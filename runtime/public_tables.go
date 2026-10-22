package main

import (
	"context"
	"sort"

	"github.com/heroiclabs/nakama-common/runtime"
)

// public_tables.go — how an online table fills.
//
// A searcher is seated at an open public table of the size they asked for, or
// a new one is opened for them. The table then fills one seat at a time:
// other searchers take seats as they arrive, and when nobody comes, personas
// sit down at random moments. How long a table takes is itself random, from a
// few seconds to about five minutes, so the wait feels like a real room
// filling. When every seat is taken the usual ready check begins.

// fillPlanMs draws when the table should be complete, measured from the
// moment the first player sat down.
func fillPlanMs(ms *MatchState) int64 {
	rng := ms.random()
	between := func(lo, hi int) int64 {
		return int64(lo+rng.Intn(hi-lo+1)) * 1000 * int64(PersonaTimePercent) / 100
	}
	switch roll := rng.Intn(100); {
	case roll < 15:
		return between(6, 25)
	case roll < 50:
		return between(25, 90)
	case roll < 80:
		return between(90, 180)
	case roll < 95:
		return between(180, 270)
	default:
		return between(270, 330)
	}
}

// planArrivals spreads the remaining seats over the fill time: the last one
// lands at the end, the others at random moments before it.
func planArrivals(ms *MatchState, nowMs int64) {
	need := ms.ExpectedPlayerCount - len(ms.Players)
	if need <= 0 {
		ms.botArrivals = nil
		return
	}
	total := fillPlanMs(ms)
	rng := ms.random()
	times := make([]int64, 0, need)
	for i := 0; i < need-1; i++ {
		times = append(times, nowMs+int64(float64(total)*(0.15+0.8*rng.Float64())))
	}
	times = append(times, nowMs+total)
	sort.Slice(times, func(i, j int) bool { return times[i] < times[j] })
	ms.botArrivals = times
}

// humanArrived drops the latest planned persona: a real player took a seat.
func humanArrived(ms *MatchState) {
	if n := len(ms.botArrivals); n > 0 {
		ms.botArrivals = ms.botArrivals[:n-1]
	}
}

// averageHumanRating is what personas are matched against.
func averageHumanRating(ms *MatchState) int {
	sum, n := 0, 0
	for i := range ms.Players {
		if !ms.Players[i].IsAI && ms.Players[i].UserID != "" {
			r := ms.Players[i].Rating
			if r == 0 {
				r = DefaultRating
			}
			sum += r
			n++
		}
	}
	if n == 0 {
		return DefaultRating
	}
	return sum / n
}

// fillPublicTable seats the personas whose moment has come, and starts the
// ready check once the table is full.
func fillPublicTable(ms *MatchState, tc turnCtx) *MatchState {
	if !ms.Public || ms.Phase != PhaseWaiting || ms.humanSeatCount() == 0 {
		return ms
	}
	matchID, _ := tc.ctx.Value(runtime.RUNTIME_CTX_MATCH_ID).(string)
	seated := false
	for len(ms.botArrivals) > 0 && ms.botArrivals[0] <= tc.now && len(ms.Players) < ms.ExpectedPlayerCount {
		ms.botArrivals = ms.botArrivals[1:]
		p := pickPersona(averageHumanRating(ms), matchID, ms.random(), ms.avatarsInUse())
		var pl PlayerState
		if p != nil {
			pl = newPersonaPlayer(tc.ctx, tc.nk, p)
		} else {
			pl = newAIPlayer(len(ms.Players), AINormal, ms.random())
		}
		ms.Players = append(ms.Players, pl)
		tc.logger.Info("public table: %q sat down (%d/%d)", pl.DisplayName, len(ms.Players), ms.ExpectedPlayerCount)
		seated = true
	}
	if !seated {
		return ms
	}
	updateLabel(ms, tc.dispatcher, tc.now)
	if len(ms.Players) == ms.ExpectedPlayerCount {
		tableFilled(ms, tc)
		enterReadyCheck(ms, tc.now)
		return settleReadyCheck(ms, tc, true)
	}
	broadcastState(ms, tc.dispatcher, tc.now)
	return ms
}

// leaveWaiting takes a player out of a table that has not started. In a
// public table their seat goes back to the plan (someone else will come); a
// friends' room is closed when its host leaves it on purpose (`closing`).
// When no real player is left the table is closed.
func leaveWaiting(ms *MatchState, userID string, closing bool, tc turnCtx) *MatchState {
	seat := ms.SeatOf(userID)
	if ms.Phase != PhaseWaiting || seat < 0 {
		return ms
	}
	if ms.HostUserID != "" && ms.HostUserID == userID && closing {
		tc.logger.Info("room closed by its host")
		return finalizeMatch(ms, tc, EndReasonLobbyTimeout)
	}
	tableLeftBeforeFill(ms, tc)
	ms.Players = append(ms.Players[:seat], ms.Players[seat+1:]...)
	ms.dropPresence(userID)
	if tc.nk != nil {
		clearActiveMatch(tc.ctx, tc.logger, tc.nk, userID)
	}
	tc.logger.Info("left the waiting table userId=%s (%d/%d)", userID, len(ms.Players), ms.ExpectedPlayerCount)
	if ms.humanSeatCount() == 0 {
		return finalizeMatch(ms, tc, EndReasonLobbyTimeout)
	}
	if ms.Public {
		// someone else will take the seat, a little later
		at := tc.now + 8000 + int64(ms.random().Intn(40000))
		ms.botArrivals = append(ms.botArrivals, at)
		sort.Slice(ms.botArrivals, func(i, j int) bool { return ms.botArrivals[i] < ms.botArrivals[j] })
	}
	updateLabel(ms, tc.dispatcher, tc.now)
	broadcastState(ms, tc.dispatcher, tc.now)
	return ms
}

// openPublicTable creates a public table of `count` seats and returns its id.
func openPublicTable(ctx context.Context, nk runtime.NakamaModule, count int) (string, error) {
	return nk.MatchCreate(ctx, "splendor_match", map[string]interface{}{
		"rated":       true,
		"public":      true,
		"playerCount": count,
	})
}

// avatarsInUse is the set of faces already at the table.
func (ms *MatchState) avatarsInUse() map[string]bool {
	out := map[string]bool{}
	for i := range ms.Players {
		if a := ms.Players[i].AvatarID; a != "" {
			out[a] = true
		}
	}
	return out
}
