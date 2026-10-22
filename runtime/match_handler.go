package main

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

// match_handler.go — the Nakama authoritative match lifecycle.
//
// Game rules live in rules.go, turn sequencing in match_turn.go, the four
// actions in match_actions.go, the pre-game ready check in match_ready.go, and
// every outbound message in match_broadcast.go. This file only wires Nakama's
// callbacks to those.

type SplendorMatch struct{}

func (m *SplendorMatch) MatchInit(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, params map[string]interface{}) (interface{}, int, string) {
	rated := paramBool(params, "rated", true)
	userIDs := paramStrings(params, "userIds")
	names := paramStrings(params, "names")

	// Both creation paths must agree on the table size: the matchmaker seeds
	// userIds, while a private lobby only knows the count up front.
	playerCount := paramInt(params, "playerCount", len(userIDs))
	if playerCount < 2 || playerCount > MaxRoomPlayers {
		logger.Warn("MatchInit: playerCount %d out of range, defaulting to 2", playerCount)
		playerCount = 2
	}

	// One seed drives every random draw in the match, so a replay that passes
	// the same seed back in reproduces the deal and the opening seat.
	seed := int64(paramInt(params, "seed", 0))
	if seed == 0 {
		seed = newSeed()
	}
	state := NewMatchStateSeeded(userIDs, names, rated, playerCount, seed)
	state.HostUserID = paramString(params, "hostUserId", "")
	state.ReadyCheck = true
	state.Public = paramBool(params, "public", false)

	// Fill the remaining seats with bots. An AI match is an ordinary
	// authoritative match: the bot occupies a real seat and plays through the
	// same validated messages a client sends, so there is no second rules path
	// and no way for a tampered client to fake an AI result.
	if aiCount := paramInt(params, "aiCount", 0); aiCount > 0 {
		difficulty := normalizeDifficulty(paramString(params, "aiDifficulty", string(AINormal)))
		for seat := len(state.Players); seat < playerCount; seat++ {
			state.Players = append(state.Players, newAIPlayer(seat, difficulty, state.random()))
		}
		rated = false // never rated, whatever the caller asked for
		state.Rated = false
		// One player against bots has nobody to wait for, and the human
		// (seat 0) always opens.
		state.ReadyCheck = false
		state.FirstSeat = 0
		logger.Info("match seeded with %d %s bots", aiCount, difficulty)
	}

	// An unrated game may play to another target; rated games never do, so
	// every rated result is measured against the same goal.
	if wt := paramInt(params, "winThreshold", 0); wt > 0 && !state.Rated && validWinThreshold(wt) {
		state.WinThresholdVal = wt
	}

	// A caller that already decided who opens (a replay, say) keeps that choice.
	if fs := paramInt(params, "firstSeat", -1); fs >= 0 && fs < playerCount {
		state.FirstSeat = fs
	}

	now := nowMs()
	state.LobbyDeadlineMs = now + int64(LobbyWaitSeconds)*1000
	if state.Public {
		state.LobbyDeadlineMs = now + 12*60*1000 // a public table always fills well before this
	}

	// A matchmaker match arrives with every seat filled, so its ready check
	// starts at once; the window covers connecting as well as answering.
	if state.ReadyCheck && len(state.Players) == playerCount {
		enterReadyCheck(state, now)
	}

	logger.Info("match created rated=%v playerCount=%d seeded=%d host=%q phase=%s seed=%d",
		rated, playerCount, len(userIDs), state.HostUserID, state.Phase, seed)

	state.lastLabel = state.label(now)
	return state, MatchTickHz, state.lastLabel
}

