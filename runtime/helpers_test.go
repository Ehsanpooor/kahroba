package main

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/heroiclabs/nakama-common/runtime"
)

// helpers_test.go — shared fakes for the match tests: a dispatcher that records
// what each player was sent, a presence, a match message, and a logger.

// ---------- presence ----------

type mockPresence struct {
	userID    string
	sessionID string
	username  string
}

func (p mockPresence) GetHidden() bool                   { return false }
func (p mockPresence) GetPersistence() bool              { return true }
func (p mockPresence) GetUsername() string               { return p.username }
func (p mockPresence) GetStatus() string                 { return "" }
func (p mockPresence) GetReason() runtime.PresenceReason { return runtime.PresenceReasonJoin }
func (p mockPresence) GetUserId() string                 { return p.userID }
func (p mockPresence) GetSessionId() string              { return p.sessionID }
func (p mockPresence) GetNodeId() string                 { return "test-node" }

func presenceFor(userID string) mockPresence {
	return mockPresence{userID: userID, sessionID: "sess-" + userID, username: userID}
}

// ---------- match message ----------

type mockMatchData struct {
	mockPresence
	opCode int64
	data   []byte
}

func (m mockMatchData) GetOpCode() int64      { return m.opCode }
func (m mockMatchData) GetData() []byte       { return m.data }
func (m mockMatchData) GetReliable() bool     { return true }
func (m mockMatchData) GetReceiveTime() int64 { return 0 }

// message builds an inbound action from a payload value.
func message(userID string, opCode int64, payload interface{}) runtime.MatchData {
	var data []byte
	if payload != nil {
		data, _ = json.Marshal(payload)
	}
	return mockMatchData{mockPresence: presenceFor(userID), opCode: opCode, data: data}
}

// ---------- dispatcher ----------

type mockBroadcast struct {
	opCode    int64
	data      []byte
	recipient string // "" means the whole match
}

type mockDispatcher struct {
	broadcasts []mockBroadcast
	kicked     []string // user IDs passed to MatchKick
	labels     []string // every label published with MatchLabelUpdate
}

func (d *mockDispatcher) record(opCode int64, data []byte, presences []runtime.Presence) {
	if len(presences) == 0 {
		d.broadcasts = append(d.broadcasts, mockBroadcast{opCode, data, ""})
		return
	}
	for _, p := range presences {
		d.broadcasts = append(d.broadcasts, mockBroadcast{opCode, data, p.GetUserId()})
	}
}

func (d *mockDispatcher) BroadcastMessage(opCode int64, data []byte, presences []runtime.Presence, sender runtime.Presence, reliable bool) error {
	d.record(opCode, data, presences)
	return nil
}

func (d *mockDispatcher) BroadcastMessageDeferred(opCode int64, data []byte, presences []runtime.Presence, sender runtime.Presence, reliable bool) error {
	d.record(opCode, data, presences)
	return nil
}

func (d *mockDispatcher) MatchKick(presences []runtime.Presence) error {
	for _, p := range presences {
		d.kicked = append(d.kicked, p.GetUserId())
	}
	return nil
}

func (d *mockDispatcher) MatchLabelUpdate(label string) error {
	d.labels = append(d.labels, label)
	return nil
}

func (d *mockDispatcher) lastOfOp(op int64) (mockBroadcast, bool) {
	for i := len(d.broadcasts) - 1; i >= 0; i-- {
		if d.broadcasts[i].opCode == op {
			return d.broadcasts[i], true
		}
	}
	return mockBroadcast{}, false
}

func (d *mockDispatcher) countOfOp(op int64) int {
	n := 0
	for _, b := range d.broadcasts {
		if b.opCode == op {
			n++
		}
	}
	return n
}

// lastStateFor returns the most recent STATE_FULL addressed to one player,
// which is how the tests assert on what that player is allowed to see.
func (d *mockDispatcher) lastStateFor(t *testing.T, userID string) StateView {
	t.Helper()
	for i := len(d.broadcasts) - 1; i >= 0; i-- {
		b := d.broadcasts[i]
		if b.opCode != OpStateFull || b.recipient != userID {
			continue
		}
		var view StateView
		if err := json.Unmarshal(b.data, &view); err != nil {
			t.Fatalf("STATE_FULL for %s did not decode: %v", userID, err)
		}
		return view
	}
	t.Fatalf("no STATE_FULL was addressed to %s", userID)
	return StateView{}
}

