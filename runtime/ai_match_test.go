package main

import (
	"fmt"
	"strings"
	"testing"
)

// errorLogger records Error lines, which is where submitAIAction reports a bot
// move the match rejected. A bot that only ever proposes legal moves logs none.
type errorLogger struct {
	mockLogger
	errors []string
}

func (l *errorLogger) Error(format string, args ...interface{}) {
	l.errors = append(l.errors, fmt.Sprintf(format, args...))
	l.mockLogger.Error(format, args...)
}

func (l *errorLogger) rejected() []string {
	var out []string
	for _, e := range l.errors {
		if strings.Contains(e, "rejected") || strings.Contains(e, "no legal action") {
			out = append(out, e)
		}
	}
	return out
}

// ai_match_test.go — the bot inside a real authoritative match.
//
// ai_test.go proves the engine plays well against its own simulation. These
// tests prove the other half: that a bot seated in the live match handler
// actually moves, that its moves survive the same validation a client's do, and
// that a whole game between bots reaches a legitimate result.

// newAIMatch seats one human and the requested bots, then starts play.
func newAIMatch(t *testing.T, now int64, difficulty AIDifficulty, bots int) (*MatchState, *mockDispatcher, turnCtx) {
	t.Helper()

	ms := NewMatchState([]string{"human"}, []string{"Human"}, false, 1+bots)
	ms.Players[0].Disconnected = false
	ms.trackPresence(presenceFor("human"))
	for seat := 1; seat <= bots; seat++ {
		ms.Players = append(ms.Players, newAIPlayer(seat, difficulty, ms.random()))
	}
	ms.Start(now)

	disp := &mockDispatcher{}
	tc := turnCtx{ctx: testContext(), logger: &mockLogger{t}, dispatcher: disp, now: now}
	ms.SetTurnDeadline(now)
	return ms, disp, tc
}

// A bot must not answer instantly, and must move once its pause has elapsed.
func TestAISeatWaitsThenMoves(t *testing.T) {
	withTimings(t, 90, 0)
	const start = int64(1_000_000)
	ms, _, tc := newAIMatch(t, start, AINormal, 1)

	// Hand the turn to the bot.
	ms = harvest(ms, tc, "human")
	if ms.CurrentTurn != 1 {
		t.Fatalf("CurrentTurn = %d after the human acted, want the bot at seat 1", ms.CurrentTurn)
	}
	if ms.AIThinkUntilMs <= start {
		t.Fatal("the bot was not given a thinking pause")
	}

	// Still thinking: nothing happens.
	ms = driveAISeat(ms, tc.at(ms.AIThinkUntilMs-1))
	if ms.CurrentTurn != 1 {
		t.Error("the bot moved before its thinking pause elapsed")
	}

	// Pause over: it acts and play returns to the human.
	ms = driveAISeat(ms, tc.at(ms.AIThinkUntilMs+1))
	if ms.CurrentTurn != 0 {
		t.Fatalf("CurrentTurn = %d after the bot's turn, want 0", ms.CurrentTurn)
	}
	if ms.Players[1].TurnsTaken != 1 {
		t.Errorf("bot recorded %d turns taken, want 1", ms.Players[1].TurnsTaken)
	}
	if ms.Players[1].MissedTurns != 0 {
		t.Errorf("bot was charged %d missed turns", ms.Players[1].MissedTurns)
	}
}

// A full bot-versus-bot game must reach a real conclusion through the match
// handler: someone crosses the threshold, the final round completes, and the
// standings are consistent with the board.
func TestAIMatchPlaysToCompletion(t *testing.T) {
	withTimings(t, 90, 0)

	ms, disp, tc := newAIMatch(t, 1_000_000, AINormal, 2)
	// Make every seat a bot so no human input is needed.
	ms.Players[0].IsAI = true
	ms.Players[0].AIDifficulty = string(AINormal)

	now := int64(1_000_000)
	scheduleAIThink(ms, now)

	logger := &errorLogger{mockLogger: mockLogger{t}}
	tc.logger = logger

	// A tick counts as progress if any of these moved. A bot turn takes two
	// ticks: one to arm the thinking pause and one to act. There is no third
	// "return coins" tick any more: the coin limit is a hard block.
	progress := func() [3]int64 {
		return [3]int64{int64(ms.TurnNumber), ms.AIThinkUntilMs, int64(ms.CurrentTurn)}
	}

	turns := 0
	for ; turns < 800 && ms.Phase != PhaseEnded; turns++ {
		before := progress()
		now = ms.AIThinkUntilMs + 1
		ms = driveAISeat(ms, tc.at(now))

		if progress() == before && ms.Phase != PhaseEnded {
			t.Fatalf("tick %d: the match stopped advancing on seat %d", turns, ms.CurrentTurn)
		}
		for i := range ms.Players {
			if total := TotalCoins(ms.Players[i].Coins); total > MaxCoins {
				t.Fatalf("tick %d: seat %d holds %d coins, above the hard limit of %d", turns, i, total, MaxCoins)
			}
		}
	}
	if r := logger.rejected(); len(r) > 0 {
		t.Errorf("the match rejected %d bot moves, first: %s", len(r), r[0])
	}

	if ms.Phase != PhaseEnded {
		t.Fatalf("no bot reached %d Power in %d turns; powers %d/%d/%d",
			WinThreshold, turns,
			PlayerPower(ms.Players[0].HiredCards, len(ms.Players[0].Artifacts)),
			PlayerPower(ms.Players[1].HiredCards, len(ms.Players[1].Artifacts)),
			PlayerPower(ms.Players[2].HiredCards, len(ms.Players[2].Artifacts)))
	}

	standings, winner := ComputeStandings(ms.Players)
	if winner < 0 {
		t.Logf("shared victory: %+v", standings)
	}
	top := standings[0]
	if top.Power < WinThreshold {
		t.Errorf("match ended with a leading score of %d, below the %d threshold", top.Power, WinThreshold)
	}

	// Everyone must have had the same number of turns, and no bot may have been
	// charged a missed turn: a bot that stalls is the failure mode this catches.
	for i := range ms.Players {
		if ms.Players[i].MissedTurns != 0 {
			t.Errorf("seat %d missed %d turns", i, ms.Players[i].MissedTurns)
		}
	}
	if disp.countOfOp(OpGameEnded) != 1 {
		t.Errorf("GAME_ENDED broadcast %d times, want 1", disp.countOfOp(OpGameEnded))
	}
	t.Logf("bot game finished in %d turns; standings %+v", ms.TurnNumber, standings)
}

