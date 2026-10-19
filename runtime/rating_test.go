package main

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// ---------- mockNK ----------
// Embeds runtime.NakamaModule (nil field) so it satisfies the interface;
// only the three methods used by rating.go are implemented.

type mockLBWrite struct {
	leaderboardID string
	ownerID       string
	score         int64
}

type mockNK struct {
	runtime.NakamaModule                   // nil — panics on any unimplemented call
	store                map[string]string // "collection/key/userId" → JSON
	lbWrites             []mockLBWrite
}

func newMockNK() *mockNK {
	return &mockNK{store: make(map[string]string)}
}

func (m *mockNK) storeKey(collection, key, userID string) string {
	return fmt.Sprintf("%s/%s/%s", collection, key, userID)
}

func (m *mockNK) StorageRead(_ context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	var out []*api.StorageObject
	for _, r := range reads {
		if v, ok := m.store[m.storeKey(r.Collection, r.Key, r.UserID)]; ok {
			out = append(out, &api.StorageObject{
				Collection: r.Collection,
				Key:        r.Key,
				UserId:     r.UserID,
				Value:      v,
			})
		}
	}
	return out, nil
}

func (m *mockNK) StorageWrite(_ context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	for _, w := range writes {
		m.store[m.storeKey(w.Collection, w.Key, w.UserID)] = w.Value
	}
	return nil, nil
}

func (m *mockNK) LeaderboardRecordWrite(_ context.Context, id, ownerID, _ string, score, _ int64, _ map[string]interface{}, _ *int) (*api.LeaderboardRecord, error) {
	m.lbWrites = append(m.lbWrites, mockLBWrite{id, ownerID, score})
	return &api.LeaderboardRecord{Score: score}, nil
}

// ---------- helpers ----------

func seedProfile(mnk *mockNK, userID string, p ratingProfile) {
	b, _ := json.Marshal(p)
	mnk.store[mnk.storeKey(RatingCollection, RatingKey, userID)] = string(b)
}

func loadProfileFromMock(mnk *mockNK, userID string) ratingProfile {
	raw := mnk.store[mnk.storeKey(RatingCollection, RatingKey, userID)]
	var p ratingProfile
	_ = json.Unmarshal([]byte(raw), &p)
	return p
}

// ---------- TestComputeEloChange ----------

func TestComputeEloChange_EqualRatings(t *testing.T) {
	// Equal ratings: expected = 0.5; win → +K/2; loss → -K/2
	win := computeEloChange(1000, 1000, true, 20)
	loss := computeEloChange(1000, 1000, false, 20)
	if win != 10 {
		t.Errorf("equal win delta = %d, want 10", win)
	}
	if loss != -10 {
		t.Errorf("equal loss delta = %d, want -10", loss)
	}
}

func TestComputeEloChange_UnderdogWins(t *testing.T) {
	// Underdog (800) beats favourite (1200): large gain for underdog.
	gain := computeEloChange(800, 1200, true, 20)
	loss := computeEloChange(1200, 800, false, 20)
	if gain <= 10 {
		t.Errorf("underdog win gain = %d, want > 10", gain)
	}
	if loss >= -10 {
		t.Errorf("favourite loss delta = %d, want < -10", loss)
	}
	t.Logf("underdog gain=%d, favourite loss=%d", gain, loss)
}

func TestComputeEloChange_FavouriteWins(t *testing.T) {
	// Favourite (1200) beats underdog (800): small gain for favourite.
	gain := computeEloChange(1200, 800, true, 20)
	if gain >= 10 {
		t.Errorf("favourite win gain = %d, want < 10", gain)
	}
	t.Logf("favourite win gain=%d", gain)
}

// ---------- TestKFactor ----------

func TestKFactor(t *testing.T) {
	prov := &ratingProfile{Provisional: true}
	grad := &ratingProfile{Provisional: false}
	if kFactor(prov) != KFactorProvisional {
		t.Errorf("provisional K = %v, want %v", kFactor(prov), KFactorProvisional)
	}
	if kFactor(grad) != KFactorStandard {
		t.Errorf("graduated K = %v, want %v", kFactor(grad), KFactorStandard)
	}
}

// ---------- TestApplyRatingUpdates ----------

// newRatedMatchState builds a minimal 2-player MatchState ready for rating tests.
func newRatedMatchState(p0, p1 string) *MatchState {
	ms := &MatchState{
		Phase:           PhaseEnded,
		WinThresholdVal: WinThreshold, // the default — weight = 1.0
		Rated:           true,
		WinnerIndex:     0, // player 0 wins
		Players: []PlayerState{
			{UserID: p0, DisplayName: "Alice"},
			{UserID: p1, DisplayName: "Bob"},
		},
	}
	return ms
}