func (m *SplendorMatch) MatchJoinAttempt(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, dispatcher runtime.MatchDispatcher, tick int64, state interface{}, presence runtime.Presence, metadata map[string]string) (interface{}, bool, string) {
	ms := state.(*MatchState)
	userID := presence.GetUserId()

	if ms.Phase == PhaseEnded {
		return ms, false, "match has ended"
	}

	// A seated player may always come back, mid-game included (§9).
	if ms.SeatOf(userID) >= 0 {
		return ms, true, ""
	}

	// During a public ready check a searcher may take a seat the check has
	// opened (match_ready.go). The one-game-at-a-time lock is checked again
	// here: the search RPC that pointed them at this match ran a moment ago.
	if ms.Phase == PhaseReadyCheck {
		if ms.openSeatCount() == 0 {
			return ms, false, "match already started"
		}
		if nk != nil {
			matchID, _ := ctx.Value(runtime.RUNTIME_CTX_MATCH_ID).(string)
			meta, err := readMetadata(ctx, nk, userID)
			if err != nil {
				return ms, false, "failed to read account"
			}
			if meta.ActiveMatchID != nil && *meta.ActiveMatchID != matchID {
				return ms, false, "already in a match"
			}
		}
		now := nowMs()
		ok, reason := claimRefillSeat(ms, userID, now)
		if ok {
			logger.Info("ready check: refill seat claimed by userId=%s", userID)
			updateLabel(ms, dispatcher, now)
		}
		return ms, ok, reason
	}

	if ms.Phase != PhaseWaiting {
		return ms, false, "match already started"
	}
	if len(ms.Players) >= ms.ExpectedPlayerCount {
		return ms, false, "match is full"
	}

	// Private lobbies admit the host and invited friends only (§6).
	if ms.HostUserID != "" {
		matchID, _ := ctx.Value(runtime.RUNTIME_CTX_MATCH_ID).(string)
		objects, err := nk.StorageRead(ctx, []*runtime.StorageRead{
			{Collection: "private_invites", Key: matchID, UserID: ""},
		})
		if err != nil || len(objects) == 0 {
			return ms, false, "invite record not found"
		}
		var doc privateInviteDoc
		if err := json.Unmarshal([]byte(objects[0].GetValue()), &doc); err != nil {
			return ms, false, "invalid invite record"
		}
		if !isAllowedJoiner(doc, userID) {
			return ms, false, "not invited"
		}
	}

	return ms, true, ""
}

func isAllowedJoiner(doc privateInviteDoc, userID string) bool {
	if doc.HostID == userID || doc.Open {
		return true
	}
	return containsString(doc.InvitedIDs, userID)
}

func (m *SplendorMatch) MatchJoin(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, dispatcher runtime.MatchDispatcher, tick int64, state interface{}, presences []runtime.Presence) interface{} {
	ms := state.(*MatchState)
	tc := turnCtx{ctx: ctx, logger: logger, nk: nk, dispatcher: dispatcher, now: nowMs()}
	return handleJoin(ms, tc, presences)
}

