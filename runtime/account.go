package main

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/heroiclabs/nakama-common/runtime"
)

// accountMetadata mirrors §3 of BACKEND_DOC: the JSON stored in Nakama account metadata.
type accountMetadata struct {
	Generation    string  `json:"generation"`
	AvatarID      string  `json:"avatarId"`
	Onboarded     bool    `json:"onboarded"`
	ActiveMatchID *string `json:"activeMatchId"`
}

// validGenerations are the 5 clans a player picks at sign-up: the game's five
// peoples (Humans of Light, Merfolk of Water, Elves of Nature, Dragonkin of
// Fire, Void Born of Shadow). Cosmetic only, no gameplay effect.
var validGenerations = map[string]bool{
	"human":     true,
	"merfolk":   true,
	"elf":       true,
	"dragonkin": true,
	"voidborn":  true,
}

// validAvatarIDs are the 30 merchant portraits (A-01..A-30) and "custom",
// a player's own photo (shown only on their device; others see A-01).
var validAvatarIDs = func() map[string]bool {
	m := map[string]bool{"custom": true}
	for i := 1; i <= 30; i++ {
		m[fmt.Sprintf("A-%02d", i)] = true
	}
	return m
}()

// readMetadata fetches and unmarshals the calling user's account metadata.
func readMetadata(ctx context.Context, nk runtime.NakamaModule, userID string) (*accountMetadata, error) {
	account, err := nk.AccountGetId(ctx, userID)
	if err != nil {
		return nil, err
	}
	var meta accountMetadata
	if raw := account.GetUser().GetMetadata(); raw != "" {
		if err := json.Unmarshal([]byte(raw), &meta); err != nil {
			return nil, err
		}
	}
	return &meta, nil
}

// writeMetadata marshals and stores metadata back to the account.
func writeMetadata(ctx context.Context, nk runtime.NakamaModule, userID string, meta *accountMetadata) error {
	m, err := metadataMap(meta)
	if err != nil {
		return err
	}
	return nk.AccountUpdateId(ctx, userID, "", m, "", "", "", "", "")
}

// setActiveMatch stamps the one-game-at-a-time lock. Best effort: the match is
// already live, so a storage hiccup here must not stop the game.
func setActiveMatch(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule, userID, matchID string) {
	if userID == "" || matchID == "" {
		return
	}
	meta, err := readMetadata(ctx, nk, userID)
	if err != nil {
		logger.Warn("setActiveMatch: read failed for %s: %v", userID, err)
		return
	}
	meta.ActiveMatchID = &matchID
	if err := writeMetadata(ctx, nk, userID, meta); err != nil {
		logger.Warn("setActiveMatch: write failed for %s: %v", userID, err)
	}
}

// clearActiveMatch releases the lock so the player can start a new game. Called
// for every player whenever a match reaches a terminal state, including a
// cancelled lobby and a server shutdown.
func clearActiveMatch(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule, userID string) {
	if userID == "" {
		return
	}
	meta, err := readMetadata(ctx, nk, userID)
	if err != nil {
		logger.Warn("clearActiveMatch: read failed for %s: %v", userID, err)
		return
	}
	if meta.ActiveMatchID == nil {
		return
	}
	meta.ActiveMatchID = nil
	if err := writeMetadata(ctx, nk, userID, meta); err != nil {
		logger.Warn("clearActiveMatch: write failed for %s: %v", userID, err)
	}
}

// metadataMap is meta as the map AccountUpdateId stores in the account's
// metadata field.
func metadataMap(meta *accountMetadata) (map[string]interface{}, error) {
	b, err := json.Marshal(meta)
	if err != nil {
		return nil, err
	}
	var m map[string]interface{}
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	return m, nil
}

// applyProfile copies the player's display name and portrait from their
// account onto their seat. Presence usernames are Nakama's unique handles,
// not the name the player chose, so the seat is corrected on every join.
func applyProfile(ms *MatchState, tc turnCtx, userID string) {
	seat := ms.SeatOf(userID)
	if seat < 0 || tc.nk == nil {
		return
	}
	account, err := tc.nk.AccountGetId(tc.ctx, userID)
	if err != nil || account.GetUser() == nil {
		return
	}
	user := account.GetUser()
	if name := user.GetDisplayName(); name != "" {
		ms.Players[seat].DisplayName = name
	}
	var meta accountMetadata
	if raw := user.GetMetadata(); raw != "" && json.Unmarshal([]byte(raw), &meta) == nil {
		ms.Players[seat].AvatarID = meta.AvatarID
	}
}
