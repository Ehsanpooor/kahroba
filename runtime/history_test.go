package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// ---------- additional mockNK methods (defined here; mockNK struct lives in rating_test.go) ----------

// StorageList iterates the in-memory store and returns objects matching collection+userID.
func (m *mockNK) StorageList(_ context.Context, _, userID, collection string, limit int, _ string) ([]*api.StorageObject, string, error) {
	var out []*api.StorageObject
	for k, v := range m.store {
		parts := strings.SplitN(k, "/", 3)
		if len(parts) != 3 {
			continue
		}
		if parts[0] != collection || parts[2] != userID {
			continue
		}
		out = append(out, &api.StorageObject{
			Collection: parts[0],
			Key:        parts[1],
			UserId:     parts[2],
			Value:      v,
		})
		if len(out) >= limit {
			break
		}
	}
	return out, "", nil
}

// ---------- TestWriteMatchHistory ----------

func TestWriteMatchHistory_WritesRecords(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}
	ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_MATCH_ID, "match-001")

	ms := &MatchState{
		Phase:           PhaseEnded,
		WinThresholdVal: WinThreshold,
		Rated:           true,
		HostUserID:      "", // public match
		StartedAtUnix:   1000,
		Players: []PlayerState{
			{UserID: "alice", DisplayName: "Alice", HiredCards: []CharacterCard{}, Artifacts: []string{}},
			{UserID: "bob", DisplayName: "Bob", HiredCards: []CharacterCard{}, Artifacts: []string{}},
		},
	}
	deltas := map[string]int{"alice": 12, "bob": -12}
	writeMatchHistory(ctx, log, mnk, ms, "match-001", testStandings(ms, 0), deltas) // alice wins (index 0)

	// Alice's history record
	aliceRaw, ok := mnk.store[mnk.storeKey(HistoryCollection, "match-001", "alice")]
	if !ok {
		t.Fatal("alice history record not written")
	}
	var aliceRec historyRecord
	_ = json.Unmarshal([]byte(aliceRaw), &aliceRec)
	if aliceRec.Result != "win" {
		t.Errorf("alice result = %q, want 'win'", aliceRec.Result)
	}
	if aliceRec.RatingDelta != 12 {
		t.Errorf("alice ratingDelta = %d, want 12", aliceRec.RatingDelta)
	}
	if aliceRec.IsAI {
		t.Error("alice isAI should be false for online game")
	}
	if aliceRec.GameID != "match-001" {
		t.Errorf("alice gameId = %q, want 'match-001'", aliceRec.GameID)
	}
	t.Logf("alice: %s", aliceRaw)

	// Bob's history record
	bobRaw, ok := mnk.store[mnk.storeKey(HistoryCollection, "match-001", "bob")]
	if !ok {
		t.Fatal("bob history record not written")
	}
	var bobRec historyRecord
	_ = json.Unmarshal([]byte(bobRaw), &bobRec)
	if bobRec.Result != "loss" {
		t.Errorf("bob result = %q, want 'loss'", bobRec.Result)
	}
	if bobRec.RatingDelta != -12 {
		t.Errorf("bob ratingDelta = %d, want -12", bobRec.RatingDelta)
	}
	t.Logf("bob: %s", bobRaw)

	// match_log — system-owned (userID="")
	logRaw, ok := mnk.store[mnk.storeKey(MatchLogCollection, "match-001", "")]
	if !ok {
		t.Fatal("match_log record not written")
	}
	var logRec matchLogRecord
	_ = json.Unmarshal([]byte(logRaw), &logRec)
	if logRec.Mode != "public" {
		t.Errorf("match_log mode = %q, want 'public'", logRec.Mode)
	}
	if !logRec.Rated {
		t.Error("match_log rated should be true")
	}
	if logRec.Result != "alice" {
		t.Errorf("match_log result = %q, want 'alice'", logRec.Result)
	}
	if len(logRec.PlayerIDs) != 2 {
		t.Errorf("match_log playerIds len = %d, want 2", len(logRec.PlayerIDs))
	}
	t.Logf("match_log: %s", logRaw)
}

