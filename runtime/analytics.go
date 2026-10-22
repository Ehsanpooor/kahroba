package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/heroiclabs/nakama-common/runtime"
)

// analytics.go — our own usage events (docs/REMOTE_CONFIG_ADS_ANALYTICS.md §3).
//
// The app batches what happens on the phone (screens, games, searches, errors)
// and sends it with the `track` RPC; the match handler records what only the
// server sees (an online game starting and ending, a public table filling).
// Everything lands in one Postgres table next to Nakama's own, so nothing
// leaves our server and the admin page can ask it questions in plain SQL
// (admin_stats.go).
//
//	track  {device, events: [{n, t, p}]}  → {accepted}

const (
	trackMaxEvents    = 50
	trackMaxPropBytes = 2048
	trackMaxPerDay    = 2000
	trackMaxAge       = 7 * 24 * time.Hour
	// a phone's clock running a little fast is still "now"
	trackMaxAhead = 5 * time.Minute
)

var eventNameRe = regexp.MustCompile(`^[a-z][a-z0-9_]{1,39}$`)

// The handle and logger the module was started with. The match handler has no
// database handle of its own in the flow functions (turnCtx), so server-side
// events go through these. Both stay nil in tests, which simply records nothing.
var (
	analyticsDB     *sql.DB
	analyticsLogger runtime.Logger
)

