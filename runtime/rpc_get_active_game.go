package main

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

type getActiveGameResponse struct {
	MatchID *string `json:"matchId"`
	// What that game is, so the menu can offer the right way back: mode
	// public | private | ai, its phase, its size and (a friends' room) its code.
	Mode        string `json:"mode,omitempty"`
	Phase       string `json:"phase,omitempty"`
	PlayerCount int    `json:"playerCount,omitempty"`
	Code        string `json:"code,omitempty"`
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

	resp := getActiveGameResponse{MatchID: meta.ActiveMatchID}
	if meta.ActiveMatchID != nil {
		m, err := nk.MatchGet(ctx, *meta.ActiveMatchID)
		if err != nil || m == nil {
			// the match is gone: the lock is stale, so release it
			clearActiveMatch(ctx, logger, nk, userID)
			resp.MatchID = nil
		} else {
			var label matchLabel
			if json.Unmarshal([]byte(m.GetLabel().GetValue()), &label) == nil {
				resp.Mode, resp.Phase, resp.PlayerCount = label.Mode, label.Phase, label.PlayerCount
			}
			if resp.Mode == "private" {
				objs, err := nk.StorageRead(ctx, []*runtime.StorageRead{{Collection: "private_invites", Key: *meta.ActiveMatchID}})
				if err == nil && len(objs) > 0 {
					var doc privateInviteDoc
					if json.Unmarshal([]byte(objs[0].GetValue()), &doc) == nil {
						resp.Code = doc.Code
					}
				}
			}
		}
	}
	out, _ := json.Marshal(resp)
	return string(out), nil
}
