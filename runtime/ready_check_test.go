package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
)

// ready_check_test.go — the pre-game ready check (match_ready.go).

// withReadyTimings pins the ready-check windows for one test.
func withReadyTimings(t *testing.T, readySeconds, refillSeconds int) {
	t.Helper()
	oldReady, oldRefill := ReadyTimeoutSeconds, ReadyRefillSeconds
	ReadyTimeoutSeconds, ReadyRefillSeconds = readySeconds, refillSeconds
	t.Cleanup(func() { ReadyTimeoutSeconds, ReadyRefillSeconds = oldReady, oldRefill })
}

// newReadyMatch seats and connects the given players and opens the ready
// check at now, as MatchInit does for a matchmaker match. host != "" makes it
// a private match.
func newReadyMatch(t *testing.T, now, seed int64, host string, userIDs ...string) (*MatchState, *mockDispatcher, turnCtx) {
	t.Helper()
	ms := NewMatchStateSeeded(userIDs, userIDs, host == "", len(userIDs), seed)
	ms.ReadyCheck = true
	ms.HostUserID = host
	for i := range ms.Players {
		ms.Players[i].Disconnected = false
		ms.trackPresence(presenceFor(ms.Players[i].UserID))
	}
	enterReadyCheck(ms, now)

	disp := &mockDispatcher{}
	tc := turnCtx{ctx: testContext(), logger: &mockLogger{t}, dispatcher: disp, now: now}
	return ms, disp, tc
}

func ready(userID string) runtime.MatchData { return message(userID, OpReady, struct{}{}) }

func decodeReadyState(t *testing.T, disp *mockDispatcher) msgReadyState {
	t.Helper()
	b, ok := disp.lastOfOp(OpReadyState)
	if !ok {
		t.Fatal("no READY_STATE was broadcast")
	}
	var rs msgReadyState
	if err := json.Unmarshal(b.data, &rs); err != nil {
		t.Fatalf("READY_STATE did not decode: %v", err)
	}
	return rs
}

func lastRemoved(t *testing.T, disp *mockDispatcher, userID string) msgRemovedFromMatch {
	t.Helper()
	for i := len(disp.broadcasts) - 1; i >= 0; i-- {
		b := disp.broadcasts[i]
		if b.opCode == OpRemovedFromMatch && b.recipient == userID {
			var m msgRemovedFromMatch
			if err := json.Unmarshal(b.data, &m); err != nil {
				t.Fatalf("REMOVED_FROM_MATCH did not decode: %v", err)
			}
			return m
		}
	}
	t.Fatalf("no REMOVED_FROM_MATCH was sent to %s", userID)
	return msgRemovedFromMatch{}
}

func lastLabel(t *testing.T, disp *mockDispatcher) matchLabel {
	t.Helper()
	if len(disp.labels) == 0 {
		t.Fatal("the match label was never published")
	}
	var l matchLabel
	if err := json.Unmarshal([]byte(disp.labels[len(disp.labels)-1]), &l); err != nil {
		t.Fatalf("label did not decode: %v", err)
	}
	return l
}

// startedFirstSeat readies everyone in a fresh seeded match and reports the
// opening seat.
func startedFirstSeat(t *testing.T, seed int64, userIDs ...string) int {
	t.Helper()
	ms, _, tc := newReadyMatch(t, 1_000_000, seed, "", userIDs...)
	msgs := make([]runtime.MatchData, 0, len(userIDs))
	for _, id := range userIDs {
		msgs = append(msgs, ready(id))
	}
	ms = runLoop(ms, tc, msgs)
	if ms.Phase != PhasePlaying {
		t.Fatalf("seed %d: phase = %q after everyone was ready, want playing", seed, ms.Phase)
	}
	return ms.FirstSeat
}

// ---------- start ----------

