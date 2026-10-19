package main

import (
	"context"
	"database/sql"

	"github.com/heroiclabs/nakama-common/runtime"
)

// onMatchmakerMatched is called by Nakama when a full group of players are found
// by the matchmaker (BACKEND_DOC §5). It creates the authoritative match, stamps
// activeMatchId on all players, and returns the match ID so Nakama can route clients.
func onMatchmakerMatched(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, entries []runtime.MatchmakerEntry) (string, error) {
	userIDs := make([]string, 0, len(entries))
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		userIDs = append(userIDs, e.GetPresence().GetUserId())
		names = append(names, e.GetPresence().GetUsername())
	}

	matchID, err := nk.MatchCreate(ctx, "splendor_match", map[string]interface{}{
		"rated":       true,
		"userIds":     userIDs,
		"names":       names,
		"playerCount": len(entries),
	})
	if err != nil {
		return "", runtime.NewError("failed to create match", 13)
	}

	// Stamp activeMatchId on every matched player so get_active_game returns the new match.
	// Best-effort: the match is already created, so log and continue on individual failures.
	for _, uid := range userIDs {
		meta, err := readMetadata(ctx, nk, uid)
		if err != nil {
			logger.Warn("onMatchmakerMatched: readMetadata failed for %s: %v", uid, err)
			continue
		}
		meta.ActiveMatchID = &matchID
		if err := writeMetadata(ctx, nk, uid, meta); err != nil {
			logger.Warn("onMatchmakerMatched: writeMetadata failed for %s: %v", uid, err)
		}
	}

	return matchID, nil
}
