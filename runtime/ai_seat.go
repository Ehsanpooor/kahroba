package main

import (
	"encoding/json"
	"fmt"
	"math/rand"
	"time"

	"github.com/heroiclabs/nakama-common/runtime"
)

// ai_seat.go — an AI opponent occupying a real seat in an authoritative match.
//
// The bot is not a client and not a parallel rules implementation. It picks a
// move, encodes it as the same op code a human would send, and posts it through
// processMessage. Everything the server enforces for a person is therefore
// enforced for the bot: it cannot overspend, cannot act out of turn, and cannot
// touch a card it has not legitimately reserved. If the engine ever proposes an
// illegal move the match rejects it exactly as it would reject a cheating
// client, and the fallback below keeps the game moving.

// aiUserPrefix marks the synthetic user IDs of AI seats. They are never real
// Nakama accounts, so nothing writes rating or history against them.
const aiUserPrefix = "ai:"

var aiNames = []string{
	"Lucia", "Marco", "Pietro", "Elena",
	"Lorenzo", "Giulia", "Anton", "Bianca",
}

func aiSeatUserID(seat int) string { return fmt.Sprintf("%s%d", aiUserPrefix, seat) }

func isAIUser(userID string) bool {
	return len(userID) > len(aiUserPrefix) && userID[:len(aiUserPrefix)] == aiUserPrefix
}

// newAIPlayer builds a seated bot.
func newAIPlayer(seat int, difficulty AIDifficulty, rng *rand.Rand) PlayerState {
	name := aiNames[seat%len(aiNames)]
	if rng != nil {
		name = aiNames[rng.Intn(len(aiNames))]
	}
	p := newPlayerState(aiSeatUserID(seat), name)
	p.Disconnected = false // a bot is never absent
	p.IsAI = true
	p.AIDifficulty = string(difficulty)
	return p
}

// hasAISeat reports whether this match contains any bot, which makes it an AI
// game for history and rating purposes.
func (ms *MatchState) hasAISeat() bool {
	for i := range ms.Players {
		if ms.Players[i].IsAI {
			return true
		}
	}
	return false
}

// aiDifficultyLabel returns the difficulty of the first bot, for the history record.
func (ms *MatchState) aiDifficultyLabel() string {
	for i := range ms.Players {
		if ms.Players[i].IsAI {
			return ms.Players[i].AIDifficulty
		}
	}
	return ""
}

// random lazily provides the match's generator. MatchState literals in tests do
// not run through NewMatchState, so this must tolerate a nil field.
func (ms *MatchState) random() *rand.Rand {
	if ms.rng == nil {
		ms.rng = newRNG()
	}
	return ms.rng
}

// scheduleAIThink sets when the bot on turn may act. A move that lands the
// instant the player's own does feels like a scripted response rather than an
// opponent, so every bot pauses for a spread of time drawn from its profile.
func scheduleAIThink(ms *MatchState, nowMs int64) {
	ms.AIThinkUntilMs = 0
	if ms.CurrentTurn < 0 || ms.CurrentTurn >= len(ms.Players) {
		return
	}
	p := &ms.Players[ms.CurrentTurn]
	if !p.IsAI {
		return
	}
	profile := profileFor(normalizeDifficulty(p.AIDifficulty))
	spread := profile.thinkMax - profile.thinkMin
	pause := profile.thinkMin
	if spread > 0 {
		pause += time.Duration(ms.random().Int63n(int64(spread)))
	}
	ms.AIThinkUntilMs = nowMs + pause.Milliseconds()
}

// driveAISeat plays the bot's turn when its thinking time is up. It returns the
// state unchanged when the seat on turn is human or still thinking.
func driveAISeat(ms *MatchState, tc turnCtx) *MatchState {
	if ms.Phase != PhasePlaying && ms.Phase != PhaseFinalRound {
		return ms
	}
	seat := ms.CurrentTurn
	if seat < 0 || seat >= len(ms.Players) || !ms.Players[seat].IsAI {
		return ms
	}
	if ms.AIThinkUntilMs == 0 {
		scheduleAIThink(ms, tc.now)
		return ms
	}
	if tc.now < ms.AIThinkUntilMs {
		return ms
	}

	difficulty := normalizeDifficulty(ms.Players[seat].AIDifficulty)
	userID := ms.Players[seat].UserID

	// Boxed in by the coin limit with a full reserve and nothing affordable:
	// there is no move to search for, so pass straight away rather than make the
	// human wait out the bot's turn clock.
	if !ms.HasLegalAction(seat) {
		return passTurn(ms, tc)
	}

	state, know := buildAIState(ms, seat)
	decision := chooseMove(state, know, difficulty, ms.random())
	op, payload := actionFor(decision.move)

	tc.logger.Debug("ai seat=%d difficulty=%s sims=%d took=%s op=%d",
		seat, difficulty, decision.simulations, decision.elapsed, op)

	return submitAIAction(ms, tc, userID, op, payload, seat)
}