func TestWriteMatchHistory_Draw(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}
	ctx := context.Background()

	ms := &MatchState{
		Phase:           PhaseEnded,
		WinThresholdVal: WinThreshold,
		HostUserID:      "host-1", // private match
		WinnerIndex:     -1,
		Players: []PlayerState{
			{UserID: "p0", HiredCards: []CharacterCard{}, Artifacts: []string{}},
			{UserID: "p1", HiredCards: []CharacterCard{}, Artifacts: []string{}},
		},
	}
	writeMatchHistory(ctx, log, mnk, ms, "match-draw", testStandings(ms, -1), map[string]int{}) // draw

	for _, uid := range []string{"p0", "p1"} {
		raw, ok := mnk.store[mnk.storeKey(HistoryCollection, "match-draw", uid)]
		if !ok {
			t.Fatalf("%s history record not written", uid)
		}
		var rec historyRecord
		_ = json.Unmarshal([]byte(raw), &rec)
		if rec.Result != "draw" {
			t.Errorf("%s result = %q, want 'draw'", uid, rec.Result)
		}
	}

	logRaw := mnk.store[mnk.storeKey(MatchLogCollection, "match-draw", "")]
	var logRec matchLogRecord
	_ = json.Unmarshal([]byte(logRaw), &logRec)
	if logRec.Mode != "private" {
		t.Errorf("mode = %q, want 'private'", logRec.Mode)
	}
	if logRec.Result != "draw" {
		t.Errorf("match_log result = %q, want 'draw'", logRec.Result)
	}
}

// ---------- TestSubmitAIResult ----------

func TestSubmitAIResult(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}
	ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_USER_ID, "player-1")

	// A recent client timestamp is honoured; see TestSubmitAIResult_RejectsImplausibleClock
	// for what happens when the device clock is wrong.
	finishedAt := time.Now().UTC().Add(-2 * time.Minute).Format(time.RFC3339)
	payload := `{"result":"win","power":8,"difficulty":"normal","finishedAt":"` + finishedAt + `"}`
	out, err := rpcSubmitAIResult(ctx, log, nil, mnk, payload)
	if err != nil {
		t.Fatalf("rpcSubmitAIResult error: %v", err)
	}
	var resp submitAIResultResponse
	_ = json.Unmarshal([]byte(out), &resp)
	if !resp.OK {
		t.Error("expected ok=true")
	}

	// Find the AI history record in storage
	found := false
	for k, v := range mnk.store {
		if !strings.HasPrefix(k, HistoryCollection+"/") {
			continue
		}
		var rec historyRecord
		_ = json.Unmarshal([]byte(v), &rec)
		if !rec.IsAI {
			continue
		}
		found = true
		if rec.Result != "win" {
			t.Errorf("AI result = %q, want 'win'", rec.Result)
		}
		if rec.Power != 8 {
			t.Errorf("AI power = %d, want 8", rec.Power)
		}
		if rec.RatingDelta != 0 {
			t.Errorf("AI ratingDelta = %d, want 0 (unrated)", rec.RatingDelta)
		}
		if rec.PlayedAt != finishedAt {
			t.Errorf("AI playedAt = %q, want the client timestamp %q", rec.PlayedAt, finishedAt)
		}
		if rec.Difficulty != "normal" {
			t.Errorf("AI difficulty = %q, want 'normal' — it must be recorded for analytics", rec.Difficulty)
		}
		t.Logf("AI history record: %s", v)
	}
	if !found {
		t.Error("no isAI=true history record found in storage")
	}
}

// A wrong device clock must not scatter history entries across the timeline:
// an implausible timestamp is replaced by server time, and the record still lands.
func TestSubmitAIResult_RejectsImplausibleClock(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}
	ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_USER_ID, "player-clock")

	stale := "2019-01-01T12:00:00Z"
	if _, err := rpcSubmitAIResult(ctx, log, nil, mnk, `{"result":"loss","power":3,"finishedAt":"`+stale+`"}`); err != nil {
		t.Fatalf("rpcSubmitAIResult error: %v", err)
	}

	for k, v := range mnk.store {
		if !strings.HasPrefix(k, HistoryCollection+"/") {
			continue
		}
		var rec historyRecord
		_ = json.Unmarshal([]byte(v), &rec)
		if rec.PlayedAt == stale {
			t.Errorf("a 2019 client timestamp was stored verbatim: %s", v)
		}
		if rec.Difficulty != "normal" {
			t.Errorf("difficulty = %q, want the 'normal' default when omitted", rec.Difficulty)
		}
	}
}

// The result enum is normalised and anything outside it is refused.
func TestSubmitAIResult_ValidatesEnums(t *testing.T) {
	log := &mockLogger{t}
	ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_USER_ID, "player-enum")

	if _, err := rpcSubmitAIResult(ctx, log, nil, newMockNK(), `{"result":"WIN","power":5,"difficulty":"Hard"}`); err != nil {
		t.Errorf("mixed-case enums should be accepted: %v", err)
	}
	if _, err := rpcSubmitAIResult(ctx, log, nil, newMockNK(), `{"result":"draw","power":5}`); err == nil {
		t.Error("an AI game cannot end in a draw; the result should have been refused")
	}
	if _, err := rpcSubmitAIResult(ctx, log, nil, newMockNK(), `{"result":"win","power":-1}`); err == nil {
		t.Error("negative Power should have been refused")
	}
}

