package main

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"

	"github.com/heroiclabs/nakama-common/runtime"
)

// rpc_get_catalog.go — the static game data, served from the server.
//
// The match protocol identifies a card by ID alone: the board arrives as
// ["H-01","M-04",...]. Something has to turn those into names, costs and Power.
// Hardcoding that table in the client is how the two halves drift apart, and
// this project has already paid for that once: the shipped card table carried 49
// costs that existed nowhere in the source deck.
//
// So the server owns the numbers and hands them out. The payload is static and
// carries a version derived from its own contents, which lets a client cache it
// permanently and re-fetch only when the data actually changes.

type catalogCard struct {
	ID       string  `json:"id"`
	Name     string  `json:"name"`
	Tier     int     `json:"tier"`
	Power    int     `json:"power"`
	Affinity Element `json:"affinity"`
	// Named to match the card objects that appear inside STATE_FULL, so a client
	// can decode both with one model.
	Cost      Cost `json:"hireCost"`
	CostTotal int  `json:"costTotal"`
}

type catalogArtifact struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Power       int    `json:"power"`
	Requirement Cost   `json:"requirement"`
}

// catalogConfig carries every rule constant the UI needs in order to render and
// validate optimistically. A client that reads these never has to hardcode a
// number that the server can change under it.
type catalogConfig struct {
	WinThreshold             int   `json:"winThreshold"`
	WinThresholdOptions      []int `json:"winThresholdOptions"`
	MaxReserve               int   `json:"maxReserve"`
	CoinHoldLimit            int   `json:"coinHoldLimit"`
	TurnSeconds              int   `json:"turnSeconds"`
	AbandonMissLimit         int   `json:"abandonMissLimit"`
	ChannelMinSupply         int   `json:"channelMinSupply"`
	ArtifactPower            int   `json:"artifactPower"`
	MaxHarvest               int   `json:"maxHarvest"`
	BoardWidth               int   `json:"boardWidth"`
	MatchmakerTimeoutSeconds int   `json:"matchmakerTimeoutSeconds"`
	ReadyTimeoutSeconds      int   `json:"readyTimeoutSeconds"`
	ReadyRefillSeconds       int   `json:"readyRefillSeconds"`
	ProvisionalGames         int   `json:"provisionalGames"`

	// Coin supply and revealed artifacts by table size, so a lobby can show the
	// setup before the match exists.
	SupplyPerColour map[string]int `json:"supplyPerColour"`
	ArtifactsShown  map[string]int `json:"artifactsShown"`

	Elements        []Element `json:"elements"`
	WildcardElement Element   `json:"wildcardElement"`
	Tiers           []int     `json:"tiers"`
	Difficulties    []string  `json:"difficulties"`
	Generations     []string  `json:"generations"`
	Avatars         []string  `json:"avatars"`
	RejectionCodes  []string  `json:"rejectionCodes"`
}

type catalogResponse struct {
	Version   string            `json:"version"`
	Cards     []catalogCard     `json:"cards"`
	Artifacts []catalogArtifact `json:"artifacts"`
	Config    catalogConfig     `json:"config"`
}

var (
	catalogOnce sync.Once
	catalogJSON string
	catalogVer  string
)