// handleJoin seats or reconnects each joining presence, then moves the match
// on if the table is now complete. Split from MatchJoin so tests can drive it
// with a fake clock.
func handleJoin(ms *MatchState, tc turnCtx, presences []runtime.Presence) *MatchState {
	matchID, _ := tc.ctx.Value(runtime.RUNTIME_CTX_MATCH_ID).(string)
	joined := make([]runtime.Presence, 0, len(presences))
	readyCheckChanged := false

	for _, pres := range presences {
		userID := pres.GetUserId()

		switch seat := ms.SeatOf(userID); {
		case seat >= 0:
			ms.trackPresence(pres)
			ms.Players[seat].Disconnected = false
			tc.logger.Info("player reconnected userId=%s seat=%d missedTurns=%d", userID, seat, ms.Players[seat].MissedTurns)
			if ms.Phase == PhaseReadyCheck {
				readyCheckChanged = true
			}

		case ms.Phase == PhaseWaiting:
			ms.trackPresence(pres)
			p := newPlayerState(userID, pres.GetUsername())
			p.Disconnected = false
			ms.Players = append(ms.Players, p)
			if ms.Public && ms.FirstSeatedMs == 0 {
				ms.FirstSeatedMs = tc.now
			}
			if ms.Public {
				if ms.humanSeatCount() == 1 && ms.botArrivals == nil {
					planArrivals(ms, tc.now)
				} else {
					humanArrived(ms)
				}
			}
			if matchID != "" && tc.nk != nil {
				setActiveMatch(tc.ctx, tc.logger, tc.nk, userID, matchID)
			}

		case ms.Phase == PhaseReadyCheck:
			seat, ok := seatRefill(ms, pres, tc.now)
			if !ok {
				// The open seat went to a bot (or to another searcher) while
				// this join was in flight. Send them back to searching.
				tc.logger.Info("ready check: refill join by userId=%s found no open seat", userID)
				sendRemoved(ms, tc.dispatcher, pres, matchID, RemovedSeatUnavailable)
				_ = tc.dispatcher.MatchKick([]runtime.Presence{pres})
				continue
			}
			ms.trackPresence(pres)
			tc.logger.Info("ready check: userId=%s took open seat %d", userID, seat)
			if matchID != "" && tc.nk != nil {
				setActiveMatch(tc.ctx, tc.logger, tc.nk, userID, matchID)
			}
			readyCheckChanged = true

		default:
			ms.trackPresence(pres)
		}
		applyProfile(ms, tc, userID)
		joined = append(joined, pres)
	}

	if ms.Phase == PhaseWaiting &&
		ms.ExpectedPlayerCount > 0 &&
		len(ms.Players) == ms.ExpectedPlayerCount {
		switch {
		case ms.ReadyCheck:
			// Every seat is filled: the ready check begins.
			tableFilled(ms, tc)
			enterReadyCheck(ms, tc.now)
			tc.logger.Info("ready check started players=%d", len(ms.Players))
			readyCheckChanged = true
		case connectedCount(ms) == ms.ExpectedPlayerCount:
			ms = startGame(ms, tc)
		}
	}

	if readyCheckChanged && ms.Phase == PhaseReadyCheck {
		ms = settleReadyCheck(ms, tc, true)
	}

	// Each joiner gets its own view last, so it reflects every transition
	// above rather than the state as it stood before them. While a room is
	// still filling, everyone already seated sees the newcomer too.
	if ms.Phase == PhaseWaiting && len(joined) > 0 && tc.dispatcher != nil {
		broadcastState(ms, tc.dispatcher, tc.now)
	} else {
		for _, pres := range joined {
			sendStateTo(ms, tc.dispatcher, pres, tc.now)
		}
	}
	// A player who comes back during the ad break and has not answered it
	// hears about it again, or the table would wait for them until the end.
	if ms.Phase == PhaseReadyCheck && ms.AdBreakUntilMs > tc.now {
		for _, pres := range joined {
			if seat := ms.SeatOf(pres.GetUserId()); seat >= 0 && !ms.Players[seat].AdDone {
				sendAdBreak(ms, tc.dispatcher, pres, tc.now)
			}
		}
	}
	return ms
}

func (m *SplendorMatch) MatchLeave(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, dispatcher runtime.MatchDispatcher, tick int64, state interface{}, presences []runtime.Presence) interface{} {
	ms := state.(*MatchState)
	tc := turnCtx{ctx: ctx, logger: logger, nk: nk, dispatcher: dispatcher, now: nowMs()}
	return handleLeave(ms, tc, presences)
}

// handleLeave records departures. During the ready check a departure costs the
// seat, exactly like a ready timeout. Once the game is running the seat is held
// for the whole abandonment window (§9): leaving is not conceding, and the turn
// timer keeps running either way.
func handleLeave(ms *MatchState, tc turnCtx, presences []runtime.Presence) *MatchState {
	for _, pres := range presences {
		userID := pres.GetUserId()
		// A leave from an older socket of a player who has already rejoined
		// on a new one is stale: the player is still here.
		if cur, ok := ms.presenceOf(userID); ok && cur.GetSessionId() != pres.GetSessionId() {
			continue
		}
		seat := ms.SeatOf(userID)
		if ms.Phase == PhaseReadyCheck && seat >= 0 {
			ms = leaveReadyCheck(ms, userID, tc)
			continue
		}
		// Leaving a public table that is still filling gives the seat back.
		if ms.Phase == PhaseWaiting && ms.Public && seat >= 0 {
			ms = leaveWaiting(ms, userID, false, tc)
			continue
		}
		ms.dropPresence(userID)
		if seat >= 0 {
			ms.Players[seat].Disconnected = true
			tc.logger.Info("player disconnected userId=%s seat=%d", userID, seat)
		}
	}
	return ms
}