// submitAIAction posts the bot's move through the normal validation path and
// verifies that it actually took effect.
func submitAIAction(ms *MatchState, tc turnCtx, userID string, op int64, payload interface{}, seat int) *MatchState {
	data, err := json.Marshal(payload)
	if err != nil {
		tc.logger.Error("ai seat=%d could not encode its move: %v", seat, err)
		return aiFallback(ms, tc, userID, seat)
	}

	before, beforePhase, beforeTurnNo := ms.CurrentTurn, ms.Phase, ms.TurnNumber
	ms = processMessage(ms, aiMatchData{userID: userID, opCode: op, data: data}, tc)

	// A rejected bot move would otherwise stall the match until the turn timer
	// fired, so treat "nothing changed" as a bug and take a guaranteed-legal
	// action instead. This has to be impossible to hit; it exists so that if it
	// ever is hit, the game continues and the log says so.
	if ms.Phase == beforePhase && ms.CurrentTurn == before && ms.TurnNumber == beforeTurnNo && ms.Phase != PhaseEnded {
		tc.logger.Error("ai seat=%d move op=%d was rejected: %s", seat, op, string(data))
		return aiFallback(ms, tc, userID, seat)
	}
	return ms
}

// aiFallback plays the simplest legal action available, in the order most
// likely to succeed. Every attempt respects the coin hold limit, so none of
// them can be refused with coin_limit. Conceding is the last resort and only
// when the bot somehow cannot act at all.
func aiFallback(ms *MatchState, tc turnCtx, userID string, seat int) *MatchState {
	if !ms.HasLegalAction(seat) {
		return passTurn(ms, tc)
	}
	acted := func(op int64, payload interface{}) bool {
		data, _ := json.Marshal(payload)
		before, turnNo := ms.CurrentTurn, ms.TurnNumber
		ms = processMessage(ms, aiMatchData{userID: userID, opCode: op, data: data}, tc)
		return ms.CurrentTurn != before || ms.TurnNumber != turnNo || ms.Phase == PhaseEnded
	}

	// Up to three distinct colours the supply can still pay out, capped by the
	// room left under the hold limit.
	room := CoinRoom(ms.Players[seat].Coins)
	var elements []Element
	for _, e := range AllElements {
		if ms.Supply[e] > 0 && len(elements) < MaxHarvestCoins && len(elements) < room {
			elements = append(elements, e)
		}
	}
	if len(elements) > 0 && acted(OpActionHarvest, msgHarvest{Elements: elements}) {
		return ms
	}

	// Any affordable card, then a reservation (legal even at the hold limit).
	p := &ms.Players[seat]
	bonus := AffinityBonus(p.HiredCards)
	for _, id := range append(ms.AllVisibleCards(), p.ReserveIDs()...) {
		if c := cardByID[id]; c != nil && CanAfford(p.Coins, CalculateActualCost(c.HireCost, bonus)) {
			if acted(OpActionHire, msgHire{CharacterID: id}) {
				return ms
			}
			break
		}
	}
	if len(p.Reserve) < MaxReserve {
		for tier := 1; tier <= 3; tier++ {
			if ms.DeckCount(tier) > 0 && acted(OpActionJail, msgJail{Tier: tier}) {
				return ms
			}
		}
		if visible := ms.AllVisibleCards(); len(visible) > 0 && acted(OpActionJail, msgJail{CharacterID: visible[0]}) {
			return ms
		}
	}

	tc.logger.Error("ai seat=%d has no legal action; conceding to keep the match alive", seat)
	return handleConcede(ms, userID, tc)
}

// ---------- synthetic match message ----------

// aiMatchData lets the bot's move travel the same route as a client message.
type aiMatchData struct {
	userID string
	opCode int64
	data   []byte
}

func (m aiMatchData) GetHidden() bool                   { return false }
func (m aiMatchData) GetPersistence() bool              { return false }
func (m aiMatchData) GetUsername() string               { return m.userID }
func (m aiMatchData) GetStatus() string                 { return "" }
func (m aiMatchData) GetReason() runtime.PresenceReason { return runtime.PresenceReasonUnknown }
func (m aiMatchData) GetUserId() string                 { return m.userID }
func (m aiMatchData) GetSessionId() string              { return "" }
func (m aiMatchData) GetNodeId() string                 { return "" }
func (m aiMatchData) GetOpCode() int64                  { return m.opCode }
func (m aiMatchData) GetData() []byte                   { return m.data }
func (m aiMatchData) GetReliable() bool                 { return true }
func (m aiMatchData) GetReceiveTime() int64             { return 0 }
