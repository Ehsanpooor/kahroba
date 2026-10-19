package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// match_flow_test.go — regressions for the six match-flow defects found in the
// 2026-09-05 review. Each of these failed against the previous implementation.

// harvest is a legal, always-available action used to pass a turn in tests.
func harvest(ms *MatchState, tc turnCtx, userID string) *MatchState {
	return processMessage(ms, message(userID, OpActionHarvest, msgHarvest{
		Elements: []Element{ELight, EWater, ENature},
	}), tc)
}

// ---------- Final round ----------

// The last seat reaching the threshold ends the game at once: the round is
// already complete, so nobody is owed another turn.
func TestFinalRound_LastSeatTriggerEndsImmediately(t *testing.T) {
	withTimings(t, 90, 0)
	ms, _, tc := newTestMatch(t, 1_000_000, "u0", "u1", "u2")

	ms.CurrentTurn = 2
	givePower(ms, 2, WinThreshold)
	ms = harvest(ms, tc, "u2")

	if ms.Phase != PhaseEnded {
		t.Fatalf("phase = %q after the last seat crossed the threshold, want %q", ms.Phase, PhaseEnded)
	}
	if ms.WinnerIndex != 2 {
		t.Errorf("winnerIndex = %d, want 2", ms.WinnerIndex)
	}
}

// The first seat reaching the threshold owes every later seat exactly one turn,
// and then the game ends.
func TestFinalRound_EveryoneGetsEqualTurns(t *testing.T) {
	withTimings(t, 90, 0)
	ms, _, tc := newTestMatch(t, 1_000_000, "u0", "u1", "u2")

	givePower(ms, 0, WinThreshold)
	ms = harvest(ms, tc, "u0")
	if ms.Phase != PhaseFinalRound {
		t.Fatalf("phase = %q after seat 0 crossed the threshold, want %q", ms.Phase, PhaseFinalRound)
	}

	ms = harvest(ms, tc, "u1")
	if ms.Phase == PhaseEnded {
		t.Fatal("game ended before seat 2 had its turn in the final round")
	}
	ms = harvest(ms, tc, "u2")
	if ms.Phase != PhaseEnded {
		t.Fatalf("phase = %q after the final round completed, want %q", ms.Phase, PhaseEnded)
	}

	for i := range ms.Players {
		if got := ms.Players[i].TurnsTaken; got != 1 {
			t.Errorf("seat %d took %d turns, want 1 — the round must be equal for everyone", i, got)
		}
	}
}

// A second-seat trigger in a 2-player game must not hand seat 0 a free extra turn.
func TestFinalRound_SecondSeatTriggerGivesNoExtraTurn(t *testing.T) {
	withTimings(t, 90, 0)
	ms, _, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	ms = harvest(ms, tc, "u0") // seat 0 plays a normal turn first
	givePower(ms, 1, WinThreshold)
	ms = harvest(ms, tc, "u1")

	if ms.Phase != PhaseEnded {
		t.Fatalf("phase = %q, want %q: the round was complete when seat 1 triggered", ms.Phase, PhaseEnded)
	}
	if ms.Players[0].TurnsTaken != ms.Players[1].TurnsTaken {
		t.Errorf("turns taken %d vs %d — seat 0 was given an extra turn",
			ms.Players[0].TurnsTaken, ms.Players[1].TurnsTaken)
	}
}

// The game must still end if the player who triggered the final round then
// concedes, which previously deadlocked because play never returned to them.
func TestFinalRound_TriggerPlayerConcedes(t *testing.T) {
	withTimings(t, 90, 0)
	ms, _, tc := newTestMatch(t, 1_000_000, "u0", "u1", "u2")

	givePower(ms, 0, WinThreshold)
	ms = harvest(ms, tc, "u0")
	if ms.Phase != PhaseFinalRound {
		t.Fatalf("expected the final round to start, got %q", ms.Phase)
	}

	ms = handleConcede(ms, "u0", tc)
	if ms.Phase == PhaseEnded {
		t.Fatal("the match ended early: two players were still in the final round")
	}

	ms = harvest(ms, tc, "u1")
	ms = harvest(ms, tc, "u2")

	if ms.Phase != PhaseEnded {
		t.Fatalf("phase = %q: the final round never completed after the trigger player conceded", ms.Phase)
	}
}

