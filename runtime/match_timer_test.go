package main

import (
	"encoding/json"
	"testing"
)

// match_timer_test.go — the turn clock and the abandonment counter.

// withTimings pins the clock settings for one test and restores them after.
func withTimings(t *testing.T, turnSeconds, graceSeconds int) {
	t.Helper()
	oldTurn, oldGrace := TurnSeconds, TurnGraceSeconds
	TurnSeconds, TurnGraceSeconds = turnSeconds, graceSeconds
	t.Cleanup(func() { TurnSeconds, TurnGraceSeconds = oldTurn, oldGrace })
}

// TestAutoSkipAndAbandon: a player who never acts is charged one missed turn per
// expiry and auto-loses on the miss after the limit.
func TestAutoSkipAndAbandon(t *testing.T) {
	withTimings(t, 3, 0)

	const start = int64(1_000_000)
	ms, disp, tc := newTestMatch(t, start, "user1", "user2")
	ms.Players[1].Conceded = true // so play always returns to seat 0

	for miss := 1; miss <= AbandonMissLimit+1; miss++ {
		tc = tc.at(ms.TurnDeadlineMs + 1)
		ms = checkTurnTimer(ms, tc)

		if got := ms.Players[0].MissedTurns; got != miss {
			t.Fatalf("miss %d: MissedTurns = %d, want %d", miss, got, miss)
		}

		b, ok := disp.lastOfOp(OpPlayerAbandoned)
		if !ok {
			t.Fatalf("miss %d: no PLAYER_ABANDONED broadcast", miss)
		}
		var pa msgPlayerAbandoned
		if err := json.Unmarshal(b.data, &pa); err != nil {
			t.Fatalf("miss %d: PLAYER_ABANDONED did not decode: %v", miss, err)
		}
		if pa.Player != "user1" || pa.MissedCount != miss {
			t.Errorf("miss %d: got player=%s missed=%d, want user1/%d", miss, pa.Player, pa.MissedCount, miss)
		}

		if miss <= AbandonMissLimit {
			if ms.Phase == PhaseEnded {
				t.Fatalf("miss %d: game ended before the limit was exceeded", miss)
			}
			if ms.TurnDeadlineMs <= tc.now {
				t.Errorf("miss %d: clock was not re-armed for the next turn", miss)
			}
		}
	}

	if !ms.Players[0].Conceded {
		t.Error("player should be auto-lost after exceeding the miss limit")
	}
	if ms.Phase != PhaseEnded {
		t.Errorf("phase = %q, want %q", ms.Phase, PhaseEnded)
	}
	if n := disp.countOfOp(OpGameEnded); n != 1 {
		t.Errorf("GAME_ENDED broadcast %d times, want exactly 1", n)
	}
}

// TestTimerNotFiredBeforeDeadline: the clock is a no-op until it expires.
func TestTimerNotFiredBeforeDeadline(t *testing.T) {
	withTimings(t, 90, 2)

	const start = int64(2_000_000)
	ms, disp, tc := newTestMatch(t, start, "user1", "user2")

	ms = checkTurnTimer(ms, tc.at(ms.TurnDeadlineMs-1))

	if ms.Players[0].MissedTurns != 0 {
		t.Errorf("MissedTurns = %d before the deadline, want 0", ms.Players[0].MissedTurns)
	}
	if disp.countOfOp(OpPlayerAbandoned) != 0 {
		t.Error("PLAYER_ABANDONED must not fire before the deadline")
	}
}

// TestGracePeriodAbsorbsLatency: an action that lands just past the deadline is
// still inside the grace window, so a player on a slow link is not punished.
func TestGracePeriodAbsorbsLatency(t *testing.T) {
	withTimings(t, 90, 2)

	const start = int64(3_000_000)
	ms, _, tc := newTestMatch(t, start, "user1", "user2")
	deadline := ms.TurnDeadlineMs

	ms = checkTurnTimer(ms, tc.at(deadline+1500)) // 1.5s late, inside a 2s grace
	if ms.Players[0].MissedTurns != 0 {
		t.Errorf("a turn 1.5s past the deadline was counted as missed with a 2s grace")
	}

	ms = checkTurnTimer(ms, tc.at(deadline+2500)) // past the grace
	if ms.Players[0].MissedTurns != 1 {
		t.Errorf("MissedTurns = %d past the grace window, want 1", ms.Players[0].MissedTurns)
	}
}

