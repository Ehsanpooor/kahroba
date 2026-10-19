package main

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

type joinPrivateMatchRequest struct {
	MatchID string `json:"matchId"`
}

type joinPrivateMatchResponse struct {
	OK bool `json:"ok"`
}

// rpcJoinPrivateMatch implements the join_private_match RPC (BACKEND_DOC §16.2).
// Validates that the caller is on the invite list, then returns ok so the client
// can proceed with the standard Nakama MatchJoin call.
// activeMatchId is stamped in MatchJoin (not here) to avoid marking players who
// validate but never actually connect.
func rpcJoinPrivateMatch(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if !ok || userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}

	var req joinPrivateMatchRequest
	if err := json.Unmarshal([]byte(payload), &req); err != nil {
		return "", runtime.NewError("invalid payload", 3)
	}
	if req.MatchID == "" {
		return "", runtime.NewError("matchId is required", 3)
	}

	meta, err := readMetadata(ctx, nk, userID)
	if err != nil {
		return "", runtime.NewError("failed to read account", 13)
	}
	if meta.ActiveMatchID != nil {
		return "", runtime.NewError("already in a match", 9)
	}

	objects, err := nk.StorageRead(ctx, []*runtime.StorageRead{
		{Collection: "private_invites", Key: req.MatchID, UserID: ""},
	})
	if err != nil {
		return "", runtime.NewError("failed to read invite record", 13)
	}
	if len(objects) == 0 {
		return "", runtime.NewError("invite not found", 5)
	}

	var doc privateInviteDoc
	if err := json.Unmarshal([]byte(objects[0].GetValue()), &doc); err != nil {
		return "", runtime.NewError("invalid invite record", 13)
	}
	if doc.Status != "open" {
		return "", runtime.NewError("match is no longer open", 9)
	}
	if !isAllowedJoiner(doc, userID) {
		return "", runtime.NewError("not invited", 7)
	}

	out, _ := json.Marshal(joinPrivateMatchResponse{OK: true})
	return string(out), nil
}
