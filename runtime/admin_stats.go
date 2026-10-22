package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/heroiclabs/nakama-common/runtime"
)

// admin_stats.go — the numbers behind the admin page's «آمار» tab.
//
//	admin_stats  {"days": 30}  → see adminStats below   (server key only)
//
// Days are Tehran days. Iran has kept +03:30 all year since 2022, so a fixed
// offset is exact and does not depend on the database knowing time zones.
// Every query reads a bounded window through an index: (name, at) for the
// events of one kind, analytics_days for players per day and retention.

var tehranZone = time.FixedZone("Asia/Tehran", 3*3600+30*60)

// dayOf is the SQL for the Tehran day of a timestamptz column.
func dayOf(col string) string {
	return "((" + col + " AT TIME ZONE 'UTC') + interval '210 minutes')::date"
}

// num is the SQL for a numeric prop, NULL when it is missing or not a number,
// so one odd event can never make a cast fail the whole query.
func num(key string) string {
	return "(CASE WHEN jsonb_typeof(props->'" + key + "') = 'number' THEN (props->>'" + key + "')::float END)"
}

func tehranDay(t time.Time) string { return t.In(tehranZone).Format("2006-01-02") }

// tehranMidnight is the start of the Tehran day `back` days before t's.
func tehranMidnight(t time.Time, back int) time.Time {
	l := t.In(tehranZone)
	return time.Date(l.Year(), l.Month(), l.Day()-back, 0, 0, 0, 0, tehranZone)
}

type statsTotals struct {
	Players       int64   `json:"players"`       // everyone ever seen
	NewPlayers    int64   `json:"newPlayers"`    // first seen in the window
	ActivePlayers int64   `json:"activePlayers"` // seen in the window
	ActiveToday   int64   `json:"activeToday"`
	Active7       int64   `json:"active7"` // the last 7 days, today included
	Events        int64   `json:"events"`
	Games         int64   `json:"games"`         // game_end from the app
	OnlineMatches int64   `json:"onlineMatches"` // online_match_end from the server
	AppOpens      int64   `json:"appOpens"`
	AvgSessionSec float64 `json:"avgSessionSec"`
	Errors        int64   `json:"errors"`
	Crashes       int64   `json:"crashes"`
}

type statsDay struct {
	Day    string `json:"day"`
	Active int64  `json:"active"`
	New    int64  `json:"new"`
	Games  int64  `json:"games"`
	Online int64  `json:"online"` // online games started
}

type retentionRate struct {
	Pct      *float64 `json:"pct"` // null until a cohort is old enough
	Players  int64    `json:"players"`
	Returned int64    `json:"returned"`
}

type retentionCohort struct {
	Day  string `json:"day"`
	Size int64  `json:"size"`
	D1   *int64 `json:"d1"` // null: day N has not ended yet, or is outside the 30 cohorts
	D7   *int64 `json:"d7"`
	D30  *int64 `json:"d30"`
}

type statsRetention struct {
	D1      retentionRate     `json:"d1"`
	D7      retentionRate     `json:"d7"`
	D30     retentionRate     `json:"d30"`
	Cohorts []retentionCohort `json:"cohorts"`
}

type statsMode struct {
	Mode    string `json:"mode"`
	Started int64  `json:"started"`
	Ended   int64  `json:"ended"`
	Quit    int64  `json:"quit"`
	Won     int64  `json:"won"`
}

type statsOnline struct {
	Started        int64   `json:"started"`
	Ended          int64   `json:"ended"`
	Public         int64   `json:"public"`
	Friends        int64   `json:"friends"`
	AvgHumans      float64 `json:"avgHumans"`
	AvgSec         float64 `json:"avgSec"`
	TablesFilled   int64   `json:"tablesFilled"`
	MedianFillSec  float64 `json:"medianFillSec"`
	AvgFillSec     float64 `json:"avgFillSec"`
	LeftBeforeFill int64   `json:"leftBeforeFill"`
}

