package main

import (
	"os"
	"strconv"
	"strings"
)

// config.go — the tunable surface (BACKEND_DOC §18).
//
// These are vars rather than consts so tests can override them and so a deploy
// can change behaviour through the environment without a rebuild. Values that
// are game rules rather than operational knobs live in rules.go as consts.
var (
	// TurnSeconds is the per-turn budget shown to players.
	TurnSeconds = getEnvInt("TURN_SECONDS", 90)

	// TurnGraceSeconds is an extra window, invisible to the UI, before the
	// server calls a turn missed. It absorbs the round trip on a slow
	// connection so a player who acted just inside their own countdown is not
	// punished for latency. Keep it small: it is added to every missed turn.
	TurnGraceSeconds = getEnvInt("TURN_GRACE_SECONDS", 2)

	TurnTimerSelectable = getEnvBool("TURN_TIMER_SELECTABLE", false)
	// WinThreshold is the Power that starts the final round. Rated games
	// always use it; unrated ones (private, AI) may pick one of
	// WinThresholdOptions when they are created.
	WinThreshold = getEnvInt("WIN_THRESHOLD", 18)

	// MatchTickHz is how often the match loop runs. It bounds how long a
	// player waits for their action to be acknowledged, so 1 Hz felt sluggish
	// even though it is enough to drive a 90-second clock. 5 Hz gives a 200 ms
	// worst case at negligible cost for a turn-based game.
	MatchTickHz = getEnvInt("MATCH_TICK_HZ", 5)

	MatchmakerTimeoutSeconds = getEnvInt("MATCHMAKER_TIMEOUT_SECONDS", 60)

	// LobbyWaitSeconds bounds the waiting phase. A matched player who never
	// connects would otherwise hold every other seat in a match that can never
	// start, and their one-game-at-a-time lock with it.
	LobbyWaitSeconds = getEnvInt("LOBBY_WAIT_SECONDS", 90)

	// ReadyTimeoutSeconds is how long each human seat has to answer the ready
	// check (op READY) once every seat of an online match is filled. A seat
	// that has not answered by then is removed, unrated, and replaced.
	ReadyTimeoutSeconds = getEnvInt("READY_TIMEOUT_SECONDS", 120)

	// ReadyRefillSeconds is how long a public match keeps a removed player's
	// seat open for someone searching for the same mode before it seats a
	// Normal bot instead. Private matches never open a seat to strangers.
	ReadyRefillSeconds = getEnvInt("READY_REFILL_SECONDS", 20)

	ProvisionalGames = getEnvInt("PROVISIONAL_GAMES", 10)
	AbandonMissLimit = getEnvInt("ABANDON_MISS_LIMIT", 3)
	MaxReserve       = getEnvInt("MAX_RESERVE", 3)
	MaxCoins         = getEnvInt("COIN_HOLD_LIMIT", 10)

	// PersonaTimePercent scales how long personas take to arrive at a table
	// and to move (100 = as a person would). Lower only for testing.
	PersonaTimePercent = getEnvInt("PERSONA_TIME_PERCENT", 100)
)

func getEnvInt(key string, def int) int {
	if s := os.Getenv(key); s != "" {
		if v, err := strconv.Atoi(s); err == nil && v > 0 {
			return v
		}
	}
	return def
}

func getEnvBool(key string, def bool) bool {
	s := strings.TrimSpace(os.Getenv(key))
	if s == "" {
		return def
	}
	switch strings.ToLower(s) {
	case "1", "true", "yes", "on":
		return true
	case "0", "false", "no", "off":
		return false
	}
	return def
}