func (m *SplendorMatch) MatchLoop(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, dispatcher runtime.MatchDispatcher, tick int64, state interface{}, messages []runtime.MatchData) interface{} {
	ms := state.(*MatchState)
	tc := turnCtx{ctx: ctx, logger: logger, nk: nk, dispatcher: dispatcher, now: nowMs()}
	return runLoop(ms, tc, messages)
}

// runLoop is one tick of the match. Split from MatchLoop so tests can drive it
// with a fake clock.
func runLoop(ms *MatchState, tc turnCtx, messages []runtime.MatchData) *MatchState {
	if ms.Phase == PhaseEnded {
		return ms
	}
	if ms.Phase == PhaseWaiting {
		// A table waiting for its players still answers SYNC_REQUEST (so
		// everyone seated can see who has arrived) and CONCEDE (leaving it).
		for _, msg := range messages {
			switch msg.GetOpCode() {
			case OpSyncRequest:
				sendState(ms, tc.dispatcher, msg.GetUserId(), tc.now)
			case OpConcede:
				ms = leaveWaiting(ms, msg.GetUserId(), true, tc)
				if ms.Phase == PhaseEnded {
					return ms
				}
			}
		}
		ms = fillPublicTable(ms, tc)
		if ms.Phase != PhaseWaiting {
			return ms
		}
		return checkLobbyTimeout(ms, tc)
	}
	if ms.Phase == PhaseReadyCheck {
		// READY, SYNC_REQUEST and CONCEDE are honoured; game actions are
		// rejected with game_not_running. A READY that completes the table
		// starts the game, and the rest of the batch is then played normally.
		for _, msg := range messages {
			ms = processMessage(ms, msg, tc)
			if ms.Phase == PhaseEnded {
				return ms
			}
		}
		return checkReadyCheck(ms, tc)
	}

	// Defensive: a playing match always has an armed clock.
	if ms.TurnDeadlineMs == 0 {
		beginTurn(ms, tc)
	}

	// Actions are processed before the clock is examined, so a message that
	// arrived inside the window is honoured even if this tick runs late.
	for _, msg := range messages {
		ms = processMessage(ms, msg, tc)
		if ms.Phase == PhaseEnded {
			return ms
		}
	}

	// A bot on turn acts once its thinking pause has elapsed.
	ms = driveAISeat(ms, tc)
	if ms.Phase == PhaseEnded {
		return ms
	}

	return checkTurnTimer(ms, tc)
}

func (m *SplendorMatch) MatchSignal(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, dispatcher runtime.MatchDispatcher, tick int64, state interface{}, data string) (interface{}, string) {
	ms, ok := state.(*MatchState)
	if !ok || ms == nil {
		return state, ""
	}
	var sig struct {
		Action string `json:"action"`
		UserID string `json:"userId"`
	}
	if err := json.Unmarshal([]byte(data), &sig); err != nil {
		return ms, ""
	}
	if sig.Action == "concede" && sig.UserID != "" {
		ms = handleConcede(ms, sig.UserID, turnCtx{ctx: ctx, logger: logger, nk: nk, dispatcher: dispatcher, now: nowMs()})
	}
	return ms, ""
}

func (m *SplendorMatch) MatchTerminate(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, dispatcher runtime.MatchDispatcher, tick int64, state interface{}, graceSeconds int) interface{} {
	ms, ok := state.(*MatchState)
	if !ok || ms == nil {
		return state
	}
	// The server is going down mid-game. Nothing can be salvaged, but players
	// must not stay locked out of starting a new match.
	if ms.Phase != PhaseEnded && nk != nil {
		logger.Warn("match terminated in phase=%s; releasing %d players", ms.Phase, len(ms.Players))
		for i := range ms.Players {
			if ms.Players[i].IsAI {
				continue // a bot holds no account lock
			}
			clearActiveMatch(ctx, logger, nk, ms.Players[i].UserID)
		}
	}
	return ms
}