type statsSearch struct {
	Started        int64   `json:"started"`
	Found          int64   `json:"found"`
	Cancelled      int64   `json:"cancelled"`
	MedianWaitSec  float64 `json:"medianWaitSec"`
	AvgWaitSec     float64 `json:"avgWaitSec"`
	AvgCancelSec   float64 `json:"avgCancelSec"`
	LeftBeforeFill int64   `json:"leftBeforeFill"`
}

type statsAdSlot struct {
	Slot    string `json:"slot"`
	Reached int64  `json:"reached"`
	Shown   int64  `json:"shown"`
}

type statsCount struct {
	Name    string `json:"name"`
	Players int64  `json:"players"`
	Count   int64  `json:"count"`
}

type statsError struct {
	Kind     string `json:"kind"` // error | crash
	Message  string `json:"message"`
	File     string `json:"file,omitempty"`
	Line     string `json:"line,omitempty"`
	Count    int64  `json:"count"`
	Players  int64  `json:"players"`
	LastSeen string `json:"lastSeen"` // Tehran time, "2006-01-02 15:04"
	Version  string `json:"version"`  // of the latest one
	Log      string `json:"log,omitempty"`
}

type adminStats struct {
	Days        int            `json:"days"`
	From        string         `json:"from"`
	Today       string         `json:"today"`
	GeneratedAt string         `json:"generatedAt"`
	Totals      statsTotals    `json:"totals"`
	Daily       []statsDay     `json:"daily"`
	Retention   statsRetention `json:"retention"`
	Modes       []statsMode    `json:"modes"`
	Online      statsOnline    `json:"online"`
	Search      statsSearch    `json:"search"`
	Ads         []statsAdSlot  `json:"ads"`
	Versions    []statsCount   `json:"versions"`
	Devices     []statsCount   `json:"devices"`
	Platforms   []statsCount   `json:"platforms"`
	Screens     []statsCount   `json:"screens"`
	Errors      []statsError   `json:"errors"`
	Crashes     []statsError   `json:"crashes"`
}

func rpcAdminStats(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	if err := requireServerCall(ctx); err != nil {
		return "", err
	}
	var req struct {
		Days int `json:"days"`
	}
	if strings.TrimSpace(payload) != "" {
		if err := json.Unmarshal([]byte(payload), &req); err != nil {
			return "", runtime.NewError("invalid payload", 3)
		}
	}
	if req.Days <= 0 {
		req.Days = 30
	}
	if req.Days > 90 {
		req.Days = 90
	}
	if db == nil {
		return "", runtime.NewError("no database", 13)
	}
	c, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()
	out, err := buildAdminStats(c, db, req.Days, time.Now())
	if err != nil {
		logger.Error("admin_stats: %v", err)
		return "", runtime.NewError("stats query failed: "+err.Error(), 13)
	}
	b, err := json.Marshal(out)
	if err != nil {
		return "", runtime.NewError("stats unavailable", 13)
	}
	return string(b), nil
}

func buildAdminStats(ctx context.Context, db *sql.DB, days int, now time.Time) (*adminStats, error) {
	since := tehranMidnight(now, days-1)
	today := tehranMidnight(now, 0)
	week := tehranMidnight(now, 6)
	out := &adminStats{
		Days:        days,
		From:        tehranDay(since),
		Today:       tehranDay(now),
		GeneratedAt: now.In(tehranZone).Format("2006-01-02 15:04"),
		Daily:       []statsDay{},
		Modes:       []statsMode{},
		Ads:         []statsAdSlot{},
		Errors:      []statsError{},
		Crashes:     []statsError{},
	}
	steps := []func() error{
		func() error { return statsTotalsQuery(ctx, db, out, since, today, week) },
		func() error { return statsDailyQuery(ctx, db, out, since, now, days) },
		func() error { return statsRetentionQuery(ctx, db, out, now) },
		func() error { return statsModesQuery(ctx, db, out, since) },
		func() error { return statsOnlineQuery(ctx, db, out, since) },
		func() error { return statsSearchQuery(ctx, db, out, since) },
		func() error { return statsAdsQuery(ctx, db, out, since) },
		func() error {
			var err error
			out.Versions, err = statsGroupQuery(ctx, db, "app_version", "app_open", since, 20)
			return err
		},
		func() error {
			var err error
			out.Devices, err = statsGroupQuery(ctx, db, "device", "app_open", since, 20)
			return err
		},
		func() error {
			var err error
			out.Platforms, err = statsGroupQuery(ctx, db, "platform || CASE WHEN os <> '' THEN ' ' || os ELSE '' END", "app_open", since, 20)
			return err
		},
		func() error {
			var err error
			out.Screens, err = statsGroupQuery(ctx, db, "coalesce(props->>'name', '')", "screen", since, 30)
			return err
		},
		func() error { return statsErrorsQuery(ctx, db, out, since) },
		func() error { return statsCrashesQuery(ctx, db, out, since) },
	}
	for _, step := range steps {
		if err := step(); err != nil {
			return nil, err
		}
	}
	return out, nil
}