// buildCatalog assembles the payload once and caches the encoded bytes. The
// data is immutable for the life of the process, so every later call is a
// string copy.
func buildCatalog() (string, string) {
	catalogOnce.Do(func() {
		cards := make([]catalogCard, 0, len(AllCards))
		for _, c := range AllCards {
			cards = append(cards, catalogCard{
				ID:        c.ID,
				Name:      c.Name,
				Tier:      c.Tier,
				Power:     c.Power,
				Affinity:  c.Affinity,
				Cost:      c.HireCost,
				CostTotal: costTotal(c.HireCost),
			})
		}
		sort.Slice(cards, func(i, j int) bool { return cards[i].ID < cards[j].ID })

		artifacts := make([]catalogArtifact, 0, len(AllArtifacts))
		for _, a := range AllArtifacts {
			artifacts = append(artifacts, catalogArtifact{
				ID:          a.ID,
				Name:        a.Name,
				Power:       ArtifactPower,
				Requirement: a.Requirement,
			})
		}
		sort.Slice(artifacts, func(i, j int) bool { return artifacts[i].ID < artifacts[j].ID })

		resp := catalogResponse{
			Cards:     cards,
			Artifacts: artifacts,
			Config: catalogConfig{
				WinThreshold:             WinThreshold,
				WinThresholdOptions:      WinThresholdOptions,
				MaxReserve:               MaxReserve,
				CoinHoldLimit:            MaxCoins,
				TurnSeconds:              TurnSeconds,
				AbandonMissLimit:         AbandonMissLimit,
				ChannelMinSupply:         ChannelMinSupply,
				ArtifactPower:            ArtifactPower,
				MaxHarvest:               MaxHarvestCoins,
				BoardWidth:               boardWidth,
				MatchmakerTimeoutSeconds: MatchmakerTimeoutSeconds,
				ReadyTimeoutSeconds:      ReadyTimeoutSeconds,
				ReadyRefillSeconds:       ReadyRefillSeconds,
				ProvisionalGames:         ProvisionalGames,
				SupplyPerColour:          map[string]int{"2": 4, "3": 5, "4": 7},
				ArtifactsShown:           map[string]int{"2": 3, "3": 4, "4": 5},
				Elements:                 AllElements,
				WildcardElement:          EAether,
				Tiers:                    []int{1, 2, 3},
				Difficulties:             []string{string(AIEasy), string(AINormal), string(AIHard)},
				Generations:              sortedKeys(validGenerations),
				Avatars:                  sortedKeys(validAvatarIDs),
				RejectionCodes:           allRejectionCodes(),
			},
		}

		// The version is a digest of the card and artifact data only, so a
		// config tweak does not force every client to re-download the deck.
		digest := sha256.New()
		for _, c := range cards {
			fmt.Fprintf(digest, "%s|%d|%d|%s|%s;", c.ID, c.Tier, c.Power, c.Affinity, costSignature(c.Cost))
		}
		for _, a := range artifacts {
			fmt.Fprintf(digest, "%s|%s;", a.ID, costSignature(a.Requirement))
		}
		resp.Version = hex.EncodeToString(digest.Sum(nil))[:16]
		catalogVer = resp.Version

		b, err := json.Marshal(resp)
		if err != nil {
			catalogJSON = "{}"
			return
		}
		catalogJSON = string(b)
	})
	return catalogJSON, catalogVer
}

func costTotal(c Cost) int {
	n := 0
	for _, v := range c {
		n += v
	}
	return n
}

// costSignature renders a cost deterministically, so the version digest does not
// depend on Go's randomised map ordering.
func costSignature(c Cost) string {
	parts := make([]string, 0, len(c))
	for _, e := range AllElements {
		if c[e] > 0 {
			parts = append(parts, fmt.Sprintf("%s%d", e, c[e]))
		}
	}
	return strings.Join(parts, ",")
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func allRejectionCodes() []string {
	return []string{
		ErrNotYourTurn, ErrBadPayload, ErrUnknownAction,
		ErrHarvestCount, ErrHarvestDuplicate, ErrHarvestAether, ErrSupplyEmpty,
		ErrChannelAether, ErrChannelSupplyLow, ErrUnknownCard, ErrCardNotAccess,
		ErrCannotAfford, ErrReserveFull, ErrCardNotVisible, ErrBadTier,
		ErrDeckEmpty, ErrCoinLimit, ErrGameNotRunning,
	}
}

type getCatalogRequest struct {
	// KnownVersion lets a client say what it already has. When it matches, the
	// response omits the payload and the client keeps its cache.
	KnownVersion string `json:"knownVersion"`
}

// rpcGetCatalog returns the card table, the artifacts and the rule constants.
//
// Call it once at startup and cache the result against `version`. It needs no
// session state and never changes during a match.
func rpcGetCatalog(ctx context.Context, logger runtime.Logger, db *sql.DB, nk runtime.NakamaModule, payload string) (string, error) {
	body, version := buildCatalog()

	var req getCatalogRequest
	if payload != "" {
		if err := json.Unmarshal([]byte(payload), &req); err != nil {
			return "", runtime.NewError("invalid payload", 3)
		}
	}
	if req.KnownVersion != "" && req.KnownVersion == version {
		out, _ := json.Marshal(map[string]interface{}{
			"version":   version,
			"unchanged": true,
		})
		return string(out), nil
	}

	return body, nil
}