// TestReconnectDoesNotResetMissedTurns: coming back does not wipe the counter (§9).
func TestReconnectDoesNotResetMissedTurns(t *testing.T) {
	withTimings(t, 3, 0)

	const start = int64(4_000_000)
	ms, _, tc := newTestMatch(t, start, "user1", "user2")
	ms.Players[1].Conceded = true

	ms = checkTurnTimer(ms, tc.at(ms.TurnDeadlineMs+1))
	ms = checkTurnTimer(ms, tc.at(ms.TurnDeadlineMs+1))
	if ms.Players[0].MissedTurns != 2 {
		t.Fatalf("MissedTurns = %d, want 2", ms.Players[0].MissedTurns)
	}

	ms.Players[0].Disconnected = false // reconnect

	if ms.Players[0].MissedTurns != 2 {
		t.Errorf("MissedTurns = %d after reconnect, want 2", ms.Players[0].MissedTurns)
	}
}

// TestTurnDeadlineResetsEachTurn: every new turn gets a full budget, never the
// remainder of the previous player's.
func TestTurnDeadlineResetsEachTurn(t *testing.T) {
	withTimings(t, 90, 0)

	const start = int64(5_000_000)
	ms, _, tc := newTestMatch(t, start, "user1", "user2", "user3")

	// Seat 0 acts 80 seconds in; seat 1 must still get the full 90.
	actedAt := start + 80_000
	ms = processMessage(ms, message("user1", OpActionHarvest, msgHarvest{
		Elements: []Element{ELight, EWater, ENature},
	}), tc.at(actedAt))

	if ms.CurrentTurn != 1 {
		t.Fatalf("CurrentTurn = %d after a legal action, want 1", ms.CurrentTurn)
	}
	if got, want := ms.TurnDeadlineMs-actedAt, int64(90_000); got != want {
		t.Errorf("seat 1 got %d ms to act, want %d", got, want)
	}
	if ms.TurnDeadlineUnix != ms.TurnDeadlineMs/1000 {
		t.Error("the seconds and milliseconds deadline fields disagree")
	}
}

// ---------- No legal action (coin-limit house rule) ----------

// HasLegalAction is true for an ordinary position, false when boxed in, and
// true again as soon as any one of the three ways out opens up.
func TestHasLegalAction(t *testing.T) {
	withTimings(t, 90, 0)
	ms, _, _ := newTestMatch(t, 1_000_000, "u0", "u1")
	if !ms.HasLegalAction(0) {
		t.Fatal("a fresh seat has no legal action")
	}

	boxIn(t, ms, 0)

	// Room for one coin: a single-coin harvest is legal again.
	ms.Players[0].Coins = Cost{ELight: MaxCoins - 1}
	if !ms.HasLegalAction(0) {
		t.Error("with 9 coins a one-coin harvest should be available")
	}
	ms.Players[0].Coins = Cost{ELight: MaxCoins}

	// A free reserve slot: reserving at 10 coins is legal.
	saved := ms.Players[0].Reserve
	ms.Players[0].Reserve = saved[:len(saved)-1]
	if !ms.HasLegalAction(0) {
		t.Error("with a free reserve slot, reserving at 10 coins should be available")
	}
	ms.Players[0].Reserve = saved

	// An affordable card: hiring is legal.
	ms.Players[0].Coins = Cost{EAether: MaxCoins}
	if !ms.HasLegalAction(0) {
		t.Error("10 Aether should afford some card on the board")
	}
}