func TestReadyCheck_AllReadyStartsWithFirstSeatOnTurn(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	const now = int64(1_000_000)
	ms, disp, tc := newReadyMatch(t, now, 7, "", "u0", "u1", "u2")

	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0")})
	if ms.Phase != PhaseReadyCheck {
		t.Fatalf("phase = %q after one READY of three, want readyCheck", ms.Phase)
	}
	rs := decodeReadyState(t, disp)
	if rs.ReadyCount != 1 || rs.SeatCount != 3 || !rs.Seats[0].Ready || rs.Seats[1].Ready {
		t.Errorf("READY_STATE = %+v, want seat 0 ready, 1 of 3", rs)
	}
	if rs.DeadlineMs != now+120_000 || rs.ServerNowMs != now || rs.ReadySeconds != 120 {
		t.Errorf("READY_STATE clock = deadline %d now %d secs %d", rs.DeadlineMs, rs.ServerNowMs, rs.ReadySeconds)
	}
	if v := disp.lastStateFor(t, "u1"); v.Phase != PhaseReadyCheck || v.ReadyDeadlineMs != now+120_000 || !v.Players[0].Ready || v.FirstSeat != -1 {
		t.Errorf("STATE_FULL during the check: phase=%q readyDeadline=%d p0ready=%v firstSeat=%d",
			v.Phase, v.ReadyDeadlineMs, v.Players[0].Ready, v.FirstSeat)
	}

	ms = runLoop(ms, tc.at(now+1000), []runtime.MatchData{ready("u1"), ready("u2")})
	if ms.Phase != PhasePlaying {
		t.Fatalf("phase = %q after everyone was ready, want playing", ms.Phase)
	}
	if ms.FirstSeat < 0 || ms.FirstSeat > 2 || ms.CurrentTurn != ms.FirstSeat {
		t.Fatalf("FirstSeat = %d, CurrentTurn = %d: the opening seat must be on turn", ms.FirstSeat, ms.CurrentTurn)
	}
	if !ms.Rated {
		t.Error("a public match of three humans must stay rated")
	}

	b, ok := disp.lastOfOp(OpGameStarted)
	if !ok {
		t.Fatal("no GAME_STARTED broadcast")
	}
	var gs msgGameStarted
	if err := json.Unmarshal(b.data, &gs); err != nil {
		t.Fatalf("GAME_STARTED did not decode: %v", err)
	}
	if gs.FirstSeat != ms.FirstSeat || gs.FirstPlayer != ms.Players[ms.FirstSeat].UserID || len(gs.Seats) != 3 {
		t.Errorf("GAME_STARTED = %+v, want firstSeat %d", gs, ms.FirstSeat)
	}

	tb, _ := disp.lastOfOp(OpTurnChange)
	var turn msgTurnChange
	_ = json.Unmarshal(tb.data, &turn)
	if turn.PlayerIndex != ms.FirstSeat || turn.TurnNumber != 1 {
		t.Errorf("first TURN_CHANGE = seat %d turn %d, want seat %d turn 1", turn.PlayerIndex, turn.TurnNumber, ms.FirstSeat)
	}
	if v := disp.lastStateFor(t, "u0"); v.FirstSeat != ms.FirstSeat {
		t.Errorf("STATE_FULL firstSeat = %d, want %d", v.FirstSeat, ms.FirstSeat)
	}
}

// The opening seat comes from the match RNG: the same seed always picks the
// same seat, and across seeds every seat gets picked.
func TestReadyCheck_FirstSeatIsSeededRandom(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	seen := map[int]bool{}
	for seed := int64(1); seed <= 60; seed++ {
		a := startedFirstSeat(t, seed, "a", "b", "c", "d")
		b := startedFirstSeat(t, seed, "a", "b", "c", "d")
		if a != b {
			t.Fatalf("seed %d chose seat %d then seat %d: not deterministic", seed, a, b)
		}
		seen[a] = true
	}
	if len(seen) != 4 {
		t.Errorf("60 seeds only ever opened at seats %v, want all four", seen)
	}
}

// A first player chosen beforehand (a replay, an AI match) is kept.
func TestReadyCheck_ExistingFirstSeatIsReused(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	ms, _, tc := newReadyMatch(t, 1_000_000, 3, "", "u0", "u1")
	ms.FirstSeat = 1
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0"), ready("u1")})
	if ms.FirstSeat != 1 || ms.CurrentTurn != 1 {
		t.Errorf("FirstSeat = %d, CurrentTurn = %d, want the preset seat 1", ms.FirstSeat, ms.CurrentTurn)
	}
}

// ---------- harmless and rejected messages ----------

