package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/heroiclabs/nakama-common/runtime"
)

// remote_config.go — the settings the app reads from the server at start.
//
// Ads, the update prompt, an announcement on the menu, the rate prompt and the
// analytics switch are all decided here, so they can change without a new app
// build (docs/REMOTE_CONFIG_ADS_ANALYTICS.md §1).
//
//	get_client_config  {}             → the config        (a signed-in player)
//	admin_get_config   {}             → the config        (server key only)
//	admin_set_config   <the config>   → the stored config (server key only)
//
// The value lives in storage (collection "config", key "client", owned by the
// system and invisible to players) and in memory: it is read once at start and
// replaced in memory when the admin saves, so a player's request never touches
// the database.

const (
	ConfigCollection = "config"
	ConfigKey        = "client"
)

type AdSlot struct {
	Enabled bool `json:"enabled"`
}

type AdSlots struct {
	PregameOnline AdSlot `json:"pregame_online"`
	PregameAI     AdSlot `json:"pregame_ai"`
	Postgame      AdSlot `json:"postgame"`
}

type AdsConfig struct {
	Enabled        bool    `json:"enabled"`
	MinIntervalSec int     `json:"minIntervalSec"`
	AdBreakMaxSec  int     `json:"adBreakMaxSec"`
	Slots          AdSlots `json:"slots"`
}

type LocalText struct {
	Fa string `json:"fa"`
	En string `json:"en"`
}

type Announcement struct {
	ID string `json:"id"`
	Fa string `json:"fa"`
	En string `json:"en"`
}

type RatePrompt struct {
	Enabled   bool `json:"enabled"`
	AfterWins int  `json:"afterWins"`
}

type AnalyticsConfig struct {
	Enabled  bool `json:"enabled"`
	FlushSec int  `json:"flushSec"`
}

type ClientConfig struct {
	Ads           AdsConfig       `json:"ads"`
	MinVersion    string          `json:"minVersion"`
	LatestVersion string          `json:"latestVersion"`
	UpdateURL     string          `json:"updateUrl"`
	UpdateMessage LocalText       `json:"updateMessage"`
	Announcement  *Announcement   `json:"announcement"` // null when there is none
	RatePrompt    RatePrompt      `json:"ratePrompt"`
	Analytics     AnalyticsConfig `json:"analytics"`
}

// defaultClientConfig is what the server answers until the admin saves
// something. Ads are off: no ad network is in the app yet.
func defaultClientConfig() ClientConfig {
	return ClientConfig{
		Ads: AdsConfig{
			Enabled:        false,
			MinIntervalSec: 180,
			AdBreakMaxSec:  30,
		},
		MinVersion:    "0.9.3",
		LatestVersion: "0.9.6",
		UpdateURL:     "https://cafebazaar.ir/app/ir.aizood.splendor",
		RatePrompt:    RatePrompt{Enabled: true, AfterWins: 2},
		Analytics:     AnalyticsConfig{Enabled: true, FlushSec: 30},
	}
}

var (
	remoteConfigMu  sync.RWMutex
	remoteConfigVal = defaultClientConfig()
)

// currentClientConfig is the config in force. It is a copy, so a caller may
// keep it without holding the lock.
func currentClientConfig() ClientConfig {
	remoteConfigMu.RLock()
	defer remoteConfigMu.RUnlock()
	c := remoteConfigVal
	if c.Announcement != nil {
		a := *c.Announcement
		c.Announcement = &a
	}
	return c
}

func setClientConfig(c ClientConfig) {
	remoteConfigMu.Lock()
	remoteConfigVal = c
	remoteConfigMu.Unlock()
}

// onlineAdBreakConfig reports whether an online table pauses for an ad once
// everyone is ready, and for how long at most.
func onlineAdBreakConfig() (bool, int) {
	c := currentClientConfig()
	return c.Ads.Enabled && c.Ads.Slots.PregameOnline.Enabled, c.Ads.AdBreakMaxSec
}

// loadClientConfig reads the stored config into memory. A stored value that
// no longer validates (an older shape, a hand edit) is ignored with a warning,
// so a bad save can never take the menu down: the defaults are served instead.
func loadClientConfig(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule) {
	objs, err := nk.StorageRead(ctx, []*runtime.StorageRead{{Collection: ConfigCollection, Key: ConfigKey}})
	if err != nil {
		logger.Warn("remote config: read failed, serving the defaults: %v", err)
		return
	}
	if len(objs) == 0 {
		logger.Info("remote config: nothing stored, serving the defaults")
		return
	}
	c, err := parseClientConfig([]byte(objs[0].GetValue()), defaultClientConfig())
	if err != nil {
		logger.Warn("remote config: stored value rejected, serving the defaults: %v", err)
		return
	}
	setClientConfig(c)
	logger.Info("remote config: loaded")
}

var versionRe = regexp.MustCompile(`^\d{1,4}(\.\d{1,4}){0,3}$`)

// compareVersions compares dotted numbers: "0.9.10" > "0.9.9", "1.0" == "1.0.0".
func compareVersions(a, b string) int {
	pa, pb := strings.Split(a, "."), strings.Split(b, ".")
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var x, y int
		if i < len(pa) {
			x, _ = strconv.Atoi(pa[i])
		}
		if i < len(pb) {
			y, _ = strconv.Atoi(pb[i])
		}
		if x != y {
			if x < y {
				return -1
			}
			return 1
		}
	}
	return 0
}