// ---------- Concede ----------

// Conceding is a loss whatever the scoreboard says.
func TestConcede_ConcederNeverWins(t *testing.T) {
	withTimings(t, 90, 0)
	ms, _, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	givePower(ms, 0, 12) // the quitter is far ahead
	givePower(ms, 1, 1)

	ms = handleConcede(ms, "u0", tc)

	if ms.Phase != PhaseEnded {
		t.Fatalf("phase = %q after the only opponent conceded, want %q", ms.Phase, PhaseEnded)
	}
	if ms.WinnerIndex != 1 {
		t.Errorf("winnerIndex = %d, want 1 — a player who concedes cannot win on Power", ms.WinnerIndex)
	}
	if ms.EndReason != EndReasonLastStanding {
		t.Errorf("endReason = %q, want %q", ms.EndReason, EndReasonLastStanding)
	}

	standings, winner := ComputeStandings(ms.Players)
	if winner != 1 || standings[0].Index != 1 {
		t.Errorf("standings put the conceding player first: %+v", standings)
	}
}

// Conceding on your own turn hands the next player a full clock, not the
// remainder of the quitter's.
func TestConcede_GivesNextPlayerAFullClock(t *testing.T) {
	withTimings(t, 90, 0)
	const start = int64(1_000_000)
	ms, _, tc := newTestMatch(t, start, "u0", "u1", "u2")

	concededAt := start + 70_000
	ms = handleConcede(ms, "u0", tc.at(concededAt))

	if ms.CurrentTurn != 1 {
		t.Fatalf("CurrentTurn = %d after seat 0 conceded on its own turn, want 1", ms.CurrentTurn)
	}
	if got, want := ms.TurnDeadlineMs-concededAt, int64(90_000); got != want {
		t.Errorf("seat 1 got %d ms, want %d — it inherited the quitter's remaining time", got, want)
	}
}

// ---------- Coin hold limit (house rule) ----------
//
// Veynoria blocks a take that would exceed 10 coins instead of following
// Splendor's "take, then return the excess". These tests drive the real match
// handler; rules_test.go covers the validators in isolation.

// lastRejection decodes the most recent ACTION_REJECTED, if any.
func lastRejection(t *testing.T, disp *mockDispatcher) (msgRejected, bool) {
	t.Helper()
	b, ok := disp.lastOfOp(OpActionRejected)
	if !ok {
		return msgRejected{}, false
	}
	var rej msgRejected
	if err := json.Unmarshal(b.data, &rej); err != nil {
		t.Fatalf("ACTION_REJECTED did not decode: %v", err)
	}
	return rej, true
}

// A harvest that would take the player above 10 coins is refused with
// coin_limit, and nothing moves: not the coins, not the supply, not the turn.
func TestHarvestOverCoinLimitIsRejected(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	ms.Players[0].Coins = Cost{EFire: 4, EShadow: 4} // 8: room for 2
	supplyBefore := TotalCoins(ms.Supply)
	disp.reset()

	ms = harvest(ms, tc, "u0") // 3 coins would make 11

	rej, ok := lastRejection(t, disp)
	if !ok || rej.Code != ErrCoinLimit {
		t.Fatalf("rejection = %+v (sent=%v), want %s", rej, ok, ErrCoinLimit)
	}
	if b, _ := disp.lastOfOp(OpActionRejected); b.recipient != "u0" {
		t.Errorf("coin_limit rejection went to %q, want only u0", b.recipient)
	}
	if total := TotalCoins(ms.Players[0].Coins); total != 8 {
		t.Errorf("seat 0 holds %d coins after a rejected harvest, want 8", total)
	}
	if got := TotalCoins(ms.Supply); got != supplyBefore {
		t.Errorf("supply changed from %d to %d on a rejected harvest", supplyBefore, got)
	}
	if ms.CurrentTurn != 0 || ms.Players[0].TurnsTaken != 0 {
		t.Error("the turn advanced on a rejected harvest")
	}
}