func TestReadyCheck_ReadyFromStrangerOrTwiceIsHarmless(t *testing.T) {
	withReadyTimings(t, 120, 20)
	ms, disp, tc := newReadyMatch(t, 1_000_000, 1, "", "u0", "u1")

	ms = runLoop(ms, tc, []runtime.MatchData{ready("stranger")})
	if n := disp.countOfOp(OpReadyState); n != 0 {
		t.Errorf("a READY from a non-member broadcast READY_STATE %d times", n)
	}

	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0")})
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0")})
	if n := disp.countOfOp(OpReadyState); n != 1 {
		t.Errorf("READY twice broadcast READY_STATE %d times, want 1", n)
	}
	if n := disp.countOfOp(OpActionRejected); n != 0 {
		t.Errorf("harmless READYs drew %d rejections", n)
	}
	if ms.Phase != PhaseReadyCheck || ms.Players[1].Ready {
		t.Errorf("phase = %q, seat 1 ready = %v: nothing should have moved", ms.Phase, ms.Players[1].Ready)
	}

	// A READY after the game has started is ignored as well.
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u1")})
	turn := ms.TurnNumber
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0"), ready("u1")})
	if ms.TurnNumber != turn || disp.countOfOp(OpActionRejected) != 0 {
		t.Error("a READY during play changed the game or was rejected")
	}
}

func TestReadyCheck_ActionsAreRejected(t *testing.T) {
	withReadyTimings(t, 120, 20)
	ms, disp, tc := newReadyMatch(t, 1_000_000, 1, "", "u0", "u1")
	supply := ms.Supply[ELight]

	ms = runLoop(ms, tc, []runtime.MatchData{
		message("u0", OpActionHarvest, msgHarvest{Elements: []Element{ELight, EWater, EFire}}),
	})
	rej, ok := lastRejection(t, disp)
	if !ok || rej.Code != ErrGameNotRunning {
		t.Fatalf("harvest during the ready check: rejection = %+v, want %s", rej, ErrGameNotRunning)
	}
	if ms.Supply[ELight] != supply || TotalCoins(ms.Players[0].Coins) != 0 {
		t.Error("a rejected action changed the board")
	}
}

// ---------- timeout and replacement ----------

// Nobody is searching: the no-show's seat is held for the refill window, then
// a Normal bot takes it and the game starts.
func TestReadyCheck_TimeoutReplacedByAIWhenNoQueue(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	const now = int64(1_000_000)
	ms, disp, tc := newReadyMatch(t, now, 5, "", "u0", "u1")

	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0")})
	ms = runLoop(ms, tc.at(now+119_999), nil)
	if ms.SeatOf("u1") != 1 {
		t.Fatal("u1 was removed before the deadline")
	}

	ms = runLoop(ms, tc.at(now+120_000), nil)
	if ms.SeatOf("u1") >= 0 {
		t.Fatal("u1 is still seated after the deadline")
	}
	if rm := lastRemoved(t, disp, "u1"); rm.Reason != RemovedReadyTimeout || rm.RatingChange != 0 {
		t.Errorf("REMOVED_FROM_MATCH = %+v, want ready_timeout and no rating change", rm)
	}
	if len(disp.kicked) != 1 || disp.kicked[0] != "u1" {
		t.Errorf("kicked = %v, want [u1]", disp.kicked)
	}
	if !ms.Players[1].SeatOpen {
		t.Fatal("a public no-show's seat should be held open for a searcher")
	}
	if l := lastLabel(t, disp); l.Mode != "public" || l.Open != 1 || l.PlayerCount != 2 {
		t.Errorf("label = %+v, want public with one open seat", l)
	}
	if rs := decodeReadyState(t, disp); !rs.Seats[1].Open || rs.Seats[1].DeadlineMs != now+140_000 {
		t.Errorf("READY_STATE seat 1 = %+v, want open until %d", rs.Seats[1], now+140_000)
	}

	ms = runLoop(ms, tc.at(now+140_000), nil)
	p := ms.Players[1]
	if !p.IsAI || p.AIDifficulty != string(AINormal) || !p.Ready {
		t.Fatalf("seat 1 = %+v, want a ready Normal bot", p)
	}
	if ms.Phase != PhasePlaying {
		t.Fatalf("phase = %q once the bot sat down, want playing", ms.Phase)
	}
	if ms.Rated {
		t.Error("one human against a bot must not be rated")
	}
	if l := lastLabel(t, disp); l.Open != 0 || l.Rated {
		t.Errorf("label after start = %+v, want no open seat and unrated", l)
	}
}

