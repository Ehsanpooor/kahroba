package main

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

type getMatchHistoryRequest struct {
	Filter string `json:"filter"` // "online" | "ai" | "all"  (default: "all")
	Cursor string `json:"cursor"` // Nakama pagination cursor; empty for first page
}

type getMatchHistoryResponse struct {
	Entries []historyRecord `json:"entries"`
	Cursor  string          `json:"cursor"` // empty when no more pages
}

// rpcGetMatchHistory reads the caller's match history with an optional filter (§12, §16.2).
func rpcGetMatchHistory(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if !ok || userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}

	var req getMatchHistoryRequest
	if payload != "" {
		if err := json.Unmarshal([]byte(payload), &req); err != nil {
			return "", runtime.NewError("invalid payload", 3)
		}
	}
	if req.Filter == "" {
		req.Filter = "all"
	}

	objects, nextCursor, err := nk.StorageList(ctx, "", userID, HistoryCollection, 100, req.Cursor)
	if err != nil {
		return "", runtime.NewError("storage list failed", 13)
	}

	entries := make([]historyRecord, 0, len(objects))
	for _, obj := range objects {
		var rec historyRecord
		if err := json.Unmarshal([]byte(obj.GetValue()), &rec); err != nil {
			logger.Warn("get_match_history: unmarshal failed for key %s: %v", obj.GetKey(), err)
			continue
		}
		switch req.Filter {
		case "ai":
			if !rec.IsAI {
				continue
			}
		case "online":
			if rec.IsAI {
				continue
			}
		}
		entries = append(entries, rec)
	}

	out, _ := json.Marshal(getMatchHistoryResponse{
		Entries: entries,
		Cursor:  nextCursor,
	})
	return string(out), nil
}