func statsTotalsQuery(ctx context.Context, db *sql.DB, out *adminStats, since, today, week time.Time) error {
	t := &out.Totals
	var avgSession sql.NullFloat64
	err := db.QueryRowContext(ctx, `SELECT
			count(*),
			count(*) FILTER (WHERE name = 'game_end'),
			count(*) FILTER (WHERE name = 'online_match_end'),
			count(*) FILTER (WHERE name = 'app_open'),
			count(*) FILTER (WHERE name = 'error'),
			count(*) FILTER (WHERE name = 'crash'),
			avg(`+num("sec")+`) FILTER (WHERE name = 'session_end')
		FROM analytics_events WHERE at >= $1`, since).
		Scan(&t.Events, &t.Games, &t.OnlineMatches, &t.AppOpens, &t.Errors, &t.Crashes, &avgSession)
	if err != nil {
		return err
	}
	t.AvgSessionSec = round1(avgSession.Float64)
	err = db.QueryRowContext(ctx, `SELECT
			(SELECT count(*) FROM analytics_players),
			(SELECT count(*) FROM analytics_players WHERE first_at >= $1),
			(SELECT count(DISTINCT user_id) FROM analytics_days WHERE day >= $2::date),
			(SELECT count(*) FROM analytics_days WHERE day = $3::date),
			(SELECT count(DISTINCT user_id) FROM analytics_days WHERE day >= $4::date)`,
		since, tehranDay(since), tehranDay(today), tehranDay(week)).
		Scan(&t.Players, &t.NewPlayers, &t.ActivePlayers, &t.ActiveToday, &t.Active7)
	return err
}

func statsDailyQuery(ctx context.Context, db *sql.DB, out *adminStats, since, now time.Time, days int) error {
	byDay := map[string]*statsDay{}
	for i := days - 1; i >= 0; i-- {
		d := tehranDay(tehranMidnight(now, i))
		out.Daily = append(out.Daily, statsDay{Day: d})
	}
	for i := range out.Daily {
		byDay[out.Daily[i].Day] = &out.Daily[i]
	}
	fill := func(query string, set func(*statsDay, int64), args ...interface{}) error {
		rows, err := db.QueryContext(ctx, query, args...)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var day time.Time
			var n int64
			if err := rows.Scan(&day, &n); err != nil {
				return err
			}
			if d := byDay[day.Format("2006-01-02")]; d != nil {
				set(d, n)
			}
		}
		return rows.Err()
	}
	if err := fill(`SELECT day, count(*) FROM analytics_days WHERE day >= $1::date GROUP BY day`,
		func(d *statsDay, n int64) { d.Active = n }, tehranDay(since)); err != nil {
		return err
	}
	if err := fill(`SELECT `+dayOf("first_at")+` AS d, count(*) FROM analytics_players WHERE first_at >= $1 GROUP BY d`,
		func(d *statsDay, n int64) { d.New = n }, since); err != nil {
		return err
	}
	if err := fill(`SELECT `+dayOf("at")+` AS d, count(*) FROM analytics_events WHERE name = 'game_end' AND at >= $1 GROUP BY d`,
		func(d *statsDay, n int64) { d.Games = n }, since); err != nil {
		return err
	}
	return fill(`SELECT `+dayOf("at")+` AS d, count(*) FROM analytics_events WHERE name = 'online_match_start' AND at >= $1 GROUP BY d`,
		func(d *statsDay, n int64) { d.Online = n }, since)
}

