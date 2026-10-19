package main

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

type concedeMatchRequest struct {
	MatchID string `json:"matchId"`
}

type concedeMatchResponse struct {
	OK bool `json:"ok"`
}

// rpcConcedeMatch implements the concede_match RPC (BACKEND_DOC §16.2).
// Signals the live match to execute handleConcede for the caller, which applies
// a rated loss and finalizes the game when only one active player remains.
func rpcConcedeMatch(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if !ok || userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}

	var req concedeMatchRequest
	if err := json.Unmarshal([]byte(payload), &req); err != nil {
		return "", runtime.NewError("invalid payload", 3)
	}
	if req.MatchID == "" {
		return "", runtime.NewError("matchId is required", 3)
	}

	signal, _ := json.Marshal(map[string]string{
		"action": "concede",
		"userId": userID,
	})
	if _, err := nk.MatchSignal(ctx, req.MatchID, string(signal)); err != nil {
		return "", runtime.NewError("failed to signal match", 13)
	}

	out, _ := json.Marshal(concedeMatchResponse{OK: true})
	return string(out), nil
}