// A searcher takes the open seat, gets a fresh ready window of their own, and
// the game starts rated once they confirm.
func TestReadyCheck_TimeoutReplacedByQueuedHuman(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	const now = int64(1_000_000)
	ms, disp, tc := newReadyMatch(t, now, 5, "", "u0", "u1")
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0")})
	ms = runLoop(ms, tc.at(now+120_000), nil)

	if ok, reason := claimRefillSeat(ms, "u1", now+130_000); ok || reason != "removed from this match" {
		t.Errorf("the removed player reclaimed their seat: ok=%v reason=%q", ok, reason)
	}
	if ok, _ := claimRefillSeat(ms, "u9", now+130_000); !ok {
		t.Fatal("a searcher could not claim the open seat")
	}
	if ok, reason := claimRefillSeat(ms, "u8", now+130_500); ok || reason != "match is full" {
		t.Errorf("a second searcher got the same seat: ok=%v reason=%q", ok, reason)
	}

	// The refill window closes while u9's join is in flight: the claim holds.
	ms = runLoop(ms, tc.at(now+140_000), nil)
	if !ms.Players[1].SeatOpen {
		t.Fatal("the seat went to a bot while a searcher's join was in flight")
	}

	joinAt := now + 140_500
	ms = handleJoin(ms, tc.at(joinAt), []runtime.Presence{presenceFor("u9")})
	if seat := ms.SeatOf("u9"); seat != 1 {
		t.Fatalf("u9 seated at %d, want 1", seat)
	}
	p := ms.Players[1]
	if p.Ready || p.IsAI || p.ReadyDeadlineMs != joinAt+120_000 {
		t.Errorf("replacement = %+v, want an unready human with a fresh %d deadline", p, joinAt+120_000)
	}
	if v := disp.lastStateFor(t, "u9"); v.YourSeat != 1 || v.Phase != PhaseReadyCheck {
		t.Errorf("replacement's first view: seat %d phase %q", v.YourSeat, v.Phase)
	}

	ms = runLoop(ms, tc.at(joinAt+5_000), []runtime.MatchData{ready("u9")})
	if ms.Phase != PhasePlaying {
		t.Fatalf("phase = %q after the replacement confirmed, want playing", ms.Phase)
	}
	if !ms.Rated {
		t.Error("two humans after a refill should still be rated")
	}
}

// A join that lands after the open seat has gone to a bot is turned away.
func TestReadyCheck_LateRefillJoinIsTurnedAway(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	const now = int64(1_000_000)
	ms, disp, tc := newReadyMatch(t, now, 5, "", "u0", "u1", "u2")
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0")})
	ms = handleLeave(ms, tc.at(now+1_000), []runtime.Presence{presenceFor("u1")}) // seat 1 open
	ms = runLoop(ms, tc.at(now+21_000), nil)                                      // nobody came: bot
	if !ms.Players[1].IsAI || ms.Phase != PhaseReadyCheck {
		t.Fatalf("seat 1 = %+v phase %q, want a bot while u2 is still deciding", ms.Players[1], ms.Phase)
	}
	ms = handleJoin(ms, tc.at(now+22_000), []runtime.Presence{presenceFor("late")})
	if ms.SeatOf("late") >= 0 {
		t.Fatal("a late searcher was seated without an open seat")
	}
	if rm := lastRemoved(t, disp, "late"); rm.Reason != RemovedSeatUnavailable {
		t.Errorf("late joiner told %q, want %q", rm.Reason, RemovedSeatUnavailable)
	}
	if _, tracked := ms.presenceOf("late"); tracked {
		t.Error("the turned-away socket is still tracked")
	}
}

// A private match never offers a seat to strangers: the no-show is replaced
// by a bot at once.
func TestReadyCheck_PrivateMatchReplacesWithAI(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	const now = int64(1_000_000)
	ms, disp, tc := newReadyMatch(t, now, 9, "host", "host", "friend1", "friend2")
	ms = runLoop(ms, tc, []runtime.MatchData{ready("host"), ready("friend1")})
	ms = runLoop(ms, tc.at(now+120_000), nil)

	if ms.SeatOf("friend2") >= 0 {
		t.Fatal("friend2 is still seated after the deadline")
	}
	if p := ms.Players[2]; !p.IsAI || p.SeatOpen || p.AIDifficulty != string(AINormal) {
		t.Fatalf("seat 2 = %+v, want a Normal bot and never an open seat", p)
	}
	if ms.Phase != PhasePlaying {
		t.Errorf("phase = %q, want playing", ms.Phase)
	}
	for _, l := range disp.labels {
		if strings.Contains(l, `"open":1`) {
			t.Errorf("a private match advertised an open seat: %s", l)
		}
	}
	if ok, _ := claimRefillSeat(ms, "stranger", now+121_000); ok {
		t.Error("a stranger was admitted to a private match")
	}
}