// statsRetentionQuery: a player's cohort is the Tehran day of their first
// event. D-N is the share of a cohort that used the app again exactly N days
// later. Each rate is taken over the 30 latest cohorts whose day N has
// already ended, so a day still in progress never drags the numbers down.
func statsRetentionQuery(ctx context.Context, db *sql.DB, out *adminStats, now time.Time) error {
	todayIdx := tehranMidnight(now, 0)
	from := tehranMidnight(now, 60) // the oldest cohort D30 can use
	to := tehranMidnight(now, 1)    // cohorts up to the day before yesterday
	rows, err := db.QueryContext(ctx, `
		SELECT c.d0, count(*),
			count(*) FILTER (WHERE EXISTS (SELECT 1 FROM analytics_days a WHERE a.user_id = c.user_id AND a.day = c.d0 + 1)),
			count(*) FILTER (WHERE EXISTS (SELECT 1 FROM analytics_days a WHERE a.user_id = c.user_id AND a.day = c.d0 + 7)),
			count(*) FILTER (WHERE EXISTS (SELECT 1 FROM analytics_days a WHERE a.user_id = c.user_id AND a.day = c.d0 + 30))
		FROM (SELECT user_id, `+dayOf("first_at")+` AS d0 FROM analytics_players
		      WHERE first_at >= $1 AND first_at < $2) c
		GROUP BY c.d0 ORDER BY c.d0`, from, to)
	if err != nil {
		return err
	}
	defer rows.Close()
	r := &out.Retention
	r.Cohorts = []retentionCohort{}
	for rows.Next() {
		var day time.Time
		var size, d1, d7, d30 int64
		if err := rows.Scan(&day, &size, &d1, &d7, &d30); err != nil {
			return err
		}
		d0 := time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, tehranZone)
		age := int(todayIdx.Sub(d0).Hours()/24 + 0.5) // days from the cohort to today
		c := retentionCohort{Day: day.Format("2006-01-02"), Size: size}
		take := func(n int, v int64, rate *retentionRate) *int64 {
			// day n ended (age > n) and the cohort is one of the 30 latest such
			if age <= n || age > n+30 {
				return nil
			}
			rate.Players += size
			rate.Returned += v
			x := v
			return &x
		}
		c.D1 = take(1, d1, &r.D1)
		c.D7 = take(7, d7, &r.D7)
		c.D30 = take(30, d30, &r.D30)
		r.Cohorts = append(r.Cohorts, c)
	}
	for _, rate := range []*retentionRate{&r.D1, &r.D7, &r.D30} {
		if rate.Players > 0 {
			p := round1(100 * float64(rate.Returned) / float64(rate.Players))
			rate.Pct = &p
		}
	}
	return rows.Err()
}

func statsModesQuery(ctx context.Context, db *sql.DB, out *adminStats, since time.Time) error {
	rows, err := db.QueryContext(ctx, `SELECT coalesce(props->>'mode', ''),
			count(*) FILTER (WHERE name = 'game_start'),
			count(*) FILTER (WHERE name = 'game_end'),
			count(*) FILTER (WHERE name = 'game_end' AND props->>'quit' = 'true'),
			count(*) FILTER (WHERE name = 'game_end' AND props->>'won' = 'true')
		FROM analytics_events WHERE name IN ('game_start', 'game_end') AND at >= $1
		GROUP BY 1 ORDER BY 3 DESC, 2 DESC`, since)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var m statsMode
		if err := rows.Scan(&m.Mode, &m.Started, &m.Ended, &m.Quit, &m.Won); err != nil {
			return err
		}
		out.Modes = append(out.Modes, m)
	}
	return rows.Err()
}

