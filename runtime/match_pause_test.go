package main

import (
	"encoding/json"
	"testing"

	"github.com/heroiclabs/nakama-common/runtime"
)

// match_pause_test.go — the voted pause of a friends' game, and the skip.

func newFriendsMatch(t *testing.T, now int64, userIDs ...string) (*MatchState, *mockDispatcher, turnCtx) {
	t.Helper()
	ms, disp, tc := newTestMatch(t, now, userIDs...)
	ms.HostUserID = userIDs[0]
	return ms, disp, tc
}

func lastStatus(t *testing.T, disp *mockDispatcher) msgTableStatus {
	t.Helper()
	b, ok := disp.lastOfOp(OpTableStatus)
	if !ok {
		t.Fatal("no TABLE_STATUS broadcast")
	}
	var st msgTableStatus
	if err := json.Unmarshal(b.data, &st); err != nil {
		t.Fatalf("TABLE_STATUS did not decode: %v", err)
	}
	return st
}

func vote(ms *MatchState, tc turnCtx, userID string, op int64, on bool) *MatchState {
	return runLoop(ms, tc, []runtime.MatchData{message(userID, op, msgPauseVote{On: on})})
}

// TestPause_NMinusOneVotesStopTheGame: five players, the fourth vote pauses.
func TestPause_NMinusOneVotesStopTheGame(t *testing.T) {
	withTimings(t, 90, 0)
	const start = int64(1_000_000)
	ms, disp, tc := newFriendsMatch(t, start, "a", "b", "c", "d", "e")
	tc = tc.at(start + 30_000) // 60 s left on the clock

	for i, u := range []string{"a", "b", "c"} {
		ms = vote(ms, tc, u, OpPause, true)
		st := lastStatus(t, disp)
		if ms.Paused || st.Paused {
			t.Fatalf("paused after %d votes of 5 players", i+1)
		}
		if st.PauseVotes != i+1 || st.PauseNeeded != 4 || !st.Seats[i].PauseVote {
			t.Fatalf("after %d votes: status %+v", i+1, st)
		}
	}
	ms = vote(ms, tc, "d", OpPause, true)
	st := lastStatus(t, disp)
	if !ms.Paused || !st.Paused {
		t.Fatal("four votes of five players did not pause")
	}
	if st.TurnLeftMs != 60_000 || ms.TurnDeadlineMs != 0 {
		t.Errorf("clock not frozen: left=%d deadline=%d", st.TurnLeftMs, ms.TurnDeadlineMs)
	}
	if st.CloseAtMs != tc.now+int64(PauseCloseMinutes)*60_000 {
		t.Errorf("closeAtMs = %d", st.CloseAtMs)
	}

	// the fifth may pause too; nobody can take a request back now
	ms = vote(ms, tc, "e", OpPause, true)
	ms = vote(ms, tc, "a", OpPause, false)
	if st := lastStatus(t, disp); st.PauseVotes != 5 {
		t.Errorf("pause votes = %d, want 5", st.PauseVotes)
	}

	// moves and the clock stand still
	turn := ms.CurrentTurn
	disp.reset()
	ms = runLoop(ms, tc.at(start+10*60_000), []runtime.MatchData{message(ms.Players[turn].UserID, OpSkip, struct{}{})})
	if ms.CurrentTurn != turn || ms.Players[turn].MissedTurns != 0 {
		t.Fatal("the game moved while paused")
	}
	if b, ok := disp.lastOfOp(OpActionRejected); !ok || !json.Valid(b.data) {
		t.Error("a move while paused was not rejected")
	}

	// any four of the five resume it, with the clock where it stopped
	later := tc.at(start + 12*60_000)
	for _, u := range []string{"e", "c", "b"} {
		ms = vote(ms, later, u, OpResume, true)
	}
	if !ms.Paused {
		t.Fatal("resumed with three of five")
	}
	ms = vote(ms, later, "d", OpResume, true)
	if ms.Paused {
		t.Fatal("four resume votes did not resume")
	}
	if ms.TurnDeadlineMs != later.now+60_000 {
		t.Errorf("deadline after resume = %d, want now+60000", ms.TurnDeadlineMs-later.now)
	}
	for i := range ms.Players {
		if ms.Players[i].PauseVote || ms.Players[i].ResumeVote {
			t.Errorf("seat %d kept a vote after the resume", i)
		}
	}
	if _, ok := disp.lastOfOp(OpTurnChange); !ok {
		t.Error("no TURN_CHANGE after the resume (the clocks restart from it)")
	}
}

