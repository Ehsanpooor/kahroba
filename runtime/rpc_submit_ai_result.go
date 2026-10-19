package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"time"

	"github.com/heroiclabs/nakama-common/runtime"
)

type submitAIResultRequest struct {
	Result     string `json:"result"` // "win" | "loss"
	Power      int    `json:"power"`
	Difficulty string `json:"difficulty"` // "easy" | "normal" | "hard"
	FinishedAt string `json:"finishedAt"` // RFC3339 client timestamp, untrusted
}

type submitAIResultResponse struct {
	OK bool `json:"ok"`
}

// rpcSubmitAIResult stores an untrusted, unrated AI-game history record (§12, §16.2).
// No validation beyond schema — AI results are analytics-only and never affect rating.
func rpcSubmitAIResult(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if !ok || userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}

	var req submitAIResultRequest
	if err := json.Unmarshal([]byte(payload), &req); err != nil {
		return "", runtime.NewError("invalid payload", 3)
	}

	// The result is client-reported and never affects rating, but the enums are
	// still normalised so history and analytics stay queryable.
	result := strings.ToLower(strings.TrimSpace(req.Result))
	if result != "win" && result != "loss" {
		return "", runtime.NewError("result must be win or loss", 3)
	}
	difficulty := strings.ToLower(strings.TrimSpace(req.Difficulty))
	switch difficulty {
	case "easy", "normal", "hard":
	case "":
		difficulty = "normal"
	default:
		return "", runtime.NewError("difficulty must be easy, normal or hard", 3)
	}
	if req.Power < 0 {
		return "", runtime.NewError("power cannot be negative", 3)
	}

	// The client clock is untrusted: accept its timestamp only when it is
	// plausible, so a wrong device clock cannot scatter history entries.
	playedAt := time.Now().UTC().Format(time.RFC3339)
	if req.FinishedAt != "" {
		if t, err := time.Parse(time.RFC3339, req.FinishedAt); err == nil {
			if delta := time.Since(t); delta > -time.Hour && delta < 24*time.Hour {
				playedAt = t.UTC().Format(time.RFC3339)
			}
		}
	}

	gameID := newUUID()
	rec := historyRecord{
		GameID:      gameID,
		IsAI:        true,
		Result:      result,
		Power:       req.Power,
		Difficulty:  difficulty,
		RatingDelta: 0,
		Opponents:   []string{},
		PlayedAt:    playedAt,
	}
	b, err := json.Marshal(rec)
	if err != nil {
		return "", runtime.NewError("internal error", 13)
	}

	if _, err = nk.StorageWrite(ctx, []*runtime.StorageWrite{
		{
			Collection:      HistoryCollection,
			Key:             gameID,
			UserID:          userID,
			Value:           string(b),
			PermissionRead:  runtime.STORAGE_PERMISSION_OWNER_READ,
			PermissionWrite: runtime.STORAGE_PERMISSION_NO_WRITE,
		},
	}); err != nil {
		return "", runtime.NewError("storage write failed", 13)
	}

	out, _ := json.Marshal(submitAIResultResponse{OK: true})
	return string(out), nil
}
