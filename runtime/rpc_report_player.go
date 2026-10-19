package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"

	"github.com/heroiclabs/nakama-common/runtime"
)

type reportPlayerRequest struct {
	MatchID    string `json:"matchId"`
	ReportedID string `json:"reportedId"`
	Reason     string `json:"reason"`
}

type reportPlayerResponse struct {
	OK bool `json:"ok"`
}

// rpcReportPlayer writes a system-owned report record for manual admin review (§13, §16.2).
func rpcReportPlayer(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if !ok || userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}

	var req reportPlayerRequest
	if err := json.Unmarshal([]byte(payload), &req); err != nil {
		return "", runtime.NewError("invalid payload", 3)
	}
	if req.MatchID == "" || req.ReportedID == "" || req.Reason == "" {
		return "", runtime.NewError("matchId, reportedId, and reason are required", 3)
	}

	reportID := newUUID()
	rec := reportRecord{
		MatchID:    req.MatchID,
		ReporterID: userID,
		ReportedID: req.ReportedID,
		Reason:     req.Reason,
		CreatedAt:  time.Now().UTC().Format(time.RFC3339),
	}
	b, _ := json.Marshal(rec)

	if _, err := nk.StorageWrite(ctx, []*runtime.StorageWrite{
		{
			Collection:      ReportsCollection,
			Key:             reportID,
			UserID:          "",
			Value:           string(b),
			PermissionRead:  runtime.STORAGE_PERMISSION_NO_READ,
			PermissionWrite: runtime.STORAGE_PERMISSION_NO_WRITE,
		},
	}); err != nil {
		return "", runtime.NewError("storage write failed", 13)
	}

	out, _ := json.Marshal(reportPlayerResponse{OK: true})
	return string(out), nil
}
