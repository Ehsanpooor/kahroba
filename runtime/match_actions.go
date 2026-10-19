package main

import (
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

// match_actions.go — the four player actions.
//
// There is no coin-return step: the 10-coin hold limit is a hard block checked
// before a take (house rule, see rules.go), so a legal action can never leave a
// player over the limit. Op 5 (the old RETURN_COINS) stays reserved and is
// rejected as unknown_action.
//
// Every handler validates against the rules engine before touching state, and
// nothing here trusts a number the client sent. The client's declared Aether
// spend and card source are hints for its own UI; the server recomputes both.

type msgHarvest struct {
	Elements []Element `json:"elements"`
}

type msgChannel struct {
	Element Element `json:"element"`
}

type msgHire struct {
	CharacterID string `json:"characterId"`
	FromReserve bool   `json:"fromReserve"` // hint only; the server derives the real source
	AetherUse   int    `json:"aetherUse"`   // hint only; the server computes the real spend
}

type msgJail struct {
	CharacterID string `json:"characterId"` // "" = blind draw from Tier
	Tier        int    `json:"tier"`
}

// processMessage routes one inbound match message.
func processMessage(ms *MatchState, msg runtime.MatchData, tc turnCtx) *MatchState {
	senderID := msg.GetUserId()
	op := msg.GetOpCode()

	// A reconnecting client can ask for its state at any time.
	if op == OpSyncRequest {
		sendState(ms, tc.dispatcher, senderID, tc.now)
		return ms
	}

	if op == OpConcede {
		return handleConcede(ms, senderID, tc)
	}

	// READY is only meaningful during the ready check and is otherwise
	// ignored without a rejection (a late or repeated READY is harmless).
	if op == OpReady {
		return handleReady(ms, senderID, tc)
	}

	if ms.Phase != PhasePlaying && ms.Phase != PhaseFinalRound {
		rejectCode(ms, tc.dispatcher, senderID, ErrGameNotRunning, "the match is not in progress")
		return ms
	}

	seat := ms.SeatOf(senderID)
	if seat < 0 || seat != ms.CurrentTurn {
		rejectCode(ms, tc.dispatcher, senderID, ErrNotYourTurn, "it is not your turn")
		return ms
	}

	p := &ms.Players[seat]
	switch op {
	case OpActionHarvest:
		return handleHarvest(ms, p, msg.GetData(), tc)
	case OpActionChannel:
		return handleChannel(ms, p, msg.GetData(), tc)
	case OpActionHire:
		return handleHire(ms, p, msg.GetData(), tc)
	case OpActionJail:
		return handleJail(ms, p, msg.GetData(), tc)
	default: // includes the retired op 5 (RETURN_COINS)
		rejectCode(ms, tc.dispatcher, senderID, ErrUnknownAction, "unknown op code")
		return ms
	}
}

// handleHarvest — Action A: take up to 3 coins of different elements.
func handleHarvest(ms *MatchState, p *PlayerState, data []byte, tc turnCtx) *MatchState {
	var req msgHarvest
	if err := json.Unmarshal(data, &req); err != nil {
		rejectCode(ms, tc.dispatcher, p.UserID, ErrBadPayload, "invalid harvest payload")
		return ms
	}
	if err := ValidateHarvest(req.Elements, ms.Supply, p.Coins); err != nil {
		reject(ms, tc.dispatcher, p.UserID, err)
		return ms
	}
	for _, e := range req.Elements {
		p.Coins[e]++
		ms.Supply[e]--
	}
	return endOfTurn(ms, tc)
}

// handleChannel — Action B: take 2 coins of one element, supply permitting.
func handleChannel(ms *MatchState, p *PlayerState, data []byte, tc turnCtx) *MatchState {
	var req msgChannel
	if err := json.Unmarshal(data, &req); err != nil {
		rejectCode(ms, tc.dispatcher, p.UserID, ErrBadPayload, "invalid channel payload")
		return ms
	}
	if err := ValidateChannel(req.Element, ms.Supply, p.Coins); err != nil {
		reject(ms, tc.dispatcher, p.UserID, err)
		return ms
	}
	p.Coins[req.Element] += 2
	ms.Supply[req.Element] -= 2
	return endOfTurn(ms, tc)
}

// handleHire — Action C: pay for a card from the board or your own reserve.
func handleHire(ms *MatchState, p *PlayerState, data []byte, tc turnCtx) *MatchState {
	var req msgHire
	if err := json.Unmarshal(data, &req); err != nil {
		rejectCode(ms, tc.dispatcher, p.UserID, ErrBadPayload, "invalid hire payload")
		return ms
	}

	visible := ms.AllVisibleCards()
	spend, err := ValidateHire(req.CharacterID, p.Coins, p.ReserveIDs(), visible, p.HiredCards)
	if err != nil {
		reject(ms, tc.dispatcher, p.UserID, err)
		return ms
	}

	for elem, qty := range spend {
		p.Coins[elem] -= qty
		if p.Coins[elem] <= 0 {
			delete(p.Coins, elem)
		}
		if elem == EAether {
			ms.AetherSupply += qty
		} else {
			ms.Supply[elem] += qty
		}
	}

	p.HiredCards = append(p.HiredCards, *cardByID[req.CharacterID])

	// A reserved card is hired out of the hand; a board card is hired off the
	// table and its slot refills at once. Checking the reserve first matches
	// ValidateHire, which cannot have accepted a card from neither place.
	if !p.RemoveFromReserve(req.CharacterID) {
		ms.TakeVisible(req.CharacterID)
	}

	return endOfTurn(ms, tc)
}

// handleJail — Action D: reserve a card and take an Aether if one is left and
// the player is below the hold limit. Reserving at 10 coins is legal; it simply
// grants no Aether.
func handleJail(ms *MatchState, p *PlayerState, data []byte, tc turnCtx) *MatchState {
	var req msgJail
	if err := json.Unmarshal(data, &req); err != nil {
		rejectCode(ms, tc.dispatcher, p.UserID, ErrBadPayload, "invalid jail payload")
		return ms
	}

	visible := ms.AllVisibleCards()
	if err := ValidateJail(req.CharacterID, req.Tier, len(p.Reserve), visible); err != nil {
		reject(ms, tc.dispatcher, p.UserID, err)
		return ms
	}

	var cardID string
	fromBoard := req.CharacterID != ""
	if fromBoard {
		cardID = req.CharacterID
		ms.TakeVisible(cardID)
	} else {
		if cardID = ms.DrawBlindFromTier(req.Tier); cardID == "" {
			rejectCode(ms, tc.dispatcher, p.UserID, ErrDeckEmpty, "that tier deck is empty")
			return ms
		}
	}

	tier := 0
	if c := cardByID[cardID]; c != nil {
		tier = c.Tier
	}
	p.Reserve = append(p.Reserve, ReserveSlot{
		CardID:     cardID,
		Tier:       tier,
		FromBoard:  fromBoard,
		ReservedAt: tc.now,
	})

	if ReserveGrantsAether(p.Coins, ms.AetherSupply) {
		p.Coins[EAether]++
		ms.AetherSupply--
	}

	return endOfTurn(ms, tc)
}
