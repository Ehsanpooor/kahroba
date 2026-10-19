package main

import (
	"context"
	"time"

	"github.com/heroiclabs/nakama-common/runtime"
)

// match_turn.go — turn sequencing, the turn clock, abandonment and match end.
//
// Everything that can move the game forward funnels through beginTurn or
// finalizeMatch, so the deadline is armed in exactly one place and can never be
// left pointing at a player who is no longer on turn.

// nowMs is the single clock the match reads. Tests inject time by calling the
// *At variants directly rather than by patching this.
func nowMs() int64 { return time.Now().UnixNano() / int64(time.Millisecond) }

// turnCtx carries the per-tick plumbing so the flow functions stay readable.
type turnCtx struct {
	ctx        context.Context
	logger     runtime.Logger
	nk         runtime.NakamaModule
	dispatcher runtime.MatchDispatcher
	now        int64 // milliseconds
}

// beginTurn arms the clock for the seat now on turn and announces it.
func beginTurn(ms *MatchState, tc turnCtx) {
	ms.TurnNumber++
	ms.SetTurnDeadline(tc.now)
	scheduleAIThink(ms, tc.now)
	broadcastState(ms, tc.dispatcher, tc.now)
	broadcastTurnChange(ms, tc.dispatcher, tc.now)
}

// endOfTurn runs the automatic end-of-turn checks after a legal action
// (GDD v2 §5.4): claim any earned artifact, then close the turn.
//
// There is no coin-limit step here. The 10-coin limit is a hard block enforced
// before a coin is taken (house rule, see rules.go), so a legal action can
// never leave the player over it and nobody ever owes a return.
func endOfTurn(ms *MatchState, tc turnCtx) *MatchState {
	seat := ms.CurrentTurn
	p := &ms.Players[seat]

	choice := ms.nobleChoice
	ms.nobleChoice = ""
	if artifactID := CheckArtifactsPreferring(p.HiredCards, ms.Artifacts, choice); artifactID != "" {
		remaining := make([]Artifact, 0, len(ms.Artifacts))
		for _, a := range ms.Artifacts {
			if a.ID != artifactID {
				remaining = append(remaining, a)
			}
		}
		ms.Artifacts = remaining
		p.Artifacts = append(p.Artifacts, artifactID)
		broadcastArtifactClaimed(ms, tc.dispatcher, seat, artifactID)
	}

	return completeTurn(ms, tc)
}

// completeTurn closes the active player's turn: check the Power threshold, then
// hand play on.
func completeTurn(ms *MatchState, tc turnCtx) *MatchState {
	ms.Players[ms.CurrentTurn].TurnsTaken++

	// Reaching the threshold starts the final round; it does not end the game.
	if ms.Phase == PhasePlaying && ms.CheckWinTrigger(ms.CurrentTurn) {
		ms.Phase = PhaseFinalRound
	}

	if ms.AdvanceTurn() {
		return finalizeMatch(ms, tc, EndReasonThreshold)
	}
	beginTurn(ms, tc)
	return ms
}

// passTurn moves play on for a seat that has no legal action at all (see
// MatchState.HasLegalAction). It counts as a turn taken, never as a missed one:
// being boxed in by the coin limit is not abandonment. Power cannot change on a
// pass, so there is no threshold check.
//
// If nobody still in the game can act either, the position is frozen for good
// (in a 2-player game two boxed-in players can hold the entire colour supply
// between them), so the match ends and is scored on the board as it stands.
func passTurn(ms *MatchState, tc turnCtx) *MatchState {
	p := &ms.Players[ms.CurrentTurn]
	p.TurnsTaken++
	tc.logger.Info("turn passed: no legal action userId=%s", p.UserID)

	if ms.NobodyCanAct() {
		return finalizeMatch(ms, tc, EndReasonStalemate)
	}

	if ms.AdvanceTurn() {
		return finalizeMatch(ms, tc, EndReasonThreshold)
	}
	beginTurn(ms, tc)
	return ms
}

// checkTurnTimer fires when the active player has run past their deadline plus
// the latency grace window.
func checkTurnTimer(ms *MatchState, tc turnCtx) *MatchState {
	if ms.Phase == PhaseEnded || !ms.TurnExpired(tc.now) {
		return ms
	}
	return autoSkipTurn(ms, tc)
}

// autoSkipTurn charges the active player a missed turn and passes play on.
//
// The counter is cumulative and never resets, and the miss after the limit is an
// automatic loss (BACKEND_DOC §8). A player who had no legal action at all
// (boxed in by the coin limit, a full reserve and nothing affordable) could not
// have moved, so their expiry is a plain pass with no missed turn charged.
func autoSkipTurn(ms *MatchState, tc turnCtx) *MatchState {
	seat := ms.CurrentTurn
	p := &ms.Players[seat]

	if !ms.HasLegalAction(seat) {
		return passTurn(ms, tc)
	}

	p.MissedTurns++
	p.TurnsTaken++
	autoLost := p.MissedTurns > AbandonMissLimit
	tc.logger.Info("turn auto-skipped userId=%s missedTurns=%d autoLost=%v", p.UserID, p.MissedTurns, autoLost)
	broadcastAbandoned(ms, tc.dispatcher, seat, autoLost)

	if autoLost {
		p.Conceded = true
		if ms.ActivePlayerCount() == 0 {
			return finalizeMatch(ms, tc, EndReasonAllLeft)
		}
		if ms.ActivePlayerCount() == 1 {
			return finalizeMatch(ms, tc, EndReasonLastStanding)
		}
	}

	if ms.AdvanceTurn() {
		return finalizeMatch(ms, tc, EndReasonThreshold)
	}
	beginTurn(ms, tc)
	return ms
}

