package main

import (
	"context"
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

// match_ready.go — the ready check that sits between "every seat is filled"
// and the first turn of an online match (product decision, 15 Oct 2026).
//
//   - Each human seat must send READY (op 8) within READY_TIMEOUT_SECONDS. Bots
//     are ready the moment they sit down.
//   - Every change goes to the table as READY_STATE (op 107).
//   - When every seat is ready the game starts and the opening seat is drawn
//     from the match RNG (GAME_STARTED, op 109, carries it).
//   - A human who is not ready by their deadline, or who leaves or concedes
//     during the check, is removed: no rating change, no history, their
//     one-game lock released, and REMOVED_FROM_MATCH (op 108) sent to them.
//   - In a public match the seat is then held open for READY_REFILL_SECONDS for
//     someone searching the same mode (start_public_search hands them the match
//     ID; see findRefillMatch). An unclaimed seat, and every removed seat of a
//     private match, goes to a Normal bot.
//   - If no human is left the match is cancelled (lobbyTimeout: unrated, no
//     history).
//   - When the remote config turns on ads and the pregame_online slot, a table
//     that is all ready does not start at once: AD_BREAK (op 110) goes out
//     with a deadline (adBreakMaxSec), each app shows its ad and answers
//     AD_DONE (op 9), and the game starts when every human seat has answered
//     or at the deadline. Bots and personas never hold it up. A player who
//     leaves meanwhile is removed exactly as during the check; a table that
//     then has to wait for a replacement starts without a second break.
//
// Nakama's matchmaker cannot be pulled from server-side: the runtime has no
// MatchmakerAdd and only hears about full groups. The open seat is therefore
// advertised through the match label, and searchers look for it themselves.

// refillClaimTTLMs bounds how long a searcher admitted to an open seat by
// MatchJoinAttempt may take to complete the join before the seat is offered
// to someone else.
const refillClaimTTLMs = int64(15_000)

// NotifyRemovedFromMatch is the notification code that repeats
// REMOVED_FROM_MATCH for a player whose socket is not in the match.
const NotifyRemovedFromMatch = 1002

// enterReadyCheck starts the ready check with a fresh deadline for every human
// seat. Nothing is broadcast here, because MatchInit has no dispatcher; the
// caller announces it when it can.
func enterReadyCheck(ms *MatchState, nowMs int64) {
	ms.Phase = PhaseReadyCheck
	ms.LobbyDeadlineMs = 0
	deadline := nowMs + int64(ReadyTimeoutSeconds)*1000
	for i := range ms.Players {
		p := &ms.Players[i]
		if p.Persona {
			// a regular takes a moment to press Ready, like anyone
			p.Ready, p.ReadyDeadlineMs = false, 0
			p.ReadyAtMs = nowMs + personaReadyDelay(ms.random()).Milliseconds()
			continue
		}
		if p.IsAI {
			p.Ready, p.ReadyDeadlineMs = true, 0
			continue
		}
		p.Ready, p.ReadyDeadlineMs = false, deadline
	}
}

// handleReady records a READY. It is deliberately silent when it does not
// apply: a stale READY that lands just after the game started, a repeat, or
// one from a socket that holds no seat changes nothing and earns no rejection.
func handleReady(ms *MatchState, userID string, tc turnCtx) *MatchState {
	if ms.Phase != PhaseReadyCheck {
		return ms
	}
	seat := ms.SeatOf(userID)
	if seat < 0 {
		return ms
	}
	p := &ms.Players[seat]
	if p.IsAI || p.SeatOpen || p.Ready {
		return ms
	}
	p.Ready, p.ReadyDeadlineMs = true, 0
	tc.logger.Info("ready check: seat %d ready userId=%s", seat, userID)
	return settleReadyCheck(ms, tc, true)
}

// checkReadyCheck runs every tick of the ready check: it removes humans past
// their deadline, hands expired open seats to bots, and settles the result.
func checkReadyCheck(ms *MatchState, tc turnCtx) *MatchState {
	if ms.Phase != PhaseReadyCheck {
		return ms
	}
	changed := ms.expireRefillClaims(tc.now)

	// A searcher already admitted to an open seat keeps it while their join
	// is in flight, even if the refill window closes meanwhile.
	inFlight := ms.liveRefillClaims(tc.now)

	for i := range ms.Players {
		p := &ms.Players[i]
		switch {
		case p.SeatOpen:
			if tc.now < p.RefillDeadlineMs {
				continue
			}
			if inFlight > 0 {
				inFlight--
				continue
			}
			tc.logger.Info("ready check: nobody took open seat %d; seating a bot", i)
			seatBot(ms, i)
			changed = true
		case p.Persona && !p.Ready && p.ReadyAtMs > 0 && tc.now >= p.ReadyAtMs:
			p.Ready, p.ReadyAtMs = true, 0
			changed = true
		case !p.IsAI && !p.Ready && p.ReadyDeadlineMs > 0 && tc.now >= p.ReadyDeadlineMs:
			removeSeat(ms, i, RemovedReadyTimeout, tc)
			changed = true
		}
	}
	ms = settleReadyCheck(ms, tc, changed)
	return checkAdBreak(ms, tc)
}

// leaveReadyCheck treats a player who leaves or concedes during the ready check
// exactly like one who timed out: removed, unrated, seat replaced.
func leaveReadyCheck(ms *MatchState, userID string, tc turnCtx) *MatchState {
	seat := ms.SeatOf(userID)
	if ms.Phase != PhaseReadyCheck || seat < 0 || ms.Players[seat].IsAI {
		return ms
	}
	removeSeat(ms, seat, RemovedLeft, tc)
	return settleReadyCheck(ms, tc, true)
}

// settleReadyCheck decides what a change to the seats means: cancel the match
// if no human is left, start it if everyone is ready, otherwise tell the table.
func settleReadyCheck(ms *MatchState, tc turnCtx, changed bool) *MatchState {
	if ms.Phase != PhaseReadyCheck {
		return ms
	}
	if ms.humanSeatCount() == 0 {
		tc.logger.Info("ready check: no human left; cancelling the match")
		updateLabel(ms, tc.dispatcher, tc.now)
		return finalizeMatch(ms, tc, EndReasonLobbyTimeout)
	}
	if !changed {
		return ms
	}
	updateLabel(ms, tc.dispatcher, tc.now)
	broadcastReadyState(ms, tc.dispatcher, tc.now)
	if ms.allSeatsReady() {
		return afterAllReady(ms, tc)
	}
	broadcastState(ms, tc.dispatcher, tc.now)
	return ms
}

// afterAllReady starts the game, or the ad break first when the config asks
// for one. With the slot off this is exactly startGame.
func afterAllReady(ms *MatchState, tc turnCtx) *MatchState {
	if ms.AdBreakUntilMs == 0 {
		on, maxSec := onlineAdBreakConfig()
		if !on {
			return startGame(ms, tc)
		}
		ms.AdBreakUntilMs = tc.now + int64(maxSec)*1000
		for i := range ms.Players {
			ms.Players[i].AdDone = false
		}
		tc.logger.Info("ad break until %d", ms.AdBreakUntilMs)
		sendAdBreak(ms, tc.dispatcher, nil, tc.now)
	}
	if ms.adBreakOver(tc.now) {
		return startGame(ms, tc)
	}
	return ms
}

// adBreakOver reports whether the ad break may end: its deadline has passed,
// or every human seat has sent AD_DONE.
func (ms *MatchState) adBreakOver(nowMs int64) bool {
	if nowMs >= ms.AdBreakUntilMs {
		return true
	}
	for i := range ms.Players {
		p := &ms.Players[i]
		if !p.IsAI && !p.SeatOpen && !p.AdDone {
			return false
		}
	}
	return true
}

// handleAdDone records an AD_DONE. Like READY it is silent when it does not
// apply: outside the break, a repeat, or from a socket that holds no seat.
func handleAdDone(ms *MatchState, userID string, tc turnCtx) *MatchState {
	if ms.Phase != PhaseReadyCheck || ms.AdBreakUntilMs == 0 {
		return ms
	}
	seat := ms.SeatOf(userID)
	if seat < 0 || ms.Players[seat].IsAI || ms.Players[seat].AdDone {
		return ms
	}
	ms.Players[seat].AdDone = true
	tc.logger.Info("ad break: seat %d done userId=%s", seat, userID)
	return checkAdBreak(ms, tc)
}

// checkAdBreak starts a table whose ad break is over. Nothing happens while a
// seat is still open or not ready: the ready check owns the table until then.
func checkAdBreak(ms *MatchState, tc turnCtx) *MatchState {
	if ms.Phase != PhaseReadyCheck || ms.AdBreakUntilMs == 0 || !ms.allSeatsReady() {
		return ms
	}
	if ms.adBreakOver(tc.now) {
		return startGame(ms, tc)
	}
	return ms
}

// startGame opens play. The opening seat is drawn from the match RNG unless it
// was already chosen (an AI match fixes it at the human; a replay can pass
// it in), so the same seed and the same events always give the same opener.
func startGame(ms *MatchState, tc turnCtx) *MatchState {
	for i := range ms.Players {
		ms.Players[i].ReadyDeadlineMs = 0
		ms.Players[i].RefillDeadlineMs = 0
	}
	ms.refillClaims = nil

	// A bot has no rating, so a table left with one human is no longer a
	// rated game. With two or more humans it stays rated, among them only
	// (see applyRatingUpdates).
	if ms.Rated && ms.ratedSeatCount() < 2 {
		ms.Rated = false
		tc.logger.Info("ready check left fewer than two humans; match is now unrated")
	}

	if ms.FirstSeat < 0 || ms.FirstSeat >= len(ms.Players) {
		ms.FirstSeat = ms.random().Intn(len(ms.Players))
	}
	ms.Start(tc.now)
	tc.logger.Info("match started players=%d rated=%v firstSeat=%d", len(ms.Players), ms.Rated, ms.FirstSeat)

	updateLabel(ms, tc.dispatcher, tc.now)
	broadcastGameStarted(ms, tc.dispatcher, tc.now)
	onlineMatchStarted(ms, tc)
	beginTurn(ms, tc)
	return ms
}

// removeSeat takes a human out of the match during the ready check and fills
// the seat: held open for a searcher in a public match, a bot in a private one.
// The player never played, so nothing is rated or recorded; their lock is
// released so they can queue again straight away.
func removeSeat(ms *MatchState, seat int, reason string, tc turnCtx) {
	p := ms.Players[seat]
	userID := p.UserID
	tc.logger.Info("ready check: removing seat %d userId=%s reason=%s", seat, userID, reason)

	if ms.removed == nil {
		ms.removed = map[string]bool{}
	}
	ms.removed[userID] = true

	matchID, _ := tc.ctx.Value(runtime.RUNTIME_CTX_MATCH_ID).(string)
	if pres, ok := ms.presenceOf(userID); ok {
		sendRemoved(ms, tc.dispatcher, pres, matchID, reason)
		_ = tc.dispatcher.MatchKick([]runtime.Presence{pres})
	}
	ms.dropPresence(userID)

	if tc.nk != nil {
		clearActiveMatch(tc.ctx, tc.logger, tc.nk, userID)
		// The socket message above is lost if the player is not connected to
		// the match, so say it once more where the menu will hear it.
		if err := tc.nk.NotificationSend(tc.ctx, userID, "removed_from_match",
			map[string]interface{}{"matchId": matchID, "reason": reason}, NotifyRemovedFromMatch, "", false); err != nil {
			tc.logger.Warn("removeSeat: notification failed for %s: %v", userID, err)
		}
	}

	if ms.HostUserID != "" || ReadyRefillSeconds <= 0 {
		seatBot(ms, seat) // private: never a stranger from the queue
		return
	}
	open := newPlayerState("", "")
	open.SeatOpen = true
	open.RefillDeadlineMs = tc.now + int64(ReadyRefillSeconds)*1000
	ms.Players[seat] = open
}

// seatBot puts a Normal bot in a seat. It is ready at once.
func seatBot(ms *MatchState, seat int) {
	if ms.Public {
		if p := pickPersona(averageHumanRating(ms), "", ms.random(), ms.avatarsInUse()); p != nil {
			pl := newPersonaPlayer(context.Background(), nil, p)
			pl.Rating = p.BaseRating
			pl.ReadyAtMs = nowMs() + personaReadyDelay(ms.random()).Milliseconds()
			ms.Players[seat] = pl
			return
		}
	}
	bot := newAIPlayer(seat, AINormal, ms.random())
	bot.Ready = true
	ms.Players[seat] = bot
}

// claimRefillSeat admits a searcher to an open seat from MatchJoinAttempt,
// reporting why not when it cannot.
func claimRefillSeat(ms *MatchState, userID string, nowMs int64) (bool, string) {
	if ms.Phase != PhaseReadyCheck || ms.HostUserID != "" {
		return false, "match already started"
	}
	if ms.removed[userID] {
		return false, "removed from this match"
	}
	if isAIUser(userID) {
		return false, "not a player"
	}
	ms.expireRefillClaims(nowMs)
	if _, ok := ms.refillClaims[userID]; ok {
		return true, "" // a retry of the same join
	}
	if ms.openSeatCount()-ms.liveRefillClaims(nowMs) <= 0 {
		return false, "match is full"
	}
	if ms.refillClaims == nil {
		ms.refillClaims = map[string]int64{}
	}
	ms.refillClaims[userID] = nowMs
	return true, ""
}

// seatRefill sits a searcher who has joined in the first open seat, with a
// fresh ready window of their own. It reports false when no seat is left.
func seatRefill(ms *MatchState, pres runtime.Presence, nowMs int64) (int, bool) {
	userID := pres.GetUserId()
	delete(ms.refillClaims, userID)
	if ms.Phase != PhaseReadyCheck || ms.removed[userID] {
		return -1, false
	}
	for i := range ms.Players {
		if !ms.Players[i].SeatOpen {
			continue
		}
		p := newPlayerState(userID, pres.GetUsername())
		p.Disconnected = false
		p.ReadyDeadlineMs = nowMs + int64(ReadyTimeoutSeconds)*1000
		// arriving after the ad break began: nobody waits for their ad
		p.AdDone = ms.AdBreakUntilMs > 0
		ms.Players[i] = p
		return i, true
	}
	return -1, false
}

// ---------- seat queries ----------

// humanSeatCount counts seats held by a person, connected or not.
func (ms *MatchState) humanSeatCount() int {
	n := 0
	for i := range ms.Players {
		if !ms.Players[i].IsAI && !ms.Players[i].SeatOpen {
			n++
		}
	}
	return n
}

// ratedSeatCount counts the seats that are rated: humans and personas.
func (ms *MatchState) ratedSeatCount() int {
	n := 0
	for i := range ms.Players {
		if (!ms.Players[i].IsAI || ms.Players[i].Persona) && !ms.Players[i].SeatOpen {
			n++
		}
	}
	return n
}

func (ms *MatchState) openSeatCount() int {
	n := 0
	for i := range ms.Players {
		if ms.Players[i].SeatOpen {
			n++
		}
	}
	return n
}

// allSeatsReady reports whether the table is complete and every seat ready.
func (ms *MatchState) allSeatsReady() bool {
	if len(ms.Players) == 0 || len(ms.Players) < ms.ExpectedPlayerCount {
		return false
	}
	for i := range ms.Players {
		if ms.Players[i].SeatOpen || !ms.Players[i].Ready {
			return false
		}
	}
	return true
}

func (ms *MatchState) liveRefillClaims(nowMs int64) int {
	n := 0
	for _, at := range ms.refillClaims {
		if nowMs-at < refillClaimTTLMs {
			n++
		}
	}
	return n
}

// expireRefillClaims drops claims whose join never arrived, reporting whether
// any did, since that frees a seat to advertise again.
func (ms *MatchState) expireRefillClaims(nowMs int64) bool {
	dropped := false
	for uid, at := range ms.refillClaims {
		if nowMs-at >= refillClaimTTLMs {
			delete(ms.refillClaims, uid)
			dropped = true
		}
	}
	return dropped
}

// ---------- match label ----------

// matchLabel is what the matchmaker, the admin console and the refill search
// see. Open counts the seats a searcher may take right now.
type matchLabel struct {
	Rated       bool   `json:"rated"`
	PlayerCount int    `json:"playerCount"`
	Mode        string `json:"mode"` // public | private | ai
	Open        int    `json:"open"`
	Phase       string `json:"phase"` // waiting | readyCheck | playing | finalRound | ended
}

func (ms *MatchState) mode() string {
	switch {
	case ms.HostUserID != "":
		return "private"
	case !ms.ReadyCheck:
		return "ai"
	}
	return "public"
}

func (ms *MatchState) label(nowMs int64) string {
	open := 0
	if ms.Phase == PhaseWaiting && ms.Public {
		open = ms.ExpectedPlayerCount - len(ms.Players)
	}
	if ms.Phase == PhaseReadyCheck && ms.mode() == "public" {
		open = ms.openSeatCount() - ms.liveRefillClaims(nowMs)
		if open < 0 {
			open = 0
		}
	}
	b, _ := json.Marshal(matchLabel{
		Rated:       ms.Rated,
		PlayerCount: ms.ExpectedPlayerCount,
		Mode:        ms.mode(),
		Open:        open,
		Phase:       string(ms.Phase),
	})
	return string(b)
}

// updateLabel republishes the label when it has changed.
func updateLabel(ms *MatchState, dispatcher runtime.MatchDispatcher, nowMs int64) {
	if dispatcher == nil {
		return
	}
	l := ms.label(nowMs)
	if l == ms.lastLabel {
		return
	}
	ms.lastLabel = l
	_ = dispatcher.MatchLabelUpdate(l)
}