func (d *mockDispatcher) reset() { d.broadcasts = nil }

// ---------- logger ----------

type mockLogger struct{ t *testing.T }

func (l *mockLogger) Debug(format string, args ...interface{})                { l.t.Logf("DEBUG: "+format, args...) }
func (l *mockLogger) Info(format string, args ...interface{})                 { l.t.Logf("INFO:  "+format, args...) }
func (l *mockLogger) Warn(format string, args ...interface{})                 { l.t.Logf("WARN:  "+format, args...) }
func (l *mockLogger) Error(format string, args ...interface{})                { l.t.Logf("ERROR: "+format, args...) }
func (l *mockLogger) WithField(key string, v interface{}) runtime.Logger      { return l }
func (l *mockLogger) WithFields(fields map[string]interface{}) runtime.Logger { return l }
func (l *mockLogger) Fields() map[string]interface{}                          { return nil }

// ---------- match fixtures ----------

// newTestMatch seats the given players, connects them all, and starts play at
// the supplied clock reading.
func newTestMatch(t *testing.T, now int64, userIDs ...string) (*MatchState, *mockDispatcher, turnCtx) {
	t.Helper()
	names := make([]string, len(userIDs))
	for i, id := range userIDs {
		names[i] = id
	}
	ms := NewMatchState(userIDs, names, false, len(userIDs))
	for i := range ms.Players {
		ms.Players[i].Disconnected = false
		ms.trackPresence(presenceFor(ms.Players[i].UserID))
	}
	ms.Start(now)

	disp := &mockDispatcher{}
	tc := turnCtx{ctx: context.Background(), logger: &mockLogger{t}, nk: nil, dispatcher: disp, now: now}
	ms.SetTurnDeadline(now)
	return ms, disp, tc
}

// at returns a copy of the context with the clock moved to nowMs.
func (tc turnCtx) at(nowMs int64) turnCtx {
	tc.now = nowMs
	return tc
}

// givePower hands a seat enough Power to cross the threshold, without needing a
// real purchase sequence.
func givePower(ms *MatchState, seat, power int) {
	ms.Players[seat].HiredCards = append(ms.Players[seat].HiredCards, CharacterCard{
		ID: "test", Tier: 3, Power: power, Affinity: ELight, HireCost: Cost{},
	})
}

// testStandings builds a ranked table with a chosen winner, for the rating and
// history tests that do not play a real game. winnerIdx of -1 means everybody
// finished level.
func testStandings(ms *MatchState, winnerIdx int) []Standing {
	rows := make([]Standing, len(ms.Players))
	for i, p := range ms.Players {
		rank := 2
		if winnerIdx == -1 || i == winnerIdx {
			rank = 1
		}
		rows[i] = Standing{
			Index:       i,
			UserID:      p.UserID,
			DisplayName: p.DisplayName,
			Power:       PlayerPower(p.HiredCards, len(p.Artifacts)),
			HiredCount:  len(p.HiredCards),
			Conceded:    p.Conceded,
			Rank:        rank,
		}
	}
	return rows
}

// boxIn puts a seat in the one position the coin-limit house rule makes
// possible and the official rules do not: 10 coins, a full reserve, and nothing
// on the board or in hand it can pay for. Every coin is Light and every card
// left in reach costs no Light, so nothing is affordable and no Aether helps.
func boxIn(t *testing.T, ms *MatchState, seat int) {
	t.Helper()
	var noLight [4][]string
	for _, c := range AllCards {
		if c.HireCost[ELight] == 0 {
			noLight[c.Tier] = append(noLight[c.Tier], c.ID)
		}
	}
	ms.Tier1Visible = append([]string(nil), noLight[1][:4]...)
	ms.Tier2Visible = append([]string(nil), noLight[2][:4]...)
	ms.Tier3Visible = append([]string(nil), noLight[3][:4]...)

	p := &ms.Players[seat]
	p.Coins = Cost{ELight: MaxCoins}
	p.HiredCards = []CharacterCard{}
	p.Reserve = []ReserveSlot{}
	for i := 0; i < MaxReserve; i++ {
		id := noLight[1][4+i]
		p.Reserve = append(p.Reserve, ReserveSlot{CardID: id, Tier: 1})
	}
	if ms.HasLegalAction(seat) {
		t.Fatal("boxIn fixture left the seat with a legal action")
	}
}