// handleConcede applies a concession, from either the RPC signal or op 6.
// A concession is a rated loss and can never win the match, whatever the
// player's Power (see ComputeStandings).
func handleConcede(ms *MatchState, userID string, tc turnCtx) *MatchState {
	// Nothing has been played during the ready check, so there is nothing to
	// lose: conceding there is leaving, and costs the seat but no rating.
	if ms.Phase == PhaseReadyCheck {
		return leaveReadyCheck(ms, userID, tc)
	}
	seat := ms.SeatOf(userID)
	if seat < 0 || ms.Phase == PhaseEnded || ms.Players[seat].Conceded {
		return ms
	}
	ms.Players[seat].Conceded = true
	tc.logger.Info("player conceded userId=%s seat=%d", userID, seat)

	switch ms.ActivePlayerCount() {
	case 0:
		return finalizeMatch(ms, tc, EndReasonAllLeft)
	case 1:
		return finalizeMatch(ms, tc, EndReasonLastStanding)
	}

	// Conceding on your own turn passes play immediately, with a full fresh
	// clock for the next player rather than the remainder of the quitter's.
	if ms.CurrentTurn == seat {
		if ms.AdvanceTurn() {
			return finalizeMatch(ms, tc, EndReasonThreshold)
		}
		beginTurn(ms, tc)
		return ms
	}

	broadcastState(ms, tc.dispatcher, tc.now)
	return ms
}

// checkLobbyTimeout cancels a match whose players never all connected, so the
// rest of the table is not held hostage by an absent seat. Nothing is rated and
// no history is written: this game never happened.
func checkLobbyTimeout(ms *MatchState, tc turnCtx) *MatchState {
	if ms.Phase != PhaseWaiting || ms.LobbyDeadlineMs == 0 || tc.now < ms.LobbyDeadlineMs {
		return ms
	}
	tc.logger.Info("lobby timed out with %d/%d players connected", connectedCount(ms), ms.ExpectedPlayerCount)
	return finalizeMatch(ms, tc, EndReasonLobbyTimeout)
}

// connectedCount reports how many seats are ready to play. A bot is always
// ready, so an AI match starts the moment its human sits down.
func connectedCount(ms *MatchState) int {
	n := 0
	for i := range ms.Players {
		if ms.Players[i].IsAI || !ms.Players[i].Disconnected {
			n++
		}
	}
	return n
}

// finalizeMatch ends the match exactly once: rank the table, apply rating,
// persist history, release every player's one-game-at-a-time lock, and tell
// the clients.
func finalizeMatch(ms *MatchState, tc turnCtx, reason EndReason) *MatchState {
	if ms.Phase == PhaseEnded {
		return ms
	}
	ms.Phase = PhaseEnded
	ms.EndReason = reason
	ms.ClearTurnDeadline()

	cancelled := reason == EndReasonLobbyTimeout

	standings, winnerIdx := ComputeStandings(ms.Players)
	ms.WinnerIndex = winnerIdx
	if cancelled {
		ms.WinnerIndex = -1
	}

	winnerUID := ""
	if ms.WinnerIndex >= 0 && ms.WinnerIndex < len(ms.Players) {
		winnerUID = ms.Players[ms.WinnerIndex].UserID
	}

	ratingDeltas := map[string]int{}
	if !cancelled && ms.Rated && tc.nk != nil {
		ratingDeltas = applyRatingUpdates(tc.ctx, tc.logger, tc.nk, ms, standings)
	}

	matchID, _ := tc.ctx.Value(runtime.RUNTIME_CTX_MATCH_ID).(string)
	if !cancelled && tc.nk != nil && matchID != "" {
		writeMatchHistory(tc.ctx, tc.logger, tc.nk, ms, matchID, standings, ratingDeltas)
	}

	// Released last so a storage failure above cannot leave players locked out
	// of starting a new game.
	if tc.nk != nil {
		for i := range ms.Players {
			if ms.Players[i].IsAI {
				continue // a bot holds no account lock to release
			}
			clearActiveMatch(tc.ctx, tc.logger, tc.nk, ms.Players[i].UserID)
		}
	}

	tc.logger.Info("match ended reason=%s winner=%q rated=%v", reason, winnerUID, ms.Rated)

	broadcastState(ms, tc.dispatcher, tc.now)
	broadcastGameEnded(tc.dispatcher, msgGameEnded{
		WinnerIndex:  ms.WinnerIndex,
		WinnerUserID: winnerUID,
		Reason:       reason,
		Standings:    standings,
		RatingDeltas: ratingDeltas,
	})
	return ms
}