func statsOnlineQuery(ctx context.Context, db *sql.DB, out *adminStats, since time.Time) error {
	o := &out.Online
	var avgHumans, avgSec, medFill, avgFill sql.NullFloat64
	err := db.QueryRowContext(ctx, `SELECT
			count(*) FILTER (WHERE name = 'online_match_start'),
			count(*) FILTER (WHERE name = 'online_match_end'),
			count(*) FILTER (WHERE name = 'online_match_start' AND props->>'public' = 'true'),
			count(*) FILTER (WHERE name = 'online_match_start' AND props->>'public' = 'false'),
			avg(`+num("humans")+`) FILTER (WHERE name = 'online_match_start'),
			avg(`+num("sec")+`) FILTER (WHERE name = 'online_match_end'),
			count(*) FILTER (WHERE name = 'table_filled'),
			percentile_cont(0.5) WITHIN GROUP (ORDER BY `+num("sec")+`) FILTER (WHERE name = 'table_filled'),
			avg(`+num("sec")+`) FILTER (WHERE name = 'table_filled'),
			count(*) FILTER (WHERE name = 'table_left_before_fill')
		FROM analytics_events
		WHERE name IN ('online_match_start', 'online_match_end', 'table_filled', 'table_left_before_fill') AND at >= $1`, since).
		Scan(&o.Started, &o.Ended, &o.Public, &o.Friends, &avgHumans, &avgSec, &o.TablesFilled, &medFill, &avgFill, &o.LeftBeforeFill)
	o.AvgHumans, o.AvgSec = round1(avgHumans.Float64), round1(avgSec.Float64)
	o.MedianFillSec, o.AvgFillSec = round1(medFill.Float64), round1(avgFill.Float64)
	return err
}

func statsSearchQuery(ctx context.Context, db *sql.DB, out *adminStats, since time.Time) error {
	s := &out.Search
	var med, avg, avgCancel sql.NullFloat64
	err := db.QueryRowContext(ctx, `SELECT
			count(*) FILTER (WHERE name = 'search_start'),
			count(*) FILTER (WHERE name = 'search_found'),
			count(*) FILTER (WHERE name = 'search_cancel'),
			percentile_cont(0.5) WITHIN GROUP (ORDER BY `+num("sec")+`) FILTER (WHERE name = 'search_found'),
			avg(`+num("sec")+`) FILTER (WHERE name = 'search_found'),
			avg(`+num("sec")+`) FILTER (WHERE name = 'search_cancel'),
			count(*) FILTER (WHERE name = 'table_left_before_fill')
		FROM analytics_events
		WHERE name IN ('search_start', 'search_found', 'search_cancel', 'table_left_before_fill') AND at >= $1`, since).
		Scan(&s.Started, &s.Found, &s.Cancelled, &med, &avg, &avgCancel, &s.LeftBeforeFill)
	s.MedianWaitSec, s.AvgWaitSec, s.AvgCancelSec = round1(med.Float64), round1(avg.Float64), round1(avgCancel.Float64)
	return err
}

func statsAdsQuery(ctx context.Context, db *sql.DB, out *adminStats, since time.Time) error {
	rows, err := db.QueryContext(ctx, `SELECT coalesce(props->>'slot', ''), count(*),
			count(*) FILTER (WHERE props->>'shown' = 'true')
		FROM analytics_events WHERE name = 'ad_slot' AND at >= $1
		GROUP BY 1 ORDER BY 1`, since)
	if err != nil {
		return err
	}
	defer rows.Close()
	seen := map[string]bool{}
	for rows.Next() {
		var a statsAdSlot
		if err := rows.Scan(&a.Slot, &a.Reached, &a.Shown); err != nil {
			return err
		}
		seen[a.Slot] = true
		out.Ads = append(out.Ads, a)
	}
	// the three slots always appear, so the page shows a zero rather than nothing
	for _, slot := range []string{"pregame_online", "pregame_ai", "postgame"} {
		if !seen[slot] {
			out.Ads = append(out.Ads, statsAdSlot{Slot: slot})
		}
	}
	return rows.Err()
}

