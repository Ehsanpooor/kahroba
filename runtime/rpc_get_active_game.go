package main

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

type getActiveGameResponse struct {
	MatchID *string `json:"matchId"`
}

// rpcGetActiveGame implements the get_active_game RPC (BACKEND_DOC §16.2).
// Returns the user's activeMatchId from account metadata, or null if none.
func rpcGetActiveGame(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if !ok || userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}

	meta, err := readMetadata(ctx, nk, userID)
	if err != nil {
		return "", runtime.NewError("failed to read account", 13)
	}

	out, _ := json.Marshal(getActiveGameResponse{MatchID: meta.ActiveMatchID})
	return string(out), nil
}