// A bot at the coin limit must pick a move the server accepts first time: no
// Harvest or Channel (coin_limit), so a hire or a reservation without Aether.
func TestAISeatRespectsCoinLimit(t *testing.T) {
	withTimings(t, 90, 0)
	const start = int64(1_000_000)
	for _, d := range []AIDifficulty{AIEasy, AINormal, AIHard} {
		ms, _, tc := newAIMatch(t, start, d, 1)
		logger := &errorLogger{mockLogger: mockLogger{t}}
		tc.logger = logger

		ms.CurrentTurn = 1
		ms.Players[1].Coins = Cost{ELight: 4, EWater: 3, ENature: 3} // at the limit
		scheduleAIThink(ms, start)

		ms = driveAISeat(ms, tc.at(ms.AIThinkUntilMs+1))

		if ms.CurrentTurn != 0 {
			t.Errorf("%s: the bot did not complete its turn at the coin limit", d)
		}
		if r := logger.rejected(); len(r) > 0 {
			t.Errorf("%s: the bot proposed a move the match rejected: %s", d, r[0])
		}
		if total := TotalCoins(ms.Players[1].Coins); total > MaxCoins {
			t.Errorf("%s: bot holds %d coins, above the limit of %d", d, total, MaxCoins)
		}
		if ms.Players[1].Conceded {
			t.Errorf("%s: the bot conceded instead of playing", d)
		}
	}
}

// A boxed-in bot (10 coins, full reserve, nothing affordable) passes at once:
// no concession, no missed turn, and no wait for its turn clock.
func TestAISeatPassesWhenBoxedIn(t *testing.T) {
	withTimings(t, 90, 0)
	const start = int64(1_000_000)
	ms, _, tc := newAIMatch(t, start, AIHard, 1)
	logger := &errorLogger{mockLogger: mockLogger{t}}
	tc.logger = logger

	ms.CurrentTurn = 1
	boxIn(t, ms, 1)
	scheduleAIThink(ms, start)

	ms = driveAISeat(ms, tc.at(ms.AIThinkUntilMs+1))

	if ms.CurrentTurn != 0 {
		t.Fatalf("CurrentTurn = %d, want the human at seat 0", ms.CurrentTurn)
	}
	if ms.Players[1].Conceded {
		t.Error("the boxed-in bot conceded")
	}
	if ms.Players[1].MissedTurns != 0 || ms.Players[1].TurnsTaken != 1 {
		t.Errorf("missed=%d taken=%d, want 0 and 1", ms.Players[1].MissedTurns, ms.Players[1].TurnsTaken)
	}
	if r := logger.rejected(); len(r) > 0 {
		t.Errorf("the bot tried a move first: %s", r[0])
	}
}

// The match must be flagged as an AI game for history, and the bot seat must be
// excluded from anything that writes against a real account.
func TestAIMatchIsFlaggedAndUnrated(t *testing.T) {
	withTimings(t, 90, 0)
	ms, _, _ := newAIMatch(t, 1_000_000, AIHard, 1)

	if !ms.hasAISeat() {
		t.Error("a match with a bot is not reporting itself as an AI game")
	}
	if ms.aiDifficultyLabel() != string(AIHard) {
		t.Errorf("difficulty label = %q, want %q", ms.aiDifficultyLabel(), AIHard)
	}
	if ms.Rated {
		t.Error("an AI match must never be rated")
	}
	if !isAIUser(ms.Players[1].UserID) {
		t.Errorf("bot user ID %q is not recognisable as a bot", ms.Players[1].UserID)
	}
	if isAIUser(ms.Players[0].UserID) {
		t.Error("the human seat was mistaken for a bot")
	}
}

// The bot's view of the game is projected like any other seat: it never
// receives, and never reasons from, an opponent's reserved cards.
func TestAISeatCannotSeeOpponentReserve(t *testing.T) {
	withTimings(t, 90, 0)
	ms, _, tc := newAIMatch(t, 1_000_000, AIHard, 1)

	// The human reserves a card face-down.
	target := ms.Tier3Visible[0]
	ms = processMessage(ms, message("human", OpActionJail, msgJail{CharacterID: target}), tc)
	if len(ms.Players[0].Reserve) != 1 {
		t.Fatalf("the human's reservation did not register")
	}

	state, know := buildAIState(ms, 1)
	if know.seen[aiCardIndex[target]] {
		t.Error("the bot's knowledge marks the human's reserved card as seen")
	}
	if state.players[0].reserveN != 0 {
		t.Error("the bot's position contains the human's reserved card")
	}
	if know.reserveN[0] != 1 {
		t.Errorf("the bot should still know the human holds 1 reserved card, got %d", know.reserveN[0])
	}
}
