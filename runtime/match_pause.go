package main

import (
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

// match_pause.go — the pause of a friends' game, the voluntary skip, and the
// table status every seat shows (who is offline, who asked for a pause).
//
// The pause is voted (the host's N-1 rule). Any player may ask for it; the
// game stops for everyone once N-1 of the N players still in the game have
// asked. While it is stopped the board is hidden on every device, the turn
// clock stands still, every move is refused, and a player who has not asked
// yet may still add their own pause ("pause me too"). The game goes on when
// N-1 players (any of them) have pressed Resume, at least two, so in a game
// of two nobody resumes alone. A pause that is not resumed within
// PauseCloseMinutes closes the room. Only private rooms (friends) can pause.

const (
	OpPause  int64 = 10 // {"on": bool} ask for the pause, or take the request back
	OpResume int64 = 11 // {"on": bool} ready to go on (while paused), or not
	OpSkip   int64 = 12 // {} pass this turn (it is not a missed turn)

	OpTableStatus int64 = 111 // every seat's flags and the pause, on every change
	OpTurnSkipped int64 = 112 // {playerIndex}: the player on turn passed it
)

// ErrGamePaused refuses a move made while the table is paused.
const ErrGamePaused = "game_paused"

// EndReasonPauseTimeout: the paused room was not resumed in time and closed.
const EndReasonPauseTimeout EndReason = "pauseTimeout"

// PauseCloseMinutes is how long a paused friends' game waits for its players.
var PauseCloseMinutes = getEnvInt("PAUSE_CLOSE_MINUTES", 30)

type msgPauseVote struct {
	On bool `json:"on"`
}

type seatStatus struct {
	Seat         int  `json:"seat"`
	Disconnected bool `json:"disconnected"`
	PauseVote    bool `json:"pauseVote"`
	ResumeVote   bool `json:"resumeVote"`
}

// msgTableStatus is TABLE_STATUS (op 111).
type msgTableStatus struct {
	Seats          []seatStatus `json:"seats"`
	CanPause       bool         `json:"canPause"`
	Paused         bool         `json:"paused"`
	PauseVotes     int          `json:"pauseVotes"`
	PauseNeeded    int          `json:"pauseNeeded"`
	ResumeVotes    int          `json:"resumeVotes"`
	ResumeNeeded   int          `json:"resumeNeeded"`
	CloseAtMs      int64        `json:"closeAtMs"` // a paused room closes then (0 when not paused)
	CurrentTurn    int          `json:"currentTurn"`
	TurnNumber     int          `json:"turnNumber"`
	TurnDeadlineMs int64        `json:"turnDeadlineMs"` // 0 while paused
	TurnLeftMs     int64        `json:"turnLeftMs"`     // the clock of the player on turn, frozen while paused
	ServerNowMs    int64        `json:"serverNowMs"`
}

type msgTurnSkipped struct {
	PlayerIndex int `json:"playerIndex"`
}

// canPause: a friends' room with a game under way.
func (ms *MatchState) canPause() bool {
	return !ms.Public && ms.HostUserID != "" &&
		(ms.Phase == PhasePlaying || ms.Phase == PhaseFinalRound)
}

// pauseNeeded is N-1 of the players still in the game (at least one).
func (ms *MatchState) pauseNeeded() int {
	return max(ms.ActivePlayerCount()-1, 1)
}

// resumeNeeded is N-1 as well, but at least two (when two are left, both).
func (ms *MatchState) resumeNeeded() int {
	n := ms.ActivePlayerCount()
	return min(max(n-1, 2), max(n, 1))
}

func (ms *MatchState) countVotes() (pause, resume int) {
	for i := range ms.Players {
		p := &ms.Players[i]
		if p.Conceded || p.IsAI {
			continue
		}
		if p.PauseVote {
			pause++
		}
		if p.ResumeVote {
			resume++
		}
	}
	return pause, resume
}

func (ms *MatchState) tableStatus(nowMs int64) msgTableStatus {
	pv, rv := ms.countVotes()
	st := msgTableStatus{
		Seats:          make([]seatStatus, len(ms.Players)),
		CanPause:       ms.canPause(),
		Paused:         ms.Paused,
		PauseVotes:     pv,
		PauseNeeded:    ms.pauseNeeded(),
		ResumeVotes:    rv,
		ResumeNeeded:   ms.resumeNeeded(),
		CurrentTurn:    ms.CurrentTurn,
		TurnNumber:     ms.TurnNumber,
		TurnDeadlineMs: ms.TurnDeadlineMs,
		ServerNowMs:    nowMs,
	}
	if ms.Paused {
		st.CloseAtMs = ms.PauseCloseAtMs
		st.TurnLeftMs = ms.PausedTurnLeftMs
	} else if ms.TurnDeadlineMs > 0 {
		st.TurnLeftMs = max(ms.TurnDeadlineMs-nowMs, 0)
	}
	for i := range ms.Players {
		p := &ms.Players[i]
		st.Seats[i] = seatStatus{Seat: i, Disconnected: p.Disconnected && !p.IsAI && !p.Conceded,
			PauseVote: p.PauseVote, ResumeVote: p.ResumeVote}
	}
	return st
}

// broadcastTableStatus tells every seat the table's flags.
func broadcastTableStatus(ms *MatchState, dispatcher runtime.MatchDispatcher, nowMs int64) {
	if dispatcher == nil {
		return
	}
	payload, err := json.Marshal(ms.tableStatus(nowMs))
	if err != nil {
		return
	}
	_ = dispatcher.BroadcastMessage(OpTableStatus, payload, nil, nil, true)
}

// sendTableStatusTo gives one (re)joining presence the table's flags.
func sendTableStatusTo(ms *MatchState, dispatcher runtime.MatchDispatcher, pres runtime.Presence, nowMs int64) {
	if dispatcher == nil {
		return
	}
	payload, err := json.Marshal(ms.tableStatus(nowMs))
	if err != nil {
		return
	}
	_ = dispatcher.BroadcastMessageDeferred(OpTableStatus, payload, []runtime.Presence{pres}, nil, true)
}

// handlePauseVote: OP_PAUSE. Before the pause it asks for it (or takes the
// request back); while paused it can only add the player's own pause.
func handlePauseVote(ms *MatchState, userID string, data []byte, tc turnCtx) *MatchState {
	seat := ms.SeatOf(userID)
	if seat < 0 || !ms.canPause() || ms.Players[seat].Conceded {
		rejectCode(ms, tc.dispatcher, userID, ErrGameNotRunning, "this game cannot be paused")
		return ms
	}
	var req msgPauseVote
	if err := json.Unmarshal(data, &req); err != nil {
		req.On = true
	}
	p := &ms.Players[seat]
	if ms.Paused && !req.On {
		return ms // the pause is on: a request can no longer be taken back
	}
	if p.PauseVote == req.On {
		return ms
	}
	p.PauseVote = req.On
	tc.logger.Info("pause vote userId=%s seat=%d on=%v", userID, seat, req.On)
	return settlePause(ms, tc)
}

// handleResumeVote: OP_RESUME, only while paused.
func handleResumeVote(ms *MatchState, userID string, data []byte, tc turnCtx) *MatchState {
	seat := ms.SeatOf(userID)
	if seat < 0 || !ms.Paused || ms.Players[seat].Conceded {
		return ms
	}
	var req msgPauseVote
	if err := json.Unmarshal(data, &req); err != nil {
		req.On = true
	}
	p := &ms.Players[seat]
	if p.ResumeVote == req.On {
		return ms
	}
	p.ResumeVote = req.On
	tc.logger.Info("resume vote userId=%s seat=%d on=%v", userID, seat, req.On)
	return settlePause(ms, tc)
}

// settlePause starts or ends the pause when the votes call for it, and tells
// the table. Also run when a player concedes, which lowers N.
func settlePause(ms *MatchState, tc turnCtx) *MatchState {
	if ms.Phase == PhaseEnded {
		return ms
	}
	pv, rv := ms.countVotes()
	switch {
	case !ms.Paused && ms.canPause() && pv >= ms.pauseNeeded():
		ms.Paused = true
		ms.PausedTurnLeftMs = max(ms.TurnDeadlineMs-tc.now, 0)
		ms.PauseCloseAtMs = tc.now + int64(PauseCloseMinutes)*60*1000
		ms.ClearTurnDeadline()
		for i := range ms.Players {
			ms.Players[i].ResumeVote = false
		}
		tc.logger.Info("game paused votes=%d/%d turnLeftMs=%d", pv, ms.pauseNeeded(), ms.PausedTurnLeftMs)
	case ms.Paused && rv >= ms.resumeNeeded():
		resumeGame(ms, tc)
		tc.logger.Info("game resumed votes=%d/%d", rv, ms.resumeNeeded())
		broadcastTableStatus(ms, tc.dispatcher, tc.now)
		broadcastTurnChange(ms, tc.dispatcher, tc.now)
		return ms
	}
	broadcastTableStatus(ms, tc.dispatcher, tc.now)
	return ms
}

// resumeGame restarts the clock where it stopped (at least 15 s, so the
// player on turn can find their bearings) and clears every vote.
func resumeGame(ms *MatchState, tc turnCtx) {
	ms.Paused = false
	ms.PauseCloseAtMs = 0
	ms.TurnDeadlineMs = tc.now + max(ms.PausedTurnLeftMs, 15000)
	ms.TurnDeadlineUnix = ms.TurnDeadlineMs / 1000
	ms.PausedTurnLeftMs = 0
	ms.AIThinkUntilMs = tc.now + 1500
	for i := range ms.Players {
		ms.Players[i].PauseVote = false
		ms.Players[i].ResumeVote = false
	}
}

// checkPauseTimeout closes a room that stayed paused too long.
func checkPauseTimeout(ms *MatchState, tc turnCtx) *MatchState {
	if !ms.Paused || ms.PauseCloseAtMs == 0 || tc.now < ms.PauseCloseAtMs {
		return ms
	}
	tc.logger.Info("paused room closed after %d minutes", PauseCloseMinutes)
	return finalizeMatch(ms, tc, EndReasonPauseTimeout)
}

// handleSkip: OP_SKIP. The player on turn passes it; it counts as a turn
// taken, not a missed one.
func handleSkip(ms *MatchState, userID string, tc turnCtx) *MatchState {
	seat := ms.SeatOf(userID)
	if seat < 0 || seat != ms.CurrentTurn {
		rejectCode(ms, tc.dispatcher, userID, ErrNotYourTurn, "it is not your turn")
		return ms
	}
	ms.nobleChoice = ""
	ms.Players[seat].TurnsTaken++
	tc.logger.Info("turn skipped userId=%s seat=%d", userID, seat)
	if tc.dispatcher != nil {
		if payload, err := json.Marshal(msgTurnSkipped{PlayerIndex: seat}); err == nil {
			_ = tc.dispatcher.BroadcastMessage(OpTurnSkipped, payload, nil, nil, true)
		}
	}
	if ms.AdvanceTurn() {
		return finalizeMatch(ms, tc, EndReasonThreshold)
	}
	beginTurn(ms, tc)
	return ms
}