// parseClientConfig decodes a whole config over `base` (so a field the sender
// left out keeps its value) and validates it. Unknown fields are refused: a
// typo in the admin page must not be saved silently as "nothing changed".
func parseClientConfig(raw []byte, base ClientConfig) (ClientConfig, error) {
	c := base
	if c.Announcement != nil {
		a := *c.Announcement
		c.Announcement = &a
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return ClientConfig{}, fmt.Errorf("invalid config: %v", err)
	}
	if err := validateClientConfig(&c); err != nil {
		return ClientConfig{}, err
	}
	return c, nil
}

// validateClientConfig checks ranges and lengths, and tidies the texts.
func validateClientConfig(c *ClientConfig) error {
	if c.Ads.MinIntervalSec < 0 || c.Ads.MinIntervalSec > 86400 {
		return fmt.Errorf("ads.minIntervalSec must be 0..86400")
	}
	if c.Ads.AdBreakMaxSec < 5 || c.Ads.AdBreakMaxSec > 60 {
		return fmt.Errorf("ads.adBreakMaxSec must be 5..60")
	}
	c.MinVersion = strings.TrimSpace(c.MinVersion)
	c.LatestVersion = strings.TrimSpace(c.LatestVersion)
	if !versionRe.MatchString(c.MinVersion) {
		return fmt.Errorf("minVersion must be dotted numbers, like 0.9.3")
	}
	if !versionRe.MatchString(c.LatestVersion) {
		return fmt.Errorf("latestVersion must be dotted numbers, like 0.9.4")
	}
	if compareVersions(c.MinVersion, c.LatestVersion) > 0 {
		return fmt.Errorf("minVersion is newer than latestVersion")
	}
	c.UpdateURL = strings.TrimSpace(c.UpdateURL)
	if c.UpdateURL != "" {
		u, err := url.Parse(c.UpdateURL)
		if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" || len(c.UpdateURL) > 500 {
			return fmt.Errorf("updateUrl must be an http(s) address of at most 500 characters")
		}
	}
	for name, s := range map[string]*string{
		"updateMessage.fa": &c.UpdateMessage.Fa,
		"updateMessage.en": &c.UpdateMessage.En,
	} {
		if err := checkText(name, s); err != nil {
			return err
		}
	}
	if a := c.Announcement; a != nil {
		a.ID = strings.TrimSpace(a.ID)
		if err := checkText("announcement.fa", &a.Fa); err != nil {
			return err
		}
		if err := checkText("announcement.en", &a.En); err != nil {
			return err
		}
		switch {
		case a.ID == "" && a.Fa == "" && a.En == "":
			c.Announcement = nil // an empty form is no announcement
		case a.ID == "":
			return fmt.Errorf("announcement.id is required")
		case utf8.RuneCountInString(a.ID) > 64:
			return fmt.Errorf("announcement.id must be at most 64 characters")
		case a.Fa == "" && a.En == "":
			return fmt.Errorf("announcement needs a text")
		}
	}
	if c.RatePrompt.AfterWins < 0 || c.RatePrompt.AfterWins > 1000 {
		return fmt.Errorf("ratePrompt.afterWins must be 0..1000")
	}
	if c.Analytics.FlushSec < 5 || c.Analytics.FlushSec > 3600 {
		return fmt.Errorf("analytics.flushSec must be 5..3600")
	}
	return nil
}

func checkText(name string, s *string) error {
	*s = strings.TrimSpace(*s)
	if !utf8.ValidString(*s) {
		return fmt.Errorf("%s is not valid text", name)
	}
	if utf8.RuneCountInString(*s) > 500 {
		return fmt.Errorf("%s must be at most 500 characters", name)
	}
	return nil
}

// ---------- RPCs

func rpcGetClientConfig(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	if uid, _ := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string); uid == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}
	b, err := json.Marshal(currentClientConfig())
	if err != nil {
		return "", runtime.NewError("config unavailable", 13)
	}
	return string(b), nil
}

// requireServerCall refuses a call made with a player's session. The admin
// page reaches these RPCs through nginx with the runtime http key, which
// carries no user; a player's token always does.
func requireServerCall(ctx context.Context) error {
	if uid, _ := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string); uid != "" {
		return runtime.NewError("not allowed", 7)
	}
	return nil
}

func rpcAdminGetConfig(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	if err := requireServerCall(ctx); err != nil {
		return "", err
	}
	b, err := json.Marshal(currentClientConfig())
	if err != nil {
		return "", runtime.NewError("config unavailable", 13)
	}
	return string(b), nil
}

func rpcAdminSetConfig(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	if err := requireServerCall(ctx); err != nil {
		return "", err
	}
	c, err := parseClientConfig([]byte(payload), currentClientConfig())
	if err != nil {
		return "", runtime.NewError(err.Error(), 3)
	}
	b, err := json.Marshal(c)
	if err != nil {
		return "", runtime.NewError("config unavailable", 13)
	}
	if _, err := nk.StorageWrite(ctx, []*runtime.StorageWrite{{
		Collection:      ConfigCollection,
		Key:             ConfigKey,
		UserID:          "",
		Value:           string(b),
		PermissionRead:  runtime.STORAGE_PERMISSION_NO_READ,
		PermissionWrite: runtime.STORAGE_PERMISSION_NO_WRITE,
	}}); err != nil {
		logger.Error("admin_set_config: storage write failed: %v", err)
		return "", runtime.NewError("storage write failed", 13)
	}
	setClientConfig(c)
	logger.Info("remote config: saved by the admin")
	return string(b), nil
}