// Taking fewer coins to land exactly on the limit is legal.
func TestHarvestUpToTheCoinLimit(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	ms.Players[0].Coins = Cost{EFire: 4, EShadow: 4} // 8
	disp.reset()
	ms = processMessage(ms, message("u0", OpActionHarvest, msgHarvest{
		Elements: []Element{ELight, EWater},
	}), tc)

	if rej, ok := lastRejection(t, disp); ok {
		t.Fatalf("a harvest to exactly 10 coins was rejected: %+v", rej)
	}
	if total := TotalCoins(ms.Players[0].Coins); total != MaxCoins {
		t.Errorf("seat 0 holds %d coins, want %d", total, MaxCoins)
	}
	if ms.CurrentTurn != 1 {
		t.Errorf("CurrentTurn = %d, want 1", ms.CurrentTurn)
	}
}

// At 10 coins not even a single coin may be taken.
func TestHarvestAtTheCoinLimitIsRejected(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	ms.Players[0].Coins = Cost{ELight: 4, EWater: 3, ENature: 3}
	disp.reset()
	ms = processMessage(ms, message("u0", OpActionHarvest, msgHarvest{Elements: []Element{EFire}}), tc)

	if rej, ok := lastRejection(t, disp); !ok || rej.Code != ErrCoinLimit {
		t.Fatalf("rejection = %+v (sent=%v), want %s", rej, ok, ErrCoinLimit)
	}
	if ms.CurrentTurn != 0 {
		t.Error("the turn advanced on a rejected harvest")
	}
}

// Channel at 9 coins would make 11: refused, state untouched.
func TestChannelOverCoinLimitIsRejected(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1") // 2 players: 4 per colour, enough to channel

	ms.Players[0].Coins = Cost{ELight: 3, EWater: 3, ENature: 3} // 9
	fireBefore := ms.Supply[EFire]
	disp.reset()
	ms = processMessage(ms, message("u0", OpActionChannel, msgChannel{Element: EFire}), tc)

	if rej, ok := lastRejection(t, disp); !ok || rej.Code != ErrCoinLimit {
		t.Fatalf("rejection = %+v (sent=%v), want %s", rej, ok, ErrCoinLimit)
	}
	if ms.Players[0].Coins[EFire] != 0 || ms.Supply[EFire] != fireBefore {
		t.Error("a rejected channel still moved coins")
	}
	if ms.CurrentTurn != 0 {
		t.Error("the turn advanced on a rejected channel")
	}
}

// Reserving at 10 coins is legal but grants no Aether: the card goes to the
// reserve, the Aether stays in the supply, and the turn passes.
func TestJailAtCoinLimitGrantsNoAether(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	ms.Players[0].Coins = Cost{ELight: 4, EWater: 3, ENature: 3} // 10
	aetherBefore := ms.AetherSupply
	target := ms.Tier1Visible[0]
	disp.reset()
	ms = processMessage(ms, message("u0", OpActionJail, msgJail{CharacterID: target}), tc)

	if rej, ok := lastRejection(t, disp); ok {
		t.Fatalf("reserving at 10 coins was rejected: %+v", rej)
	}
	if len(ms.Players[0].Reserve) != 1 || ms.Players[0].Reserve[0].CardID != target {
		t.Errorf("reserve = %+v, want just %s", ms.Players[0].Reserve, target)
	}
	if ms.Players[0].Coins[EAether] != 0 || TotalCoins(ms.Players[0].Coins) != MaxCoins {
		t.Errorf("coins = %v; reserving at the limit must not grant Aether", ms.Players[0].Coins)
	}
	if ms.AetherSupply != aetherBefore {
		t.Errorf("Aether supply went from %d to %d; it must stay put", aetherBefore, ms.AetherSupply)
	}
	if ms.CurrentTurn != 1 {
		t.Errorf("CurrentTurn = %d, want 1", ms.CurrentTurn)
	}
}