// statsGroupQuery counts players and events of one kind by an expression over
// the event row (a column, or a prop). expr is always a constant of this file.
func statsGroupQuery(ctx context.Context, db *sql.DB, expr, event string, since time.Time, limit int) ([]statsCount, error) {
	rows, err := db.QueryContext(ctx, `SELECT `+expr+` AS k, count(DISTINCT user_id), count(*)
		FROM analytics_events WHERE name = $1 AND at >= $2
		GROUP BY k ORDER BY 2 DESC, 3 DESC LIMIT $3`, event, since, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	list := []statsCount{}
	for rows.Next() {
		var c statsCount
		if err := rows.Scan(&c.Name, &c.Players, &c.Count); err != nil {
			return nil, err
		}
		list = append(list, c)
	}
	return list, rows.Err()
}

func statsErrorsQuery(ctx context.Context, db *sql.DB, out *adminStats, since time.Time) error {
	rows, err := db.QueryContext(ctx, `SELECT
			left(coalesce(props->>'msg', ''), 400), left(coalesce(props->>'file', ''), 200), left(coalesce(props->>'line', ''), 12),
			count(*), count(DISTINCT user_id), max(at),
			(array_agg(app_version ORDER BY at DESC))[1]
		FROM analytics_events WHERE name = 'error' AND at >= $1
		GROUP BY 1, 2, 3 ORDER BY 6 DESC LIMIT 50`, since)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		e := statsError{Kind: "error"}
		var last time.Time
		if err := rows.Scan(&e.Message, &e.File, &e.Line, &e.Count, &e.Players, &last, &e.Version); err != nil {
			return err
		}
		e.LastSeen = last.In(tehranZone).Format("2006-01-02 15:04")
		out.Errors = append(out.Errors, e)
	}
	return rows.Err()
}

// statsCrashesQuery groups the latest crash logs by the line that most looks
// like the cause, which SQL cannot pick out of a 4 KB log tail.
func statsCrashesQuery(ctx context.Context, db *sql.DB, out *adminStats, since time.Time) error {
	rows, err := db.QueryContext(ctx, `SELECT at, coalesce(user_id::text, ''), app_version, left(coalesce(props->>'log', ''), 4096)
		FROM analytics_events WHERE name = 'crash' AND at >= $1 ORDER BY at DESC LIMIT 300`, since)
	if err != nil {
		return err
	}
	defer rows.Close()
	type group struct {
		e       statsError
		players map[string]bool
		last    time.Time
	}
	groups := map[string]*group{}
	for rows.Next() {
		var at time.Time
		var user, version, log string
		if err := rows.Scan(&at, &user, &version, &log); err != nil {
			return err
		}
		sig := crashSignature(log)
		g := groups[sig]
		if g == nil {
			// rows come newest first: the first of a group is its latest
			g = &group{e: statsError{Kind: "crash", Message: sig, Version: version, Log: log,
				LastSeen: at.In(tehranZone).Format("2006-01-02 15:04")}, players: map[string]bool{}, last: at}
			groups[sig] = g
		}
		g.e.Count++
		if user != "" {
			g.players[user] = true
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	list := make([]*group, 0, len(groups))
	for _, g := range groups {
		g.e.Players = int64(len(g.players))
		list = append(list, g)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].last.After(list[j].last) })
	for i, g := range list {
		if i == 30 {
			break
		}
		out.Crashes = append(out.Crashes, g.e)
	}
	return nil
}

// crashSignature is the last line of a log that reports an error, or else its
// last non-empty line, shortened.
func crashSignature(log string) string {
	lines := strings.Split(strings.ReplaceAll(log, "\r", ""), "\n")
	pick := ""
	for i := len(lines) - 1; i >= 0; i-- {
		l := strings.TrimSpace(lines[i])
		if l == "" {
			continue
		}
		if pick == "" {
			pick = l
		}
		u := strings.ToUpper(l)
		if strings.Contains(u, "ERROR") || strings.Contains(u, "FATAL") || strings.Contains(u, "CRASH") || strings.Contains(u, "SIGNAL") {
			pick = l
			break
		}
	}
	if pick == "" {
		return "(empty log)"
	}
	if r := []rune(pick); len(r) > 200 {
		pick = string(r[:200]) + "…"
	}
	return pick
}

func round1(f float64) float64 {
	if f < 0 {
		return -round1(-f)
	}
	return float64(int64(f*10+0.5)) / 10
}