// TestPause_TwoPlayers: one pauses, but both must resume.
func TestPause_TwoPlayers(t *testing.T) {
	withTimings(t, 90, 0)
	const start = int64(1_000_000)
	ms, _, tc := newFriendsMatch(t, start, "a", "b")
	ms = vote(ms, tc, "a", OpPause, true)
	if !ms.Paused {
		t.Fatal("one of two did not pause")
	}
	ms = vote(ms, tc, "b", OpResume, true)
	if !ms.Paused {
		t.Fatal("one player resumed a game of two alone")
	}
	ms = vote(ms, tc, "a", OpResume, true)
	if ms.Paused {
		t.Fatal("both resumed but the game stayed paused")
	}
}

// TestPause_RoomClosesAfterTimeout: an unresumed pause closes the room.
func TestPause_RoomClosesAfterTimeout(t *testing.T) {
	withTimings(t, 90, 0)
	const start = int64(1_000_000)
	ms, _, tc := newFriendsMatch(t, start, "a", "b", "c")
	ms = vote(ms, tc, "a", OpPause, true)
	ms = vote(ms, tc, "b", OpPause, true)
	if !ms.Paused {
		t.Fatal("two of three did not pause")
	}
	ms = runLoop(ms, tc.at(ms.PauseCloseAtMs-1), nil)
	if ms.Phase == PhaseEnded {
		t.Fatal("closed before the deadline")
	}
	ms = runLoop(ms, tc.at(ms.PauseCloseAtMs), nil)
	if ms.Phase != PhaseEnded || ms.EndReason != EndReasonPauseTimeout {
		t.Fatalf("phase=%s reason=%s, want ended/pauseTimeout", ms.Phase, ms.EndReason)
	}
}

// TestPause_PublicTablesCannotPause.
func TestPause_PublicTablesCannotPause(t *testing.T) {
	const start = int64(1_000_000)
	ms, disp, tc := newTestMatch(t, start, "a", "b")
	ms.Public = true
	ms = vote(ms, tc, "a", OpPause, true)
	if ms.Paused || ms.Players[0].PauseVote {
		t.Fatal("a public table took a pause vote")
	}
	if _, ok := disp.lastOfOp(OpActionRejected); !ok {
		t.Error("the vote was not refused")
	}
}

// TestSkip_PassesTheTurnWithoutAMiss.
func TestSkip_PassesTheTurnWithoutAMiss(t *testing.T) {
	withTimings(t, 90, 0)
	const start = int64(1_000_000)
	ms, disp, tc := newTestMatch(t, start, "a", "b", "c")
	seat := ms.CurrentTurn
	other := ms.Players[(seat+1)%3].UserID
	ms = runLoop(ms, tc, []runtime.MatchData{message(other, OpSkip, struct{}{})})
	if ms.CurrentTurn != seat {
		t.Fatal("a player skipped someone else's turn")
	}
	turnNo := ms.TurnNumber
	ms = runLoop(ms, tc, []runtime.MatchData{message(ms.Players[seat].UserID, OpSkip, struct{}{})})
	if ms.CurrentTurn == seat || ms.TurnNumber != turnNo+1 {
		t.Fatal("the skip did not pass the turn")
	}
	if ms.Players[seat].MissedTurns != 0 || ms.Players[seat].TurnsTaken != 1 {
		t.Errorf("missed=%d taken=%d, want 0/1", ms.Players[seat].MissedTurns, ms.Players[seat].TurnsTaken)
	}
	b, ok := disp.lastOfOp(OpTurnSkipped)
	if !ok {
		t.Fatal("no TURN_SKIPPED")
	}
	var m msgTurnSkipped
	if json.Unmarshal(b.data, &m) != nil || m.PlayerIndex != seat {
		t.Errorf("TURN_SKIPPED = %s", b.data)
	}
}