// Reserving at 9 coins still grants the Aether, landing exactly on 10.
func TestJailBelowCoinLimitGrantsAether(t *testing.T) {
	withTimings(t, 90, 0)
	ms, _, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	ms.Players[0].Coins = Cost{ELight: 3, EWater: 3, ENature: 3} // 9
	aetherBefore := ms.AetherSupply
	ms = processMessage(ms, message("u0", OpActionJail, msgJail{Tier: 2}), tc)

	if ms.Players[0].Coins[EAether] != 1 || TotalCoins(ms.Players[0].Coins) != MaxCoins {
		t.Errorf("coins = %v, want 1 Aether and 10 in total", ms.Players[0].Coins)
	}
	if ms.AetherSupply != aetherBefore-1 {
		t.Errorf("Aether supply = %d, want %d", ms.AetherSupply, aetherBefore-1)
	}
}

// Op 5 used to be RETURN_COINS. It is retired, so an old client sending it gets
// a clean unknown_action and the game does not move.
func TestRetiredReturnCoinsOpIsUnknown(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	ms.Players[0].Coins = Cost{ELight: 4, EWater: 3, ENature: 3}
	disp.reset()
	ms = processMessage(ms, message("u0", OpRetiredReturnCoins, map[string]interface{}{
		"coins": Cost{ELight: 1},
	}), tc)

	if rej, ok := lastRejection(t, disp); !ok || rej.Code != ErrUnknownAction {
		t.Fatalf("rejection = %+v (sent=%v), want %s", rej, ok, ErrUnknownAction)
	}
	if TotalCoins(ms.Players[0].Coins) != MaxCoins || ms.CurrentTurn != 0 {
		t.Error("the retired op changed the game state")
	}
}

// The state sent to clients no longer carries the return-coins fields.
func TestStateHasNoReturnCoinsFields(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")
	broadcastState(ms, tc.dispatcher, tc.now)
	b, _ := disp.lastOfOp(OpStateFull)
	for _, key := range []string{"awaitReturnCoins", "awaitReturnSeat"} {
		if strings.Contains(string(b.data), key) {
			t.Errorf("STATE_FULL still carries %q", key)
		}
	}
}

// ---------- Hidden information ----------

// A reserved card is private. Opponents learn that a card was reserved and from
// which tier, never which card it is.
func TestReserveIsHiddenFromOpponents(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	target := ms.Tier1Visible[0]
	ms = processMessage(ms, message("u0", OpActionJail, msgJail{CharacterID: target}), tc)
	if len(ms.Players[0].Reserve) != 1 {
		t.Fatalf("reserve holds %d cards, want 1", len(ms.Players[0].Reserve))
	}

	own := disp.lastStateFor(t, "u0")
	if own.Players[0].Reserve[0].CardID != target {
		t.Errorf("the owner cannot see their own reserved card: %+v", own.Players[0].Reserve[0])
	}

	opp := disp.lastStateFor(t, "u1")
	if got := opp.Players[0].Reserve[0].CardID; got != "" {
		t.Errorf("opponent can see the reserved card %q — reserves must be private", got)
	}
	if opp.Players[0].ReserveCount != 1 {
		t.Errorf("opponent sees reserveCount = %d, want 1", opp.Players[0].ReserveCount)
	}
	if opp.Players[0].Reserve[0].Tier != 1 {
		t.Errorf("opponent should still see the tier, got %d", opp.Players[0].Reserve[0].Tier)
	}
}

// A blind draw is hidden from opponents too, and never appears anywhere in the
// bytes they receive.
func TestBlindDrawNeverReachesOpponents(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	ms = processMessage(ms, message("u0", OpActionJail, msgJail{Tier: 3}), tc)
	drawn := ms.Players[0].Reserve[0].CardID
	if drawn == "" {
		t.Fatal("the blind draw produced no card")
	}

	for _, b := range disp.broadcasts {
		if b.recipient == "u0" || b.opCode != OpStateFull {
			continue
		}
		if strings.Contains(string(b.data), drawn) {
			t.Fatalf("the blind-drawn card %s leaked to %s", drawn, b.recipient)
		}
	}
}

