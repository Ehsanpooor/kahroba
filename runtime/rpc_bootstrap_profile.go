package main

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

type bootstrapProfileRequest struct {
	DisplayName string `json:"displayName"`
	Generation  string `json:"generation"`
	AvatarID    string `json:"avatarId"`
}

type bootstrapProfileResponse struct {
	OK bool `json:"ok"`
}

// rpcBootstrapProfile implements the bootstrap_profile RPC (BACKEND_DOC §16.2).
// Sets display name, generation, avatarId, and onboarded=true on the account.
func rpcBootstrapProfile(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if !ok || userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}

	var req bootstrapProfileRequest
	if err := json.Unmarshal([]byte(payload), &req); err != nil {
		return "", runtime.NewError("invalid payload", 3)
	}

	if req.DisplayName == "" {
		return "", runtime.NewError("displayName is required", 3)
	}
	if req.Generation != "" && !validGenerations[req.Generation] {  // the clan is optional
		return "", runtime.NewError("invalid generation", 3)
	}
	if !validAvatarIDs[req.AvatarID] {
		return "", runtime.NewError("invalid avatarId", 3)
	}

	meta, err := readMetadata(ctx, nk, userID)
	if err != nil {
		return "", runtime.NewError("failed to read account", 13)
	}

	meta.Generation = req.Generation
	meta.AvatarID = req.AvatarID
	meta.Onboarded = true
	// ActiveMatchID preserved as-is

	metaMap, err := metadataMap(meta)
	if err != nil {
		return "", runtime.NewError("failed to encode metadata", 13)
	}

	// One AccountUpdateId call sets the display name and the metadata together.
	// The username stays the unique one Nakama generated: display names may repeat.
	if err := nk.AccountUpdateId(ctx, userID, "", metaMap, req.DisplayName, "", "", "", ""); err != nil {
		return "", runtime.NewError("failed to update account", 13)
	}

	out, _ := json.Marshal(bootstrapProfileResponse{OK: true})
	return string(out), nil
}
