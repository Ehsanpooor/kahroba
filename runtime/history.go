package main

import (
	"context"
	cryptorand "crypto/rand"
	"encoding/json"
	"fmt"
	"time"

	"github.com/heroiclabs/nakama-common/runtime"
)

// newUUID returns a random UUID v4 without pulling in an external package.
func newUUID() string {
	b := make([]byte, 16)
	_, _ = cryptorand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

const (
	HistoryCollection  = "history"
	MatchLogCollection = "match_log"
	ReportsCollection  = "reports"
)

// historyRecord is stored per player, owner-readable (BACKEND_DOC §15).
type historyRecord struct {
	GameID      string   `json:"gameId"`
	IsAI        bool     `json:"isAI"`
	Result      string   `json:"result"` // "win" | "loss" | "draw"
	Power       int      `json:"power"`
	Rank        int      `json:"rank,omitempty"`
	PlayerCount int      `json:"playerCount,omitempty"`
	Conceded    bool     `json:"conceded,omitempty"`
	Difficulty  string   `json:"difficulty,omitempty"` // AI games only
	RatingDelta int      `json:"ratingDelta"`
	Opponents   []string `json:"opponents"`
	PlayedAt    string   `json:"playedAt"` // RFC3339
}

// matchLogRecord is system-owned, for anti-cheat and analytics (§13, §15).
type matchLogRecord struct {
	GameID    string    `json:"gameId"`
	Mode      string    `json:"mode"` // "public" | "private"
	Rated     bool      `json:"rated"`
	PlayerIDs []string  `json:"playerIds"`
	Result    string    `json:"result"` // winning userID, or "draw"
	EndReason EndReason `json:"endReason,omitempty"`
	Turns     int       `json:"turns,omitempty"`
	StartedAt string    `json:"startedAt"`
	EndedAt   string    `json:"endedAt"`
}

// reportRecord is system-owned (§13, §15).
type reportRecord struct {
	MatchID    string `json:"matchId"`
	ReporterID string `json:"reporterId"`
	ReportedID string `json:"reportedId"`
	Reason     string `json:"reason"`
	CreatedAt  string `json:"createdAt"`
}

// writeMatchHistory persists one record per player plus a system match log at
// the end of every online match (§12). Results come from the ranked standings,
// so a player who conceded is recorded as a loss regardless of their Power.
func writeMatchHistory(
	ctx context.Context,
	logger runtime.Logger,
	nk runtime.NakamaModule,
	ms *MatchState,
	matchID string,
	standings []Standing,
	ratingDeltas map[string]int,
) {
	now := time.Now().UTC().Format(time.RFC3339)
	writes := make([]*runtime.StorageWrite, 0, len(ms.Players)+1)

	playerIDs := make([]string, 0, len(ms.Players))
	for i := range ms.Players {
		if ms.Players[i].UserID != "" && !ms.Players[i].IsAI {
			playerIDs = append(playerIDs, ms.Players[i].UserID)
		}
	}

	rankBySeat := make(map[int]int, len(standings))
	rankCount := map[int]int{}
	for _, s := range standings {
		rankBySeat[s.Index] = s.Rank
		rankCount[s.Rank]++
	}

	isAIGame := ms.hasAISeat()
	difficulty := ms.aiDifficultyLabel()

	for i := range ms.Players {
		pl := ms.Players[i]
		if pl.UserID == "" || pl.IsAI {
			continue // a bot has no account to write history against
		}

		rank := rankBySeat[i]
		result := "loss"
		switch {
		case rank == 1 && rankCount[1] > 1:
			result = "draw"
		case rank == 1:
			result = "win"
		}

		opponents := make([]string, 0, len(ms.Players)-1)
		for j := range ms.Players {
			if j != i && ms.Players[j].UserID != "" && (!ms.Players[j].IsAI || ms.Players[j].Persona) {
				opponents = append(opponents, ms.Players[j].UserID)
			}
		}

		rec := historyRecord{
			GameID:      matchID,
			IsAI:        isAIGame,
			Difficulty:  difficulty,
			Result:      result,
			Power:       PlayerPower(pl.HiredCards, len(pl.Artifacts)),
			Rank:        rank,
			PlayerCount: len(ms.Players),
			Conceded:    pl.Conceded,
			RatingDelta: ratingDeltas[pl.UserID],
			Opponents:   opponents,
			PlayedAt:    now,
		}
		b, err := json.Marshal(rec)
		if err != nil {
			logger.Warn("writeMatchHistory: marshal failed for %s: %v", pl.UserID, err)
			continue
		}
		writes = append(writes, &runtime.StorageWrite{
			Collection:      HistoryCollection,
			Key:             matchID,
			UserID:          pl.UserID,
			Value:           string(b),
			PermissionRead:  runtime.STORAGE_PERMISSION_OWNER_READ,
			PermissionWrite: runtime.STORAGE_PERMISSION_NO_WRITE,
		})
	}

	mode := "private"
	if ms.HostUserID == "" {
		mode = "public"
	}
	winnerUID := "draw"
	if ms.WinnerIndex >= 0 && ms.WinnerIndex < len(ms.Players) {
		winnerUID = ms.Players[ms.WinnerIndex].UserID
	}
	startedAt := now
	if ms.StartedAtUnix > 0 {
		startedAt = time.Unix(ms.StartedAtUnix, 0).UTC().Format(time.RFC3339)
	}
	if logB, err := json.Marshal(matchLogRecord{
		GameID:    matchID,
		Mode:      mode,
		Rated:     ms.Rated,
		PlayerIDs: playerIDs,
		Result:    winnerUID,
		EndReason: ms.EndReason,
		Turns:     ms.TurnNumber,
		StartedAt: startedAt,
		EndedAt:   now,
	}); err == nil {
		writes = append(writes, &runtime.StorageWrite{
			Collection:      MatchLogCollection,
			Key:             matchID,
			UserID:          "",
			Value:           string(logB),
			PermissionRead:  runtime.STORAGE_PERMISSION_NO_READ,
			PermissionWrite: runtime.STORAGE_PERMISSION_NO_WRITE,
		})
	}

	if _, err := nk.StorageWrite(ctx, writes); err != nil {
		logger.Warn("writeMatchHistory: StorageWrite failed: %v", err)
	}
}
