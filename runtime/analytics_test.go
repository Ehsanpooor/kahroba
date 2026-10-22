package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// analytics_test.go — what `track` keeps and drops (analytics.go), and the
// crash grouping of admin_stats.

func ev(n string, t int64, p string) trackEvent {
	return trackEvent{N: n, T: t, P: json.RawMessage(p)}
}

func TestTrack_ValidEvents(t *testing.T) {
	now := time.UnixMilli(1_761_120_000_000)
	ms := now.UnixMilli()
	big := `{"x": "` + strings.Repeat("a", 2048) + `"}`
	rows := validEvents([]trackEvent{
		ev("game_end", ms-1000, `{"mode": "ai", "won": true}`), // kept, phone time
		ev("tutorial_start", ms, ``),                           // kept, no props
		ev("Game_end", ms, `{}`),                               // capital letter
		ev("g", ms, `{}`),                                      // too short
		ev("a"+strings.Repeat("b", 40), ms, `{}`),              // 41 characters
		ev("screen", ms, `["menu"]`),                           // props not an object
		ev("screen", ms, `"menu"`),                             // props not an object
		ev("error", ms, big),                                   // props too big
		ev("screen", ms, `{"name": "a\u0000b"}`),               // NUL: Postgres refuses it
		ev("app_open", ms-8*24*3600*1000, `{"first": true}`),   // too old: server time
		ev("app_open", ms+10*60*1000, `{}`),                    // far future: server time
		ev("app_open", ms+60*1000, `{}`),                       // slightly ahead: now
	}, now)
	names := []string{}
	for _, r := range rows {
		names = append(names, r.name)
	}
	if strings.Join(names, ",") != "game_end,tutorial_start,app_open,app_open,app_open" {
		t.Fatalf("kept %v", names)
	}
	if !rows[0].at.Equal(now.Add(-time.Second)) {
		t.Errorf("a recent phone time was not kept: %v", rows[0].at)
	}
	if rows[1].props != "{}" {
		t.Errorf("missing props stored as %q, want {}", rows[1].props)
	}
	for _, r := range rows[2:] {
		if !r.at.Equal(now) {
			t.Errorf("an unbelievable time %v was kept, want the server's", r.at)
		}
	}
}

func TestTrack_AtMostFiftyACall(t *testing.T) {
	now := time.Now()
	events := make([]trackEvent, 80)
	for i := range events {
		events[i] = ev("screen", now.UnixMilli(), `{"name": "menu"}`)
	}
	if n := len(validEvents(events, now)); n != trackMaxEvents {
		t.Errorf("kept %d of 80, want %d", n, trackMaxEvents)
	}
}

func TestTrack_DailyAllowance(t *testing.T) {
	q := &trackQuota{count: map[string]int{}}
	day := time.Date(2026, 10, 22, 10, 0, 0, 0, time.UTC)
	got := 0
	for i := 0; i < 41; i++ {
		got += q.take("u1", 50, day)
	}
	if got != trackMaxPerDay {
		t.Errorf("a player stored %d events in a day, want %d", got, trackMaxPerDay)
	}
	if n := q.take("u2", 50, day); n != 50 {
		t.Errorf("another player got %d, want 50", n)
	}
	q.giveBack("u2", 50, day)
	if q.count["u2"] != 0 {
		t.Error("a failed insert still counted")
	}
	if n := q.take("u1", 50, day.Add(24*time.Hour)); n != 50 {
		t.Errorf("the next day the player got %d, want 50", n)
	}
}

func TestTrack_NeedsAPlayerAndAPayload(t *testing.T) {
	if _, err := rpcTrack(context.Background(), &mockLogger{t}, nil, nil, `{"events": []}`); rpcCode(err) != 16 {
		t.Errorf("without a session: err = %v, want unauthenticated", err)
	}
	if _, err := rpcTrack(asUser("u1"), &mockLogger{t}, nil, nil, `{"events": `); rpcCode(err) != 3 {
		t.Errorf("broken JSON: err = %v, want invalid argument", err)
	}
	out, err := rpcTrack(asUser("u1"), &mockLogger{t}, nil, nil, `{"device": {}, "events": [{"n": "BAD", "t": 0, "p": {}}]}`)
	if err != nil || out != `{"accepted":0}` {
		t.Errorf("only bad events: %s, %v; want accepted 0", out, err)
	}
}

// A nil database records nothing and does not panic: the match tests run
// through every place a server event is recorded.
func TestRecordServerEvent_NilDatabase(t *testing.T) {
	recordServerEvent(context.Background(), nil, "online_match_start", map[string]interface{}{"players": 2})
}

func TestCrashSignature(t *testing.T) {
	log := "Godot Engine v4.7\nloading table\nERROR: Condition \"!p\" is true.\n   at: foo (core/x.cpp:12)\n\n"
	if got := crashSignature(log); got != `ERROR: Condition "!p" is true.` {
		t.Errorf("signature = %q", got)
	}
	if got := crashSignature("a\nlast line\n"); got != "last line" {
		t.Errorf("signature without an error line = %q", got)
	}
	if got := crashSignature(" \n"); got != "(empty log)" {
		t.Errorf("signature of an empty log = %q", got)
	}
}

func TestTehranDays(t *testing.T) {
	// 20:29 UTC is 23:59 in Tehran; 20:30 UTC is the next Tehran day
	if d := tehranDay(time.Date(2026, 10, 21, 20, 29, 0, 0, time.UTC)); d != "2026-10-21" {
		t.Errorf("tehranDay = %s", d)
	}
	if d := tehranDay(time.Date(2026, 10, 21, 20, 30, 0, 0, time.UTC)); d != "2026-10-22" {
		t.Errorf("tehranDay = %s", d)
	}
	m := tehranMidnight(time.Date(2026, 10, 22, 1, 0, 0, 0, time.UTC), 1)
	if !m.Equal(time.Date(2026, 10, 20, 20, 30, 0, 0, time.UTC)) {
		t.Errorf("tehranMidnight = %v", m.UTC())
	}
}