// Leaving or conceding during the ready check is a timeout, not a loss.
func TestReadyCheck_LeaveAndConcedeAreTreatedAsTimeouts(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	const now = int64(1_000_000)
	ms, disp, tc := newReadyMatch(t, now, 2, "", "u0", "u1", "u2")
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u1")})

	ms = handleLeave(ms, tc.at(now+1_000), []runtime.Presence{presenceFor("u1")})
	if ms.SeatOf("u1") >= 0 || !ms.Players[1].SeatOpen {
		t.Fatal("a player who left during the ready check kept the seat")
	}
	if rm := lastRemoved(t, disp, "u1"); rm.Reason != RemovedLeft {
		t.Errorf("leaver told %q, want %q", rm.Reason, RemovedLeft)
	}

	ms = runLoop(ms, tc.at(now+2_000), []runtime.MatchData{message("u2", OpConcede, struct{}{})})
	if ms.SeatOf("u2") >= 0 || !ms.Players[2].SeatOpen {
		t.Fatal("a player who conceded during the ready check kept the seat")
	}
	for i := range ms.Players {
		if ms.Players[i].Conceded {
			t.Errorf("seat %d is marked conceded: nothing was played", i)
		}
	}
	if ms.Phase != PhaseReadyCheck {
		t.Errorf("phase = %q, want the check to carry on for u0", ms.Phase)
	}
}

// A stale leave from an old socket must not cost a reconnected player the seat.
func TestReadyCheck_StaleLeaveIsIgnored(t *testing.T) {
	withReadyTimings(t, 120, 20)
	ms, _, tc := newReadyMatch(t, 1_000_000, 2, "", "u0", "u1")
	ms.trackPresence(mockPresence{userID: "u1", sessionID: "new-socket", username: "u1"})
	ms = handleLeave(ms, tc, []runtime.Presence{presenceFor("u1")}) // the old socket
	if ms.SeatOf("u1") != 1 {
		t.Error("a leave from a replaced socket removed the player")
	}
}

// Nobody passed the check: the match is cancelled, unrated, with no history.
func TestReadyCheck_NoHumanLeftCancels(t *testing.T) {
	withReadyTimings(t, 120, 20)
	const now = int64(1_000_000)
	ms, disp, tc := newReadyMatch(t, now, 4, "", "u0", "u1")
	ms = runLoop(ms, tc.at(now+120_000), nil)
	if ms.Phase != PhaseEnded || ms.EndReason != EndReasonLobbyTimeout {
		t.Fatalf("phase = %q reason = %q, want ended / lobbyTimeout", ms.Phase, ms.EndReason)
	}
	if disp.countOfOp(OpGameEnded) != 1 {
		t.Error("GAME_ENDED was not sent exactly once")
	}
}

// The removed player's lock is released and they are told even when their
// socket is not in the match.
func TestReadyCheck_RemovalReleasesLockAndNotifies(t *testing.T) {
	withReadyTimings(t, 120, 20)
	const now = int64(1_000_000)
	ms, _, tc := newReadyMatch(t, now, 4, "", "u0", "u1")
	nk := &readyNK{meta: `{"activeMatchId":"m1"}`}
	tc.nk = nk
	ms.dropPresence("u1") // never connected
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0")})
	ms = runLoop(ms, tc.at(now+120_000), nil)

	if len(nk.updated) != 1 || nk.updated[0] != "u1" {
		t.Errorf("account writes = %v, want only u1's lock released", nk.updated)
	}
	if len(nk.notified) != 1 || nk.notified[0] != "u1" || nk.codes[0] != NotifyRemovedFromMatch {
		t.Errorf("notifications = %v codes %v, want u1 / %d", nk.notified, nk.codes, NotifyRemovedFromMatch)
	}
}

// ---------- the final round with a random opener ----------

