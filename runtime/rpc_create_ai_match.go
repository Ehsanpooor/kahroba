package main

import (
	"context"
	"database/sql"
	"encoding/json"

	"github.com/heroiclabs/nakama-common/runtime"
)

type createAIMatchRequest struct {
	Difficulty   string `json:"difficulty"`   // easy | normal | hard
	AICount      int    `json:"aiCount"`      // 1..3 bots; defaults to 1
	PlayerName   string `json:"playerName"`   // optional display name override
	WinThreshold int    `json:"winThreshold"` // optional: 15 | 20 | 25 | 30, default WinThreshold
}

type createAIMatchResponse struct {
	MatchID    string `json:"matchId"`
	Difficulty string `json:"difficulty"`
	Seats      int    `json:"seats"`
}

// rpcCreateAIMatch starts a single-player game against the built-in engine.
//
// The bot plays from a real seat in an authoritative match rather than in the
// client, so the same rules engine, the same turn clock and the same hidden
// information rules apply. That also means an AI game cannot be used to fake a
// result: it is unrated by construction and its history record is flagged.
func rpcCreateAIMatch(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if !ok || userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}

	var req createAIMatchRequest
	if payload != "" {
		if err := json.Unmarshal([]byte(payload), &req); err != nil {
			return "", runtime.NewError("invalid payload", 3)
		}
	}

	aiCount := req.AICount
	if aiCount == 0 {
		aiCount = 1
	}
	if aiCount < 1 || aiCount > 3 {
		return "", runtime.NewError("aiCount must be between 1 and 3", 3)
	}
	difficulty := normalizeDifficulty(req.Difficulty)
	if req.WinThreshold == 0 {
		req.WinThreshold = WinThreshold
	}
	if !validWinThreshold(req.WinThreshold) {
		return "", runtime.NewError("winThreshold must be 15, 20, 25 or 30", 3)
	}

	meta, err := readMetadata(ctx, nk, userID)
	if err != nil {
		return "", runtime.NewError("failed to read account", 13)
	}
	if meta.ActiveMatchID != nil {
		return "", runtime.NewError("already in a match", 9)
	}

	displayName := req.PlayerName
	if displayName == "" {
		if account, err := nk.AccountGetId(ctx, userID); err == nil {
			displayName = account.GetUser().GetDisplayName()
			if displayName == "" {
				displayName = account.GetUser().GetUsername()
			}
		}
	}

	// Seat 0 is the human, so the player moves first.
	matchID, err := nk.MatchCreate(ctx, "splendor_match", map[string]interface{}{
		"rated":        false,
		"userIds":      []string{userID},
		"names":        []string{displayName},
		"playerCount":  1 + aiCount,
		"aiCount":      aiCount,
		"aiDifficulty": string(difficulty),
		"winThreshold": req.WinThreshold,
	})
	if err != nil {
		logger.Error("rpcCreateAIMatch: MatchCreate failed: %v", err)
		return "", runtime.NewError("failed to create match", 13)
	}

	meta.ActiveMatchID = &matchID
	if err := writeMetadata(ctx, nk, userID, meta); err != nil {
		logger.Warn("rpcCreateAIMatch: failed to stamp activeMatchId for %s: %v", userID, err)
	}

	out, _ := json.Marshal(createAIMatchResponse{
		MatchID:    matchID,
		Difficulty: string(difficulty),
		Seats:      1 + aiCount,
	})
	return string(out), nil
}