// TestTableStatus_DisconnectIsAnnounced: a player who drops shows offline.
func TestTableStatus_DisconnectIsAnnounced(t *testing.T) {
	const start = int64(1_000_000)
	ms, disp, tc := newFriendsMatch(t, start, "a", "b", "c")
	ms = handleLeave(ms, tc, []runtime.Presence{presenceFor("b")})
	if st := lastStatus(t, disp); !st.Seats[1].Disconnected || st.Seats[0].Disconnected {
		t.Fatalf("after b left: %+v", st.Seats)
	}
	ms = handleJoin(ms, tc, []runtime.Presence{presenceFor("b")})
	if st := lastStatus(t, disp); st.Seats[1].Disconnected {
		t.Fatal("b came back but still shows offline")
	}
	_ = ms
}

// TestExchange_TakePastTenWithReturn: at 10 coins, take 2 different and hand 2
// back (official Splendor's return rule); the wrong count or coins not held
// are refused, and so is going past 10 without a return.
func TestExchange_TakePastTenWithReturn(t *testing.T) {
	const start = int64(1_000_000)
	ms, disp, tc := newTestMatch(t, start, "a", "b")
	seat := ms.CurrentTurn
	p := &ms.Players[seat]
	p.Coins = Cost{ELight: 4, EWater: 4, EAether: 2}
	uid := p.UserID
	supplyFire, supplyLight := ms.Supply[EFire], ms.Supply[ELight]

	try := func(op int64, payload interface{}) bool {
		disp.reset()
		turn := ms.TurnNumber
		ms = runLoop(ms, tc, []runtime.MatchData{message(uid, op, payload)})
		return ms.TurnNumber != turn
	}
	if try(OpActionHarvest, msgHarvest{Elements: []Element{EFire, ENature}}) {
		t.Fatal("went past 10 without a return")
	}
	if try(OpActionHarvest, msgHarvest{Elements: []Element{EFire, ENature}, Return: Cost{ELight: 1}}) {
		t.Fatal("returned 1 of 2 over the limit")
	}
	if try(OpActionHarvest, msgHarvest{Elements: []Element{EFire, ENature}, Return: Cost{EShadow: 2}}) {
		t.Fatal("returned coins not held")
	}
	if !try(OpActionHarvest, msgHarvest{Elements: []Element{EFire, ENature}, Return: Cost{ELight: 1, EAether: 1}}) {
		t.Fatal("a valid exchange was refused")
	}
	pc := ms.Players[seat].Coins
	if TotalCoins(pc) != 10 || pc[EFire] != 1 || pc[ENature] != 1 || pc[ELight] != 3 || pc[EAether] != 1 {
		t.Errorf("coins after the exchange = %v", pc)
	}
	if ms.Supply[EFire] != supplyFire-1 || ms.Supply[ELight] != supplyLight+1 {
		t.Errorf("supply fire %d light %d", ms.Supply[EFire], ms.Supply[ELight])
	}

	// a channel exchange (the supply holds 5 light now), handing back one of the coins just taken
	seat = ms.CurrentTurn
	p = &ms.Players[seat]
	p.Coins = Cost{EWater: 5, EShadow: 5}
	uid = p.UserID
	if !try(OpActionChannel, msgChannel{Element: ELight, Return: Cost{ELight: 1, EWater: 1}}) {
		t.Fatal("a channel exchange was refused")
	}
	if pc := ms.Players[seat].Coins; TotalCoins(pc) != 10 || pc[ELight] != 1 || pc[EWater] != 4 {
		t.Errorf("coins after the channel exchange = %v", pc)
	}
}