func TestSubmitAIResult_Unauthenticated(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}
	_, err := rpcSubmitAIResult(context.Background(), log, nil, mnk, `{"result":"win","power":5}`)
	if err == nil {
		t.Error("expected error for unauthenticated call")
	}
}

// ---------- TestReportPlayer ----------

func TestReportPlayer(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}
	ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_USER_ID, "reporter-user")

	payload := `{"matchId":"match-xyz","reportedId":"bad-player","reason":"cheating"}`
	out, err := rpcReportPlayer(ctx, log, nil, mnk, payload)
	if err != nil {
		t.Fatalf("rpcReportPlayer error: %v", err)
	}
	var resp reportPlayerResponse
	_ = json.Unmarshal([]byte(out), &resp)
	if !resp.OK {
		t.Error("expected ok=true")
	}

	// Reports are system-owned (userID=""); find by iterating
	found := false
	for k, v := range mnk.store {
		if !strings.HasPrefix(k, ReportsCollection+"/") {
			continue
		}
		// key format: reports/<reportId>/  (userID="" → trailing empty segment)
		var rec reportRecord
		_ = json.Unmarshal([]byte(v), &rec)
		if rec.MatchID == "match-xyz" && rec.ReporterID == "reporter-user" && rec.ReportedID == "bad-player" {
			found = true
			if rec.Reason != "cheating" {
				t.Errorf("reason = %q, want 'cheating'", rec.Reason)
			}
			if rec.CreatedAt == "" {
				t.Error("createdAt should be set")
			}
			t.Logf("report record: %s", v)
		}
	}
	if !found {
		t.Error("report record not found in storage")
	}
}

func TestReportPlayer_MissingFields(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}
	ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_USER_ID, "user-1")

	_, err := rpcReportPlayer(ctx, log, nil, mnk, `{"matchId":"m1","reportedId":"u2"}`) // no reason
	if err == nil {
		t.Error("expected error for missing reason")
	}
}

// ---------- TestGetMatchHistory ----------

func TestGetMatchHistory_Filters(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}
	const uid = "player-history"
	ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_USER_ID, uid)

	// Seed: one online record, one AI record
	onlineRec := historyRecord{GameID: "game-online-1", IsAI: false, Result: "win", Power: 15}
	aiRec := historyRecord{GameID: "game-ai-1", IsAI: true, Result: "loss", Power: 5}
	ob, _ := json.Marshal(onlineRec)
	ab, _ := json.Marshal(aiRec)
	mnk.store[mnk.storeKey(HistoryCollection, "game-online-1", uid)] = string(ob)
	mnk.store[mnk.storeKey(HistoryCollection, "game-ai-1", uid)] = string(ab)

	cases := []struct {
		filter  string
		wantLen int
		wantIDs []string
	}{
		{"all", 2, []string{"game-online-1", "game-ai-1"}},
		{"ai", 1, []string{"game-ai-1"}},
		{"online", 1, []string{"game-online-1"}},
	}

	for _, tc := range cases {
		t.Run("filter="+tc.filter, func(t *testing.T) {
			reqBytes, _ := json.Marshal(getMatchHistoryRequest{Filter: tc.filter})
			out, err := rpcGetMatchHistory(ctx, log, nil, mnk, string(reqBytes))
			if err != nil {
				t.Fatalf("error: %v", err)
			}
			var resp getMatchHistoryResponse
			_ = json.Unmarshal([]byte(out), &resp)

			if len(resp.Entries) != tc.wantLen {
				t.Errorf("got %d entries, want %d", len(resp.Entries), tc.wantLen)
			}
			for _, wantID := range tc.wantIDs {
				found := false
				for _, e := range resp.Entries {
					if e.GameID == wantID {
						found = true
						break
					}
				}
				if !found {
					t.Errorf("expected gameId %q not in results", wantID)
				}
			}
			t.Logf("filter=%q → %d entries", tc.filter, len(resp.Entries))
		})
	}
}

func TestGetMatchHistory_DefaultFilterAll(t *testing.T) {
	mnk := newMockNK()
	log := &mockLogger{t}
	const uid = "player-2"
	ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_USER_ID, uid)

	rec := historyRecord{GameID: "game-1", IsAI: false, Result: "win"}
	b, _ := json.Marshal(rec)
	mnk.store[mnk.storeKey(HistoryCollection, "game-1", uid)] = string(b)

	// empty payload → default filter "all"
	out, err := rpcGetMatchHistory(ctx, log, nil, mnk, "")
	if err != nil {
		t.Fatalf("error: %v", err)
	}
	var resp getMatchHistoryResponse
	_ = json.Unmarshal([]byte(out), &resp)
	if len(resp.Entries) != 1 {
		t.Errorf("got %d entries, want 1", len(resp.Entries))
	}
}
