package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"

	"github.com/heroiclabs/nakama-common/runtime"
)

// matchSearchParams holds the criteria for a public matchmaker search (§5).
// Add fields here as new matching properties are introduced — toMatchmakerArgs
// is the only function that needs to change; the RPC body never restructures.
type matchSearchParams struct {
	PlayerCount int
	// Future: TurnTime int, WinThreshold int, etc.
}

func (p matchSearchParams) toMatchmakerArgs() (minCount, maxCount int, query string, stringProps map[string]string, numericProps map[string]float64) {
	minCount = p.PlayerCount
	maxCount = p.PlayerCount
	query = fmt.Sprintf(
		"+properties.playerCount:>=%d +properties.playerCount:<=%d", // Nakama 3 names every ticket property "properties."
		p.PlayerCount, p.PlayerCount,
	)
	stringProps = map[string]string{}
	numericProps = map[string]float64{
		"playerCount": float64(p.PlayerCount),
	}
	return
}

type startPublicSearchRequest struct {
	PlayerCount int `json:"playerCount"`
}

// startPublicSearchResponse carries the matchmaker parameters the client must pass
// to its socket MatchmakerAdd call (BACKEND_DOC §5).
// NakamaModule v1.32 does not expose a server-side MatchmakerAdd; the server
// validates the gate and configures the criteria, the client socket executes it.
type startPublicSearchResponse struct {
	MinCount          int                `json:"minCount"`
	MaxCount          int                `json:"maxCount"`
	Query             string             `json:"query"`
	StringProperties  map[string]string  `json:"stringProperties"`
	NumericProperties map[string]float64 `json:"numericProperties"`
	// TimeoutSeconds tells the client how long to wait before withdrawing from
	// the matchmaker (BACKEND_DOC §5). Server-driven so a single env change
	// keeps server intent and client behavior in sync.
	TimeoutSeconds int `json:"timeoutSeconds"`
	// RefillMatchID, when present, is a public match of the requested size
	// whose ready check has a seat open because a matched player failed to
	// confirm. The client should join it directly (socket match_join with
	// this ID) instead of, or after withdrawing, its matchmaker ticket. If that
	// join is refused the seat has gone: carry on with the matchmaker using the
	// parameters above, which are always returned.
	RefillMatchID string `json:"refillMatchId,omitempty"`
}

// rpcStartPublicSearch implements the start_public_search RPC (BACKEND_DOC §16.2).
// Gates on activeMatchId==null, then returns matchmaker parameters for the client
// to use with its socket MatchmakerAdd call.
func rpcStartPublicSearch(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	userID, ok := ctx.Value(runtime.RUNTIME_CTX_USER_ID).(string)
	if !ok || userID == "" {
		return "", runtime.NewError("unauthenticated", 16)
	}

	var req startPublicSearchRequest
	if err := json.Unmarshal([]byte(payload), &req); err != nil {
		return "", runtime.NewError("invalid payload", 3)
	}

	if req.PlayerCount < 2 || req.PlayerCount > 4 {
		return "", runtime.NewError("playerCount must be 2, 3, or 4", 3)
	}

	meta, err := readMetadata(ctx, nk, userID)
	if err != nil {
		return "", runtime.NewError("failed to read account", 13)
	}
	if meta.ActiveMatchID != nil {
		return "", runtime.NewError("already in a match", 9)
	}

	params := matchSearchParams{PlayerCount: req.PlayerCount}
	minCount, maxCount, query, strProps, numProps := params.toMatchmakerArgs()

	out, _ := json.Marshal(startPublicSearchResponse{
		MinCount:          minCount,
		MaxCount:          maxCount,
		Query:             query,
		StringProperties:  strProps,
		NumericProperties: numProps,
		TimeoutSeconds:    MatchmakerTimeoutSeconds,
		RefillMatchID:     findRefillMatch(ctx, logger, nk, req.PlayerCount),
	})
	return string(out), nil
}

// refillQuery finds public matches of one size whose ready check is holding a
// seat open (see matchLabel in match_ready.go).
func refillQuery(playerCount int) string {
	return fmt.Sprintf(
		"+label.mode:public +label.open:>=1 +label.playerCount:>=%d +label.playerCount:<=%d",
		playerCount, playerCount,
	)
}

// findRefillMatch returns a match a searcher can drop straight into, or "".
//
// This is the closest thing to pulling the next player out of the queue that
// Nakama allows: the runtime cannot add, inspect or take matchmaker tickets
// (there is no server-side MatchmakerAdd, and the matched hook only fires for
// complete groups). So the match advertises its open seat in its label and a
// searcher looks for one here, both when they start searching and when they
// poll this RPC while their ticket is waiting. A lookup failure is never an
// error: the player simply matchmakes as usual.
func findRefillMatch(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule, playerCount int) string {
	matches, err := nk.MatchList(ctx, 10, true, "", nil, nil, refillQuery(playerCount))
	if err != nil {
		logger.Warn("findRefillMatch: MatchList failed: %v", err)
		return ""
	}
	for _, m := range matches {
		if id := m.GetMatchId(); id != "" {
			return id
		}
	}
	return ""
}
