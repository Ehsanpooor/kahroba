package main

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// remote_config_test.go — the client config: defaults, validation, and who may
// read and change it (remote_config.go).

// withClientConfig puts a config in force for one test.
func withClientConfig(t *testing.T, c ClientConfig) {
	t.Helper()
	old := currentClientConfig()
	setClientConfig(c)
	t.Cleanup(func() { setClientConfig(old) })
}

// The defaults are exactly the JSON of the contract (docs §1).
func TestClientConfig_DefaultsMatchTheContract(t *testing.T) {
	withClientConfig(t, defaultClientConfig())
	const want = `{
	  "ads": {"enabled": false, "minIntervalSec": 180, "adBreakMaxSec": 30,
	    "slots": {"pregame_online": {"enabled": false}, "pregame_ai": {"enabled": false}, "postgame": {"enabled": false}}},
	  "minVersion": "0.9.3", "latestVersion": "0.9.6",
	  "updateUrl": "https://cafebazaar.ir/app/ir.aizood.splendor",
	  "updateMessage": {"fa": "", "en": ""},
	  "announcement": null,
	  "ratePrompt": {"enabled": true, "afterWins": 2},
	  "analytics": {"enabled": true, "flushSec": 30}
	}`
	got, err := rpcGetClientConfig(asUser("p1"), &mockLogger{t}, nil, nil, "{}")
	if err != nil {
		t.Fatal(err)
	}
	var a, b interface{}
	_ = json.Unmarshal([]byte(got), &a)
	_ = json.Unmarshal([]byte(want), &b)
	if !reflect.DeepEqual(a, b) {
		t.Errorf("get_client_config =\n%s\nwant the contract's defaults", got)
	}
}

func TestClientConfig_NeedsAPlayer(t *testing.T) {
	if _, err := rpcGetClientConfig(context.Background(), &mockLogger{t}, nil, nil, "{}"); rpcCode(err) != 16 {
		t.Errorf("without a session: err = %v, want unauthenticated", err)
	}
}

func TestClientConfig_Validation(t *testing.T) {
	base := defaultClientConfig()
	bad := map[string]string{
		"interval too long":   `{"ads": {"minIntervalSec": 86401}}`,
		"interval negative":   `{"ads": {"minIntervalSec": -1}}`,
		"break too short":     `{"ads": {"adBreakMaxSec": 4}}`,
		"break too long":      `{"ads": {"adBreakMaxSec": 61}}`,
		"wrong type":          `{"ads": {"enabled": "yes"}}`,
		"version letters":     `{"minVersion": "0.9.x"}`,
		"version empty":       `{"latestVersion": ""}`,
		"min above latest":    `{"minVersion": "0.9.10", "latestVersion": "0.9.9"}`,
		"unknown field":       `{"adz": {}}`,
		"announcement no id":  `{"announcement": {"id": "", "fa": "سلام", "en": ""}}`,
		"announcement long":   `{"announcement": {"id": "` + strings.Repeat("a", 65) + `", "fa": "x", "en": ""}}`,
		"announcement silent": `{"announcement": {"id": "a1", "fa": "", "en": ""}}`,
		"text too long":       `{"updateMessage": {"fa": "` + strings.Repeat("ب", 501) + `", "en": ""}}`,
		"update url":          `{"updateUrl": "javascript:alert(1)"}`,
		"flush too fast":      `{"analytics": {"enabled": true, "flushSec": 1}}`,
		"not json":            `{"ads": `,
	}
	for name, raw := range bad {
		if _, err := parseClientConfig([]byte(raw), base); err == nil {
			t.Errorf("%s: %s was accepted", name, raw)
		}
	}

	good := `{"ads": {"enabled": true, "minIntervalSec": 0, "adBreakMaxSec": 60,
		"slots": {"pregame_online": {"enabled": true}, "pregame_ai": {"enabled": false}, "postgame": {"enabled": true}}},
		"minVersion": "0.9.9", "latestVersion": "0.9.10",
		"announcement": {"id": " 2026-11-01-a ", "fa": " سلام ", "en": ""}}`
	c, err := parseClientConfig([]byte(good), base)
	if err != nil {
		t.Fatalf("a valid config was refused: %v", err)
	}
	if !c.Ads.Enabled || !c.Ads.Slots.PregameOnline.Enabled || c.Ads.Slots.PregameAI.Enabled || c.Ads.AdBreakMaxSec != 60 {
		t.Errorf("ads = %+v", c.Ads)
	}
	if c.Announcement == nil || c.Announcement.ID != "2026-11-01-a" || c.Announcement.Fa != "سلام" {
		t.Errorf("announcement = %+v, want trimmed", c.Announcement)
	}
	if c.UpdateURL != base.UpdateURL || !c.RatePrompt.Enabled {
		t.Error("fields left out should keep their values")
	}

	c, err = parseClientConfig([]byte(`{"announcement": {"id": "", "fa": "", "en": ""}}`), c)
	if err != nil || c.Announcement != nil {
		t.Errorf("an empty announcement should clear it: %+v, %v", c.Announcement, err)
	}
}

