package main

import (
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

// match_broadcast.go — every outbound match message.
//
// State is projected per viewer (match_view.go) and delivered to that viewer's
// own socket, so no player ever receives another player's private information.
// Messages that concern one player (a rejection, a sync reply) are addressed to
// that player only; genuinely public events go to the table.

// Op codes — client to server (API_DOC §6.1).
const (
	OpActionHarvest int64 = 1
	OpActionChannel int64 = 2
	OpActionHire    int64 = 3
	OpActionJail    int64 = 4
	// 5 was RETURN_COINS, retired with the coin-limit house rule. The number is
	// reserved, never reused, and rejected as unknown_action.
	OpRetiredReturnCoins int64 = 5
	OpConcede            int64 = 6
	OpSyncRequest        int64 = 7
	// OpReady answers the pre-game ready check (match_ready.go). Empty payload.
	// Harmless outside the ready check, from a non-member, or when repeated.
	OpReady int64 = 8
)

// Op codes — server to client (API_DOC §6.2).
const (
	OpStateFull        int64 = 100
	OpStateDiff        int64 = 101
	OpTurnChange       int64 = 102
	OpActionRejected   int64 = 103
	OpArtifactClaimed  int64 = 104
	OpPlayerAbandoned  int64 = 105
	OpGameEnded        int64 = 106
	OpReadyState       int64 = 107 // ready-check roster and deadline, on every change
	OpRemovedFromMatch int64 = 108 // to one player: you are out of this match, return to the menu
	OpGameStarted      int64 = 109 // the ready check passed; carries firstSeat for the "who starts" reveal
)

// Reasons carried by REMOVED_FROM_MATCH (op 108).
const (
	RemovedReadyTimeout    = "ready_timeout"    // did not send READY in time
	RemovedLeft            = "left"             // left or conceded during the ready check
	RemovedSeatUnavailable = "seat_unavailable" // a refill seat was gone by the time the join landed
)

// readySeat is one seat in READY_STATE.
type readySeat struct {
	Seat        int    `json:"seat"`
	UserID      string `json:"userId"`      // "" while the seat is open
	DisplayName string `json:"displayName"` // "" while the seat is open
	AvatarID    string `json:"avatarId"`
	Ready       bool   `json:"ready"`
	IsAI        bool   `json:"isAI"`
	Rating      int    `json:"rating,omitempty"`
	Open        bool   `json:"open"`       // seat held for a replacement from the queue
	DeadlineMs  int64  `json:"deadlineMs"` // this seat's own deadline (ready or refill); 0 once ready
}

// msgReadyState is READY_STATE (op 107).
type msgReadyState struct {
	Seats        []readySeat `json:"seats"`
	ReadyCount   int         `json:"readyCount"`
	SeatCount    int         `json:"seatCount"`
	DeadlineMs   int64       `json:"deadlineMs"` // latest pending seat deadline: the countdown to show
	ServerNowMs  int64       `json:"serverNowMs"`
	ReadySeconds int         `json:"readySeconds"`
}

// msgRemovedFromMatch is REMOVED_FROM_MATCH (op 108).
type msgRemovedFromMatch struct {
	MatchID      string `json:"matchId"`
	Reason       string `json:"reason"`
	RatingChange int    `json:"ratingChange"` // always 0: a removed player never played
}

// msgGameStarted is GAME_STARTED (op 109).
type msgGameStarted struct {
	FirstSeat   int      `json:"firstSeat"`
	FirstPlayer string   `json:"firstPlayer"` // userId on seat firstSeat
	Seats       []string `json:"seats"`       // userId per seat, in seat order
	Rated       bool     `json:"rated"`
	ServerNowMs int64    `json:"serverNowMs"`
}

type msgRejected struct {
	Code   string `json:"code"`
	Reason string `json:"reason"`
}

type msgTurnChange struct {
	ActivePlayer string `json:"activePlayer"`
	PlayerIndex  int    `json:"playerIndex"`
	TurnNumber   int    `json:"turnNumber"`
	TurnDeadline int64  `json:"turnDeadline"` // seconds, existing contract
	DeadlineMs   int64  `json:"deadlineMs"`   // milliseconds, canonical
	ServerNowMs  int64  `json:"serverNowMs"`  // for a drift-free client countdown
	TurnSeconds  int    `json:"turnSeconds"`
}

type msgPlayerAbandoned struct {
	Player      string `json:"player"`
	PlayerIndex int    `json:"playerIndex"`
	MissedCount int    `json:"missedCount"`
	AutoLost    bool   `json:"autoLost"`
}

type msgArtifactClaimed struct {
	Player      string `json:"player"`
	PlayerIndex int    `json:"playerIndex"`
	ArtifactID  string `json:"artifactId"`
}

type msgGameEnded struct {
	WinnerIndex  int            `json:"winnerIndex"` // -1 = shared victory
	WinnerUserID string         `json:"winnerUserId"`
	Reason       EndReason      `json:"reason"`
	Standings    []Standing     `json:"standings"`
	RatingDeltas map[string]int `json:"ratingDeltas"`
}

// broadcastState sends each connected player their own projection of the game.
func broadcastState(ms *MatchState, dispatcher runtime.MatchDispatcher, nowMs int64) {
	for i := range ms.Players {
		uid := ms.Players[i].UserID
		pres, ok := ms.presenceOf(uid)
		if !ok {
			continue // disconnected; they get a fresh view on rejoin
		}
		payload, err := json.Marshal(ms.ViewFor(uid, nowMs))
		if err != nil {
			continue
		}
		_ = dispatcher.BroadcastMessage(OpStateFull, payload, []runtime.Presence{pres}, nil, true)
	}
}

// sendState delivers one player's projection to that player alone.
func sendState(ms *MatchState, dispatcher runtime.MatchDispatcher, userID string, nowMs int64) {
	pres, ok := ms.presenceOf(userID)
	if !ok {
		return
	}
	payload, err := json.Marshal(ms.ViewFor(userID, nowMs))
	if err != nil {
		return
	}
	_ = dispatcher.BroadcastMessage(OpStateFull, payload, []runtime.Presence{pres}, nil, true)
}

// sendStateTo delivers a projection to a presence that may not be seated yet,
// which is the case for the very first message after a socket joins.
func sendStateTo(ms *MatchState, dispatcher runtime.MatchDispatcher, pres runtime.Presence, nowMs int64) {
	payload, err := json.Marshal(ms.ViewFor(pres.GetUserId(), nowMs))
	if err != nil {
		return
	}
	_ = dispatcher.BroadcastMessageDeferred(OpStateFull, payload, []runtime.Presence{pres}, nil, true)
}

// broadcastTurnChange announces the active seat and the deadline it must act by.
func broadcastTurnChange(ms *MatchState, dispatcher runtime.MatchDispatcher, nowMs int64) {
	if ms.CurrentTurn < 0 || ms.CurrentTurn >= len(ms.Players) {
		return
	}
	p := ms.Players[ms.CurrentTurn]
	payload, err := json.Marshal(msgTurnChange{
		ActivePlayer: p.UserID,
		PlayerIndex:  ms.CurrentTurn,
		TurnNumber:   ms.TurnNumber,
		TurnDeadline: ms.TurnDeadlineUnix,
		DeadlineMs:   ms.TurnDeadlineMs,
		ServerNowMs:  nowMs,
		TurnSeconds:  TurnSeconds,
	})
	if err != nil {
		return
	}
	_ = dispatcher.BroadcastMessage(OpTurnChange, payload, nil, nil, true)
}

// reject tells one player why their action did not stand. Nobody else needs it.
func reject(ms *MatchState, dispatcher runtime.MatchDispatcher, userID string, err error) {
	code, reason := ErrUnknownAction, "action rejected"
	if re, ok := err.(*RuleError); ok {
		code, reason = re.Code, re.Message
	} else if err != nil {
		reason = err.Error()
	}
	payload, mErr := json.Marshal(msgRejected{Code: code, Reason: reason})
	if mErr != nil {
		return
	}
	if pres, ok := ms.presenceOf(userID); ok {
		_ = dispatcher.BroadcastMessage(OpActionRejected, payload, []runtime.Presence{pres}, nil, true)
	}
}

func rejectCode(ms *MatchState, dispatcher runtime.MatchDispatcher, userID, code, reason string) {
	reject(ms, dispatcher, userID, ruleErr(code, reason))
}

func broadcastArtifactClaimed(ms *MatchState, dispatcher runtime.MatchDispatcher, seat int, artifactID string) {
	payload, err := json.Marshal(msgArtifactClaimed{
		Player:      ms.Players[seat].UserID,
		PlayerIndex: seat,
		ArtifactID:  artifactID,
	})
	if err != nil {
		return
	}
	_ = dispatcher.BroadcastMessage(OpArtifactClaimed, payload, nil, nil, true)
}

func broadcastAbandoned(ms *MatchState, dispatcher runtime.MatchDispatcher, seat int, autoLost bool) {
	payload, err := json.Marshal(msgPlayerAbandoned{
		Player:      ms.Players[seat].UserID,
		PlayerIndex: seat,
		MissedCount: ms.Players[seat].MissedTurns,
		AutoLost:    autoLost,
	})
	if err != nil {
		return
	}
	_ = dispatcher.BroadcastMessage(OpPlayerAbandoned, payload, nil, nil, true)
}

func broadcastGameEnded(dispatcher runtime.MatchDispatcher, msg msgGameEnded) {
	payload, err := json.Marshal(msg)
	if err != nil {
		return
	}
	_ = dispatcher.BroadcastMessage(OpGameEnded, payload, nil, nil, true)
}

// readyStateMessage builds READY_STATE from the current seats.
func readyStateMessage(ms *MatchState, nowMs int64) msgReadyState {
	msg := msgReadyState{
		Seats:        make([]readySeat, len(ms.Players)),
		SeatCount:    len(ms.Players),
		ServerNowMs:  nowMs,
		ReadySeconds: ReadyTimeoutSeconds,
	}
	for i := range ms.Players {
		p := &ms.Players[i]
		seat := readySeat{
			Seat:        i,
			UserID:      p.UserID,
			DisplayName: p.DisplayName,
			AvatarID:    p.AvatarID,
			Ready:       p.Ready && !p.SeatOpen,
			IsAI:        p.IsAI && !p.Persona,
			Rating:      p.Rating,
			Open:        p.SeatOpen,
		}
		switch {
		case p.SeatOpen:
			seat.DeadlineMs = p.RefillDeadlineMs
		case !p.Ready:
			seat.DeadlineMs = p.ReadyDeadlineMs
		}
		if seat.Ready {
			msg.ReadyCount++
		}
		if seat.DeadlineMs > msg.DeadlineMs {
			msg.DeadlineMs = seat.DeadlineMs
		}
		msg.Seats[i] = seat
	}
	return msg
}

// broadcastReadyState tells the whole table who is ready and how long is left.
func broadcastReadyState(ms *MatchState, dispatcher runtime.MatchDispatcher, nowMs int64) {
	payload, err := json.Marshal(readyStateMessage(ms, nowMs))
	if err != nil {
		return
	}
	_ = dispatcher.BroadcastMessage(OpReadyState, payload, nil, nil, true)
}

// sendRemoved tells one player they are out of the match. Only that player
// receives it; the rest of the table sees the seat change in READY_STATE.
func sendRemoved(ms *MatchState, dispatcher runtime.MatchDispatcher, pres runtime.Presence, matchID, reason string) {
	payload, err := json.Marshal(msgRemovedFromMatch{MatchID: matchID, Reason: reason})
	if err != nil {
		return
	}
	_ = dispatcher.BroadcastMessage(OpRemovedFromMatch, payload, []runtime.Presence{pres}, nil, true)
}

// broadcastGameStarted announces the end of the ready check and the opening
// seat, ahead of the first STATE_FULL and TURN_CHANGE of the game.
func broadcastGameStarted(ms *MatchState, dispatcher runtime.MatchDispatcher, nowMs int64) {
	seats := make([]string, len(ms.Players))
	for i := range ms.Players {
		seats[i] = ms.Players[i].UserID
	}
	first := ms.firstSeat()
	firstPlayer := ""
	if first < len(ms.Players) {
		firstPlayer = ms.Players[first].UserID
	}
	payload, err := json.Marshal(msgGameStarted{
		FirstSeat:   first,
		FirstPlayer: firstPlayer,
		Seats:       seats,
		Rated:       ms.Rated,
		ServerNowMs: nowMs,
	})
	if err != nil {
		return
	}
	_ = dispatcher.BroadcastMessage(OpGameStarted, payload, nil, nil, true)
}