// The draw piles never leave the server: clients get counts, not card IDs.
func TestDeckOrderNeverLeavesTheServer(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	broadcastState(ms, tc.dispatcher, tc.now)
	view := disp.lastStateFor(t, "u0")

	if view.Tier1Count != len(ms.Tier1Deck) {
		t.Errorf("tier1Count = %d, want %d", view.Tier1Count, len(ms.Tier1Deck))
	}

	b, _ := disp.lastOfOp(OpStateFull)
	raw := string(b.data)
	for _, key := range []string{"tier1Deck", "tier2Deck", "tier3Deck"} {
		if strings.Contains(raw, key) {
			t.Errorf("STATE_FULL still carries %q", key)
		}
	}
	// Spot-check that a specific undrawn card is absent from the payload.
	if len(ms.Tier1Deck) > 0 && strings.Contains(raw, ms.Tier1Deck[len(ms.Tier1Deck)-1]) {
		t.Error("a card from the bottom of the tier 1 deck appears in the client payload")
	}
}

// A rejection is addressed to the player who caused it, not to the table.
func TestRejectionIsPrivate(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	disp.reset()
	_ = harvest(ms, tc, "u1") // not seat 1's turn

	b, ok := disp.lastOfOp(OpActionRejected)
	if !ok {
		t.Fatal("no rejection was sent")
	}
	if b.recipient != "u1" {
		t.Errorf("rejection went to %q, want only u1", b.recipient)
	}
	var rej msgRejected
	_ = json.Unmarshal(b.data, &rej)
	if rej.Code != ErrNotYourTurn {
		t.Errorf("rejection code = %q, want %q", rej.Code, ErrNotYourTurn)
	}
}

// ---------- Actions ----------

// Hiring from the reserve removes the card from hand and does not touch the board.
func TestHireFromReserve(t *testing.T) {
	withTimings(t, 90, 0)
	ms, _, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	// Reserve a cheap tier 1 card, then hand the player enough coins to buy it.
	target := ms.Tier1Visible[0]
	ms = processMessage(ms, message("u0", OpActionJail, msgJail{CharacterID: target}), tc)

	card := cardByID[target]
	ms.CurrentTurn = 0
	ms.Players[0].Coins = Cost{}
	for elem, qty := range card.HireCost {
		ms.Players[0].Coins[elem] = qty
	}

	boardBefore := len(ms.AllVisibleCards())
	ms = processMessage(ms, message("u0", OpActionHire, msgHire{CharacterID: target, FromReserve: true}), tc)

	if len(ms.Players[0].Reserve) != 0 {
		t.Errorf("the card is still in the reserve after being hired")
	}
	if len(ms.Players[0].HiredCards) != 1 || ms.Players[0].HiredCards[0].ID != target {
		t.Errorf("hired tableau = %+v, want just %s", ms.Players[0].HiredCards, target)
	}
	if got := len(ms.AllVisibleCards()); got != boardBefore {
		t.Errorf("board size changed from %d to %d when hiring out of hand", boardBefore, got)
	}
}

// Taking a face-up card refills its slot in place, so the board keeps its shape.
func TestBoardRefillsInPlace(t *testing.T) {
	withTimings(t, 90, 0)
	ms, _, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	target := ms.Tier2Visible[1]
	deckBefore := len(ms.Tier2Deck)

	ms = processMessage(ms, message("u0", OpActionJail, msgJail{CharacterID: target}), tc)

	if len(ms.Tier2Visible) != 4 {
		t.Errorf("tier 2 shows %d cards after a reservation, want 4", len(ms.Tier2Visible))
	}
	if ms.Tier2Visible[1] == target {
		t.Error("the reserved card is still face-up")
	}
	if len(ms.Tier2Deck) != deckBefore-1 {
		t.Errorf("tier 2 deck went from %d to %d, want one card drawn", deckBefore, len(ms.Tier2Deck))
	}
	if ms.Players[0].Coins[EAether] != 1 {
		t.Errorf("reserving should grant 1 Aether, got %d", ms.Players[0].Coins[EAether])
	}
}