// With seat 1 opening a 3-player game the order is 1, 2, 0: a threshold
// reached by seat 2 gives seat 0 its turn and then ends the game.
func TestFinalRound_MeasuredFromFirstSeat(t *testing.T) {
	withTimings(t, 90, 0)
	const start = int64(1_000_000)
	ms, _, tc := newTestMatch(t, start, "user1", "user2", "user3")
	ms.FirstSeat = 1
	ms.Start(start)
	if ms.CurrentTurn != 1 {
		t.Fatalf("CurrentTurn = %d, want the opener at seat 1", ms.CurrentTurn)
	}

	ms = harvest(ms, tc, "user2")
	givePower(ms, 2, WinThreshold)
	ms = harvest(ms, tc, "user3")
	if ms.Phase != PhaseFinalRound || ms.CurrentTurn != 0 {
		t.Fatalf("phase = %q turn = %d, want the final round with seat 0 to play", ms.Phase, ms.CurrentTurn)
	}
	ms = harvest(ms, tc, "user1")
	if ms.Phase != PhaseEnded {
		t.Errorf("phase = %q after the last seat of the round, want ended", ms.Phase)
	}

	// The bot's search must see the same end of the round.
	ms2, _, _ := newTestMatch(t, start, "a", "b", "c")
	ms2.FirstSeat = 1
	ms2.Phase = PhaseFinalRound
	ms2.CurrentTurn = 0
	st, _ := buildAIState(ms2, 0)
	st.endTurn()
	if !st.ended {
		t.Error("AI state: the final round did not end on wrapping back to the opener")
	}
	ms2.CurrentTurn = 2
	st, _ = buildAIState(ms2, 2)
	st.endTurn()
	if st.ended {
		t.Error("AI state: the final round ended before the last seat played")
	}
}

// ---------- creation and search ----------

func TestMatchInit_ReadyCheckAndSeed(t *testing.T) {
	m := &SplendorMatch{}
	params := func() map[string]interface{} {
		return map[string]interface{}{
			"rated": true, "userIds": []string{"a", "b"}, "names": []string{"A", "B"},
			"playerCount": 2, "seed": 42,
		}
	}
	s1, _, label := m.MatchInit(testContext(), &mockLogger{t}, nil, nil, params())
	s2, _, _ := m.MatchInit(testContext(), &mockLogger{t}, nil, nil, params())
	a, b := s1.(*MatchState), s2.(*MatchState)
	if a.Phase != PhaseReadyCheck || !a.ReadyCheck {
		t.Errorf("matchmaker match phase = %q readyCheck=%v, want the ready check", a.Phase, a.ReadyCheck)
	}
	if strings.Join(a.Tier1Visible, ",") != strings.Join(b.Tier1Visible, ",") || a.Seed != 42 {
		t.Error("the same seed did not produce the same deal")
	}
	if !strings.Contains(label, `"mode":"public"`) {
		t.Errorf("label = %s, want mode public", label)
	}

	ai, _, aiLabel := m.MatchInit(testContext(), &mockLogger{t}, nil, nil, map[string]interface{}{
		"rated": false, "userIds": []string{"h"}, "names": []string{"H"}, "playerCount": 2, "aiCount": 1,
	})
	am := ai.(*MatchState)
	if am.ReadyCheck || am.Phase != PhaseWaiting || am.FirstSeat != 0 {
		t.Errorf("AI match: readyCheck=%v phase=%q firstSeat=%d, want no check and the human opening", am.ReadyCheck, am.Phase, am.FirstSeat)
	}
	if !strings.Contains(aiLabel, `"mode":"ai"`) {
		t.Errorf("AI label = %s", aiLabel)
	}

	priv, _, _ := m.MatchInit(testContext(), &mockLogger{t}, nil, nil, map[string]interface{}{
		"rated": false, "playerCount": 2, "hostUserId": "h",
	})
	if pm := priv.(*MatchState); !pm.ReadyCheck || pm.Phase != PhaseWaiting {
		t.Errorf("private lobby: readyCheck=%v phase=%q, want waiting with the check armed", pm.ReadyCheck, pm.Phase)
	}
}