// A player who cannot legally act is passed when the clock runs out, without
// being charged a missed turn or announced as abandoning.
func TestTimeoutWithNoLegalActionIsAPassNotAMiss(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")
	boxIn(t, ms, 0)
	disp.reset()

	ms = checkTurnTimer(ms, tc.at(ms.TurnDeadlineMs+1))

	if ms.CurrentTurn != 1 {
		t.Fatalf("CurrentTurn = %d, want 1", ms.CurrentTurn)
	}
	if ms.Players[0].MissedTurns != 0 {
		t.Errorf("MissedTurns = %d; a boxed-in player could not have moved", ms.Players[0].MissedTurns)
	}
	if ms.Players[0].TurnsTaken != 1 {
		t.Errorf("TurnsTaken = %d, want 1: a pass is still a turn for final-round accounting", ms.Players[0].TurnsTaken)
	}
	if n := disp.countOfOp(OpPlayerAbandoned); n != 0 {
		t.Errorf("PLAYER_ABANDONED sent %d times for a boxed-in player", n)
	}
	if disp.countOfOp(OpTurnChange) != 1 {
		t.Error("the next player was not told it is their turn")
	}

	// And the next player can act normally.
	disp.reset()
	ms = processMessage(ms, message("u1", OpActionHarvest, msgHarvest{Elements: []Element{EWater, ENature, EFire}}), tc)
	if disp.countOfOp(OpActionRejected) != 0 || ms.CurrentTurn != 0 {
		t.Error("seat 1 could not act after seat 0 was passed")
	}
}

// A boxed-in player who also stops responding is never auto-lost for it: the
// abandonment counter only counts turns the player could have played.
func TestBoxedInPlayerIsNeverAutoLost(t *testing.T) {
	withTimings(t, 3, 0)
	ms, _, tc := newTestMatch(t, 1_000_000, "u0", "u1")
	ms.Players[1].Conceded = true // play always returns to seat 0
	boxIn(t, ms, 0)

	for i := 0; i < AbandonMissLimit+2; i++ {
		ms = checkTurnTimer(ms, tc.at(ms.TurnDeadlineMs+1))
	}
	if ms.Players[0].MissedTurns != 0 || ms.Players[0].Conceded {
		t.Errorf("boxed-in player charged %d misses, conceded=%v", ms.Players[0].MissedTurns, ms.Players[0].Conceded)
	}
}

// When nobody still in the game can act, the position is frozen for good and
// the match ends on the board as it stands instead of passing turns forever.
// (Reachable in a 2-player game: two boxed-in players can hold all 20 colour
// coins between them.)
func TestEveryoneBoxedInEndsInStalemate(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")
	boxIn(t, ms, 0)
	boxIn(t, ms, 1)
	givePower(ms, 1, 4) // seat 1 leads on Power
	disp.reset()

	ms = checkTurnTimer(ms, tc.at(ms.TurnDeadlineMs+1))

	if ms.Phase != PhaseEnded || ms.EndReason != EndReasonStalemate {
		t.Fatalf("phase=%q reason=%q, want ended/%q", ms.Phase, ms.EndReason, EndReasonStalemate)
	}
	if ms.WinnerIndex != 1 {
		t.Errorf("winnerIndex = %d, want 1 (more Power)", ms.WinnerIndex)
	}
	if disp.countOfOp(OpGameEnded) != 1 {
		t.Errorf("GAME_ENDED sent %d times, want 1", disp.countOfOp(OpGameEnded))
	}
	if ms.Players[0].MissedTurns != 0 {
		t.Error("the stalemate charged a missed turn")
	}
}

// One boxed-in player is not a stalemate while someone else can still move.
func TestOneBoxedInPlayerIsNotAStalemate(t *testing.T) {
	withTimings(t, 90, 0)
	ms, _, tc := newTestMatch(t, 1_000_000, "u0", "u1")
	boxIn(t, ms, 0)
	if ms.NobodyCanAct() {
		t.Fatal("seat 1 can still act")
	}
	ms = checkTurnTimer(ms, tc.at(ms.TurnDeadlineMs+1))
	if ms.Phase == PhaseEnded {
		t.Fatalf("match ended (%q) while seat 1 could still act", ms.EndReason)
	}
}