func TestCompareVersions(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"0.9.10", "0.9.9", 1}, {"0.9.3", "0.9.4", -1}, {"1.0", "1.0.0", 0}, {"1", "0.99.99", 1},
	}
	for _, c := range cases {
		if got := compareVersions(c.a, c.b); got != c.want {
			t.Errorf("compareVersions(%s, %s) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

// The admin RPCs answer the server key (no user in the context) and refuse a
// player's session, whoever it is.
func TestAdminRPCs_RefusePlayerSessions(t *testing.T) {
	withClientConfig(t, defaultClientConfig())
	nk := newMockNK()
	player := asUser("00000000-0000-0000-0000-000000000001")
	if _, err := rpcAdminGetConfig(player, &mockLogger{t}, nil, nk, "{}"); rpcCode(err) != 7 {
		t.Errorf("admin_get_config with a session: err = %v, want permission denied", err)
	}
	if _, err := rpcAdminSetConfig(player, &mockLogger{t}, nil, nk, `{"ads": {"enabled": true}}`); rpcCode(err) != 7 {
		t.Errorf("admin_set_config with a session: err = %v, want permission denied", err)
	}
	if _, err := rpcAdminStats(player, &mockLogger{t}, nil, nk, `{"days": 30}`); rpcCode(err) != 7 {
		t.Errorf("admin_stats with a session: err = %v, want permission denied", err)
	}
	if len(nk.store) != 0 || currentClientConfig().Ads.Enabled {
		t.Fatal("a refused call changed the config")
	}
}

func TestAdminSetConfig_StoresAndAppliesAtOnce(t *testing.T) {
	withClientConfig(t, defaultClientConfig())
	nk := newMockNK()
	server := context.Background()

	if _, err := rpcAdminSetConfig(server, &mockLogger{t}, nil, nk, `{"ads": {"adBreakMaxSec": 2}}`); rpcCode(err) != 3 {
		t.Fatalf("an invalid config: err = %v, want invalid argument", err)
	}
	if len(nk.store) != 0 {
		t.Fatal("an invalid config was stored")
	}

	cfg := defaultClientConfig()
	cfg.Ads.Enabled = true
	cfg.Ads.Slots.PregameOnline.Enabled = true
	cfg.Announcement = &Announcement{ID: "a1", Fa: "خبر", En: "news"}
	raw, _ := json.Marshal(cfg)
	if _, err := rpcAdminSetConfig(server, &mockLogger{t}, nil, nk, string(raw)); err != nil {
		t.Fatalf("admin_set_config: %v", err)
	}
	stored := nk.store[nk.storeKey(ConfigCollection, ConfigKey, "")]
	if stored == "" {
		t.Fatal("nothing was stored under config/client")
	}
	if on, _ := onlineAdBreakConfig(); !on {
		t.Error("the new config is not in force")
	}
	got, _ := rpcGetClientConfig(asUser("p1"), &mockLogger{t}, nil, nil, "{}")
	if !strings.Contains(got, `"announcement":{"id":"a1","fa":"خبر","en":"news"}`) {
		t.Errorf("players see %s", got)
	}
	adminView, _ := rpcAdminGetConfig(server, &mockLogger{t}, nil, nk, "")
	if adminView != got {
		t.Errorf("admin_get_config = %s, want what players see", adminView)
	}

	// what a restart reads back
	setClientConfig(defaultClientConfig())
	loadClientConfig(server, &mockLogger{t}, nk)
	if c := currentClientConfig(); c.Announcement == nil || !c.Ads.Enabled {
		t.Errorf("loaded config = %+v, want the stored one", c)
	}
}

// A stored value that no longer validates is ignored rather than served.
func TestLoadClientConfig_BadStoredValueKeepsDefaults(t *testing.T) {
	withClientConfig(t, defaultClientConfig())
	nk := newMockNK()
	nk.store[nk.storeKey(ConfigCollection, ConfigKey, "")] = `{"ads": {"adBreakMaxSec": 1000}}`
	loadClientConfig(context.Background(), &mockLogger{t}, nk)
	if c := currentClientConfig(); c.Ads.AdBreakMaxSec != 30 {
		t.Errorf("adBreakMaxSec = %d, want the default 30", c.Ads.AdBreakMaxSec)
	}
}