// TestApplyRatingUpdates_RatedMatch: Alice (provisional) beats Bob (graduated).
// Expect: both profiles written, Bob gets a leaderboard entry, Alice does not.
func TestApplyRatingUpdates_RatedMatch(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}

	const alice = "user-alice"
	const bob = "user-bob"

	// Seed Bob as a graduated player (15 games already played).
	seedProfile(mnk, bob, ratingProfile{
		Rating:      1000,
		GamesPlayed: 15,
		Provisional: false,
	})
	// Alice has no storage record → readRatingProfile returns fresh default (provisional).

	ms := newRatedMatchState(alice, bob) // alice wins

	applyRatingUpdates(context.Background(), log, mnk, ms, testStandings(ms, 0))

	alice_p := loadProfileFromMock(mnk, alice)
	bob_p := loadProfileFromMock(mnk, bob)

	// Both profiles must be written.
	if alice_p.GamesPlayed != 1 {
		t.Errorf("alice GamesPlayed = %d, want 1", alice_p.GamesPlayed)
	}
	if bob_p.GamesPlayed != 16 {
		t.Errorf("bob GamesPlayed = %d, want 16", bob_p.GamesPlayed)
	}

	// Winner gains, loser loses.
	if alice_p.Rating <= DefaultRating {
		t.Errorf("alice rating should have increased: got %d", alice_p.Rating)
	}
	if bob_p.Rating >= 1000 {
		t.Errorf("bob rating should have decreased: got %d", bob_p.Rating)
	}

	// Alice wins/losses.
	if alice_p.Wins != 1 || alice_p.Losses != 0 {
		t.Errorf("alice wins=%d losses=%d, want 1/0", alice_p.Wins, alice_p.Losses)
	}
	if bob_p.Losses != 1 || bob_p.Wins != 0 {
		t.Errorf("bob wins=%d losses=%d, want 0/1", bob_p.Wins, bob_p.Losses)
	}

	// Alice: GamesPlayed=1 < ProvisionalGames=10 → still provisional → NO leaderboard write.
	if alice_p.Provisional != true {
		t.Error("alice should still be provisional after 1 game")
	}
	// Bob: GamesPlayed=16 >= 10 → graduated → YES leaderboard write.
	if bob_p.Provisional != false {
		t.Error("bob should be graduated after 16 games")
	}

	// Leaderboard: exactly one write, for Bob.
	if len(mnk.lbWrites) != 1 {
		t.Fatalf("leaderboard writes = %d, want 1", len(mnk.lbWrites))
	}
	if mnk.lbWrites[0].ownerID != bob {
		t.Errorf("leaderboard write for %s, want bob", mnk.lbWrites[0].ownerID)
	}
	if mnk.lbWrites[0].leaderboardID != LeaderboardID {
		t.Errorf("wrong leaderboard ID: %s", mnk.lbWrites[0].leaderboardID)
	}
	if mnk.lbWrites[0].score != int64(bob_p.Rating) {
		t.Errorf("leaderboard score=%d, want %d", mnk.lbWrites[0].score, bob_p.Rating)
	}

	t.Logf("alice: rating=%d provisional=%v", alice_p.Rating, alice_p.Provisional)
	t.Logf("bob:   rating=%d provisional=%v", bob_p.Rating, bob_p.Provisional)
}

// TestApplyRatingUpdates_BothProvisional: neither player has enough games → no leaderboard writes.
func TestApplyRatingUpdates_BothProvisional(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}

	const p0 = "user-p0"
	const p1 = "user-p1"
	// No pre-seeded profiles → both fresh / provisional.

	ms := newRatedMatchState(p0, p1)
	applyRatingUpdates(context.Background(), log, mnk, ms, testStandings(ms, 0))

	if len(mnk.lbWrites) != 0 {
		t.Errorf("expected 0 leaderboard writes for provisional players, got %d", len(mnk.lbWrites))
	}
}

// TestApplyRatingUpdates_Draw: WinnerIndex==-1 → both GamesPlayed++, no Wins/Losses, no leaderboard (if still provisional).
func TestApplyRatingUpdates_Draw(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}

	const p0 = "user-d0"
	const p1 = "user-d1"

	ms := newRatedMatchState(p0, p1)
	ms.WinnerIndex = -1 // draw

	applyRatingUpdates(context.Background(), log, mnk, ms, testStandings(ms, -1))

	p0p := loadProfileFromMock(mnk, p0)
	p1p := loadProfileFromMock(mnk, p1)

	if p0p.Wins != 0 || p0p.Losses != 0 {
		t.Errorf("draw: p0 wins=%d losses=%d, want 0/0", p0p.Wins, p0p.Losses)
	}
	if p1p.Wins != 0 || p1p.Losses != 0 {
		t.Errorf("draw: p1 wins=%d losses=%d, want 0/0", p1p.Wins, p1p.Losses)
	}
	if p0p.GamesPlayed != 1 || p1p.GamesPlayed != 1 {
		t.Errorf("draw: GamesPlayed not incremented (%d, %d)", p0p.GamesPlayed, p1p.GamesPlayed)
	}
}

// TestApplyRatingUpdates_ProvisionalGraduation: player crosses ProvisionalGames threshold this game → leaderboard write fires.
func TestApplyRatingUpdates_ProvisionalGraduation(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}

	const p0 = "user-grad"
	const p1 = "user-fresh"

	// p0 is on their last provisional game (GamesPlayed = ProvisionalGames-1).
	seedProfile(mnk, p0, ratingProfile{
		Rating:      1050,
		GamesPlayed: ProvisionalGames - 1,
		Provisional: true,
	})

	ms := newRatedMatchState(p0, p1)
	applyRatingUpdates(context.Background(), log, mnk, ms, testStandings(ms, 0)) // p0 wins

	p0p := loadProfileFromMock(mnk, p0)
	if p0p.Provisional {
		t.Errorf("p0 should have graduated: GamesPlayed=%d", p0p.GamesPlayed)
	}
	// Graduation this game → leaderboard write for p0.
	lbForP0 := 0
	for _, w := range mnk.lbWrites {
		if w.ownerID == p0 {
			lbForP0++
		}
	}
	if lbForP0 != 1 {
		t.Errorf("expected 1 leaderboard write for p0 on graduation, got %d", lbForP0)
	}
}