// Harvesting fewer than three coins is legal, which players need in order to
// stay under the hold limit.
func TestHarvestFewerThanThree(t *testing.T) {
	withTimings(t, 90, 0)
	ms, disp, tc := newTestMatch(t, 1_000_000, "u0", "u1")

	disp.reset()
	ms = processMessage(ms, message("u0", OpActionHarvest, msgHarvest{Elements: []Element{ELight}}), tc)

	if n := disp.countOfOp(OpActionRejected); n != 0 {
		b, _ := disp.lastOfOp(OpActionRejected)
		t.Fatalf("a single-coin harvest was rejected: %s", string(b.data))
	}
	if ms.Players[0].Coins[ELight] != 1 {
		t.Errorf("player holds %d Light, want 1", ms.Players[0].Coins[ELight])
	}
	if ms.CurrentTurn != 1 {
		t.Errorf("the turn did not pass after a legal harvest")
	}
}

// ---------- Lobby ----------

// A match nobody finishes joining is cancelled rather than left to rot.
func TestLobbyTimeoutCancelsTheMatch(t *testing.T) {
	withTimings(t, 90, 0)

	ms := NewMatchState([]string{"u0", "u1"}, []string{"A", "B"}, true, 2)
	ms.Players[0].Disconnected = false
	ms.trackPresence(presenceFor("u0"))
	ms.LobbyDeadlineMs = 1_000_000

	disp := &mockDispatcher{}
	tc := turnCtx{ctx: testContext(), logger: &mockLogger{t}, dispatcher: disp, now: 1_000_001}

	ms = checkLobbyTimeout(ms, tc)

	if ms.Phase != PhaseEnded {
		t.Fatalf("phase = %q, want %q", ms.Phase, PhaseEnded)
	}
	if ms.EndReason != EndReasonLobbyTimeout {
		t.Errorf("endReason = %q, want %q", ms.EndReason, EndReasonLobbyTimeout)
	}
	if ms.WinnerIndex != -1 {
		t.Errorf("a cancelled lobby must have no winner, got %d", ms.WinnerIndex)
	}
}

// ---------- MatchInit parameters ----------

// Match parameters arrive as native Go types on one path and JSON-decoded types
// on another. Both must produce the same table.
func TestMatchInitAcceptsBothParameterShapes(t *testing.T) {
	m := &SplendorMatch{}

	native := map[string]interface{}{
		"rated":       true,
		"userIds":     []string{"a", "b", "c"},
		"names":       []string{"A", "B", "C"},
		"playerCount": 3,
	}
	decoded := map[string]interface{}{
		"rated":       true,
		"userIds":     []interface{}{"a", "b", "c"},
		"names":       []interface{}{"A", "B", "C"},
		"playerCount": float64(3),
	}

	for label, params := range map[string]map[string]interface{}{"native": native, "decoded": decoded} {
		state, _, _ := m.MatchInit(testContext(), &mockLogger{t}, nil, nil, params)
		ms, ok := state.(*MatchState)
		if !ok {
			t.Fatalf("%s: MatchInit did not return a MatchState", label)
		}
		if len(ms.Players) != 3 {
			t.Errorf("%s: seated %d players, want 3", label, len(ms.Players))
		}
		if ms.ExpectedPlayerCount != 3 {
			t.Errorf("%s: expectedPlayerCount = %d, want 3", label, ms.ExpectedPlayerCount)
		}
		if got := ms.Supply[ELight]; got != 5 {
			t.Errorf("%s: 3-player supply = %d per colour, want 5", label, got)
		}
		if len(ms.Artifacts) != 4 {
			t.Errorf("%s: revealed %d artifacts, want 4", label, len(ms.Artifacts))
		}
	}
}