// A private lobby enters the ready check when its last seat fills.
func TestReadyCheck_PrivateLobbyEntersCheckWhenFull(t *testing.T) {
	withReadyTimings(t, 120, 20)
	ms := NewMatchStateSeeded(nil, nil, false, 2, 1)
	ms.ReadyCheck = true
	ms.HostUserID = "host"
	disp := &mockDispatcher{}
	tc := turnCtx{ctx: testContext(), logger: &mockLogger{t}, dispatcher: disp, now: 1_000_000}

	ms = handleJoin(ms, tc, []runtime.Presence{presenceFor("host")})
	if ms.Phase != PhaseWaiting {
		t.Fatalf("phase = %q with one of two seated", ms.Phase)
	}
	ms = handleJoin(ms, tc, []runtime.Presence{presenceFor("guest")})
	if ms.Phase != PhaseReadyCheck {
		t.Fatalf("phase = %q with the lobby full, want readyCheck", ms.Phase)
	}
	if rs := decodeReadyState(t, disp); rs.SeatCount != 2 || rs.ReadyCount != 0 {
		t.Errorf("READY_STATE = %+v", rs)
	}
	if v := disp.lastStateFor(t, "guest"); v.Phase != PhaseReadyCheck {
		t.Errorf("the joiner's view says %q; it must reflect the ready check", v.Phase)
	}
}

func TestStartPublicSearch_ReturnsRefillMatch(t *testing.T) {
	nk := &readyNK{matches: []*api.Match{{MatchId: "refill-1"}}}
	ctx := context.WithValue(testContext(), runtime.RUNTIME_CTX_USER_ID, "searcher")
	out, err := rpcStartPublicSearch(ctx, &mockLogger{t}, nil, nk, `{"playerCount":3}`)
	if err != nil {
		t.Fatalf("start_public_search: %v", err)
	}
	var resp startPublicSearchResponse
	if err := json.Unmarshal([]byte(out), &resp); err != nil {
		t.Fatalf("response did not decode: %v", err)
	}
	if resp.RefillMatchID != "refill-1" || resp.MinCount != 3 {
		t.Errorf("response = %+v, want refillMatchId refill-1 alongside the matchmaker params", resp)
	}
	for _, want := range []string{"+label.mode:public", "+label.open:>=1", "+label.playerCount:>=3", "+label.playerCount:<=3"} {
		if !strings.Contains(nk.query, want) {
			t.Errorf("refill query %q lacks %q", nk.query, want)
		}
	}

	nk.matches = nil
	out, _ = rpcStartPublicSearch(ctx, &mockLogger{t}, nil, nk, `{"playerCount":3}`)
	if strings.Contains(out, "refillMatchId") {
		t.Errorf("no open seat, yet the response offers one: %s", out)
	}
}

// A bot that replaced a no-show is not rated, and the humans are rated
// against each other only.
func TestApplyRatingUpdates_SkipsBotSeats(t *testing.T) {
	ms := newRatedMatchState("p0", "p1")
	ms.Players = append(ms.Players, newAIPlayer(2, AINormal, nil))
	mnk := newMockNK()
	deltas := applyRatingUpdates(context.Background(), &mockLogger{t}, mnk, ms, testStandings(ms, 0))
	if _, ok := deltas[aiSeatUserID(2)]; ok || len(deltas) != 2 {
		t.Errorf("deltas = %v, want the two humans only", deltas)
	}
	for k := range mnk.store {
		if strings.Contains(k, aiUserPrefix) {
			t.Errorf("a rating profile was written for a bot: %s", k)
		}
	}
	if deltas["p0"] <= 0 || deltas["p1"] >= 0 {
		t.Errorf("deltas = %v, want the winner up and the loser down", deltas)
	}
}

// ---------- fake Nakama module ----------

// readyNK fakes the few Nakama calls the ready check and the refill search make.
type readyNK struct {
	runtime.NakamaModule
	meta     string // account metadata JSON; "" means no lock held
	matches  []*api.Match
	query    string
	updated  []string
	notified []string
	codes    []int
}

func (n *readyNK) AccountGetId(_ context.Context, userID string) (*api.Account, error) {
	return &api.Account{User: &api.User{Id: userID, Metadata: n.meta}}, nil
}

func (n *readyNK) AccountUpdateId(_ context.Context, userID, _ string, _ map[string]interface{}, _, _, _, _, _ string) error {
	n.updated = append(n.updated, userID)
	return nil
}

func (n *readyNK) NotificationSend(_ context.Context, userID, _ string, _ map[string]interface{}, code int, _ string, _ bool) error {
	n.notified = append(n.notified, userID)
	n.codes = append(n.codes, code)
	return nil
}

func (n *readyNK) MatchList(_ context.Context, _ int, _ bool, _ string, _, _ *int, query string) ([]*api.Match, error) {
	n.query = query
	return n.matches, nil
}