// initAnalytics creates the events table and its indexes when missing, and
// keeps the handle for the match handler. A failure here is logged and the
// game runs without analytics rather than not at all.
//
// Two small tables sit beside it so the admin page never has to scan every
// event ever recorded: analytics_players holds each player's first event, and
// analytics_days one row per player per day they used the app (Tehran days),
// which is all that daily players and retention need.
func initAnalytics(ctx context.Context, logger runtime.Logger, db *sql.DB) {
	analyticsLogger = logger
	if db == nil {
		return
	}
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS analytics_events (
			at          timestamptz NOT NULL DEFAULT now(),
			user_id     uuid,
			name        text NOT NULL,
			props       jsonb NOT NULL DEFAULT '{}'::jsonb,
			app_version text NOT NULL DEFAULT '',
			platform    text NOT NULL DEFAULT '',
			device      text NOT NULL DEFAULT '',
			os          text NOT NULL DEFAULT '',
			locale      text NOT NULL DEFAULT '',
			session_id  text NOT NULL DEFAULT ''
		)`,
		`CREATE INDEX IF NOT EXISTS analytics_events_name_at ON analytics_events (name, at)`,
		`CREATE INDEX IF NOT EXISTS analytics_events_user_at ON analytics_events (user_id, at)`,
		`CREATE INDEX IF NOT EXISTS analytics_events_at ON analytics_events (at)`,
		`CREATE TABLE IF NOT EXISTS analytics_players (
			user_id  uuid PRIMARY KEY,
			first_at timestamptz NOT NULL
		)`,
		`CREATE INDEX IF NOT EXISTS analytics_players_first_at ON analytics_players (first_at)`,
		`CREATE TABLE IF NOT EXISTS analytics_days (
			day     date NOT NULL,
			user_id uuid NOT NULL,
			PRIMARY KEY (day, user_id)
		)`,
		`CREATE INDEX IF NOT EXISTS analytics_days_user ON analytics_days (user_id, day)`,
	}
	for _, s := range stmts {
		if _, err := db.ExecContext(ctx, s); err != nil {
			logger.Error("analytics: could not prepare the tables: %v", err)
			return
		}
	}
	analyticsDB = db
}

// ---------- the daily allowance per player

// trackQuota counts the events each player sent today (UTC). It lives in
// memory: a restart forgets it, which at worst lets one player send a second
// day's worth once. That is cheaper than a query on every call.
type trackQuota struct {
	mu    sync.Mutex
	day   string
	count map[string]int
}

var dailyQuota = &trackQuota{count: map[string]int{}}

// take reserves up to n events for userID today and reports how many it got.
func (q *trackQuota) take(userID string, n int, now time.Time) int {
	q.mu.Lock()
	defer q.mu.Unlock()
	if day := now.UTC().Format("2006-01-02"); day != q.day {
		q.day, q.count = day, map[string]int{}
	}
	left := trackMaxPerDay - q.count[userID]
	if left <= 0 {
		return 0
	}
	if n > left {
		n = left
	}
	q.count[userID] += n
	return n
}

// giveBack returns events reserved but not stored (the insert failed).
func (q *trackQuota) giveBack(userID string, n int, now time.Time) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if now.UTC().Format("2006-01-02") == q.day && q.count[userID] >= n {
		q.count[userID] -= n
	}
}

// ---------- track

type trackDevice struct {
	AppVersion string `json:"appVersion"`
	Platform   string `json:"platform"`
	OS         string `json:"os"`
	Model      string `json:"model"`
	Locale     string `json:"locale"`
	SessionID  string `json:"sessionId"`
}

type trackEvent struct {
	N string          `json:"n"`
	T int64           `json:"t"`
	P json.RawMessage `json:"p"`
}

type trackRequest struct {
	Device trackDevice  `json:"device"`
	Events []trackEvent `json:"events"`
}

// eventRow is one event ready for the table.
type eventRow struct {
	at    time.Time
	name  string
	props string
}

// cleanText makes a device string safe to store: valid UTF-8, no NUL (which
// Postgres refuses), trimmed, and short.
func cleanText(s string, max int) string {
	s = strings.ToValidUTF8(s, "")
	s = strings.ReplaceAll(s, "\x00", "")
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) > max {
		s = string([]rune(s)[:max])
	}
	return s
}

// cleanProps checks that p is a JSON object of at most 2048 bytes and returns
// it re-encoded, which also replaces any invalid UTF-8. "No props" is {}.
func cleanProps(p json.RawMessage) (string, bool) {
	p = bytes.TrimSpace(p)
	if len(p) == 0 || string(p) == "null" {
		return "{}", true
	}
	if len(p) > trackMaxPropBytes || p[0] != '{' {
		return "", false
	}
	var m map[string]interface{}
	if err := json.Unmarshal(p, &m); err != nil {
		return "", false
	}
	b, err := json.Marshal(m)
	// Postgres's jsonb cannot hold a NUL character, and one bad row would
	// fail the whole batch.
	if err != nil || bytes.Contains(b, []byte(`\u0000`)) {
		return "", false
	}
	return string(b), true
}

// validEvents keeps the events that pass the checks of the contract and dates
// each one: the phone's time when it is believable, the server's otherwise.
func validEvents(events []trackEvent, now time.Time) []eventRow {
	if len(events) > trackMaxEvents {
		events = events[:trackMaxEvents]
	}
	out := make([]eventRow, 0, len(events))
	for _, e := range events {
		if !eventNameRe.MatchString(e.N) {
			continue
		}
		props, ok := cleanProps(e.P)
		if !ok {
			continue
		}
		at := now
		if e.T > 0 {
			t := time.UnixMilli(e.T)
			if !t.Before(now.Add(-trackMaxAge)) && !t.After(now.Add(trackMaxAhead)) {
				if t.Before(now) {
					at = t
				}
			}
		}
		out = append(out, eventRow{at: at, name: e.N, props: props})
	}
	return out
}

func rpcTrack(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, _ := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}
	if len(payload) > 256*1024 {
		return "", runtime.NewError("payload too large", 3)
	}
	var req trackRequest
	if err := json.Unmarshal([]byte(payload), &req); err != nil {
		return "", runtime.NewError("invalid payload", 3)
	}
	now := time.Now()
	rows := validEvents(req.Events, now)
	if len(rows) == 0 || db == nil {
		return `{"accepted":0}`, nil
	}
	n := dailyQuota.take(userID, len(rows), now)
	rows = rows[:n]
	if n == 0 {
		return `{"accepted":0}`, nil
	}
	d := req.Device
	dev := [6]string{
		cleanText(d.AppVersion, 32), cleanText(d.Platform, 32), cleanText(d.Model, 64),
		cleanText(d.OS, 32), cleanText(d.Locale, 16), cleanText(d.SessionID, 64),
	}
	if err := insertEvents(ctx, db, userID, dev, rows); err != nil {
		dailyQuota.giveBack(userID, n, now)
		logger.Error("track: insert failed for %s: %v", userID, err)
		return "", runtime.NewError("could not store the events", 13)
	}
	return fmt.Sprintf(`{"accepted":%d}`, n), nil
}

// insertEvents writes a batch in one statement, notes the player's first event
// (kept only when it is earlier than what is already known) and the days they
// were here.
func insertEvents(ctx context.Context, db *sql.DB, userID string, dev [6]string, rows []eventRow) error {
	var sb strings.Builder
	sb.WriteString(`INSERT INTO analytics_events (at, user_id, name, props, app_version, platform, device, os, locale, session_id) VALUES `)
	args := make([]interface{}, 0, len(rows)*4+7)
	args = append(args, userID, dev[0], dev[1], dev[2], dev[3], dev[4], dev[5])
	first := rows[0].at
	days := map[string]bool{}
	for i, r := range rows {
		days[tehranDay(r.at)] = true
		if i > 0 {
			sb.WriteString(",")
		}
		k := len(args)
		fmt.Fprintf(&sb, "($%d, $1::uuid, $%d, $%d::jsonb, $2, $3, $4, $5, $6, $7)", k+1, k+2, k+3)
		args = append(args, r.at, r.name, r.props)
		if r.at.Before(first) {
			first = r.at
		}
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, sb.String(), args...); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO analytics_players (user_id, first_at) VALUES ($1::uuid, $2)
		ON CONFLICT (user_id) DO UPDATE SET first_at = EXCLUDED.first_at
		WHERE analytics_players.first_at > EXCLUDED.first_at`, userID, first); err != nil {
		return err
	}
	for day := range days {
		if _, err := tx.ExecContext(ctx, `INSERT INTO analytics_days (day, user_id) VALUES ($1::date, $2::uuid)
			ON CONFLICT DO NOTHING`, day, userID); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ---------- events the server records itself

// recordServerEvent stores an event that belongs to no player (a match
// starting, a table filling). It never blocks the caller: the match loop must
// not wait on the database, so the insert runs on its own with a short
// deadline, and a nil handle (tests, or a failed start) records nothing.
func recordServerEvent(ctx context.Context, db *sql.DB, name string, props map[string]interface{}) {
	if db == nil {
		return
	}
	b, err := json.Marshal(props)
	if err != nil || props == nil {
		b = []byte("{}")
	}
	at := time.Now()
	logger := analyticsLogger
	go func() {
		c, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if _, err := db.ExecContext(c,
			`INSERT INTO analytics_events (at, name, props, platform) VALUES ($1, $2, $3::jsonb, 'server')`,
			at, name, string(b)); err != nil && logger != nil {
			logger.Warn("analytics: could not record %s: %v", name, err)
		}
	}()
}

// ---------- the match's own events

// onlineMatchStarted records an online game (public or friends) leaving the
// ready check. A game against the computer is the app's to report.
func onlineMatchStarted(ms *MatchState, tc turnCtx) {
	if !ms.ReadyCheck {
		return
	}
	humans, personas := 0, 0
	for i := range ms.Players {
		switch {
		case ms.Players[i].Persona:
			personas++
		case !ms.Players[i].IsAI:
			humans++
		}
	}
	recordServerEvent(tc.ctx, analyticsDB, "online_match_start", map[string]interface{}{
		"players":  len(ms.Players),
		"humans":   humans,
		"personas": personas,
		"rated":    ms.Rated,
		"public":   ms.Public,
	})
}

// onlineMatchEnded records the end of an online game that was played; a table
// cancelled before its first turn is not a game.
func onlineMatchEnded(ms *MatchState, tc turnCtx, reason EndReason) {
	if !ms.ReadyCheck || ms.StartedAtUnix == 0 {
		return
	}
	rounds := 0
	for i := range ms.Players {
		if ms.Players[i].TurnsTaken > rounds {
			rounds = ms.Players[i].TurnsTaken
		}
	}
	sec := tc.now/1000 - ms.StartedAtUnix
	if sec < 0 {
		sec = 0
	}
	recordServerEvent(tc.ctx, analyticsDB, "online_match_end", map[string]interface{}{
		"reason": string(reason),
		"rounds": rounds,
		"sec":    sec,
	})
}

// tableFilled records a public table getting its last seat: how long it took
// from the first player sitting down, and how many of the seats are people.
func tableFilled(ms *MatchState, tc turnCtx) {
	if !ms.Public {
		return
	}
	sec := int64(0)
	if ms.FirstSeatedMs > 0 && tc.now > ms.FirstSeatedMs {
		sec = (tc.now - ms.FirstSeatedMs) / 1000
	}
	recordServerEvent(tc.ctx, analyticsDB, "table_filled", map[string]interface{}{
		"sec":     sec,
		"humans":  ms.humanSeatCount(),
		"players": len(ms.Players),
	})
}

// tableLeftBeforeFill records a player giving up on a public table that was
// still filling.
func tableLeftBeforeFill(ms *MatchState, tc turnCtx) {
	if !ms.Public {
		return
	}
	sec := int64(0)
	if ms.FirstSeatedMs > 0 && tc.now > ms.FirstSeatedMs {
		sec = (tc.now - ms.FirstSeatedMs) / 1000
	}
	recordServerEvent(tc.ctx, analyticsDB, "table_left_before_fill", map[string]interface{}{
		"sec":     sec,
		"seated":  len(ms.Players),
		"players": ms.ExpectedPlayerCount,
	})
}
