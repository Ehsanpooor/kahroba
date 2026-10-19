package main

import (
	"sort"
	"strconv"
)

// rules.go — pure game logic: cost calculator, action validators, end-of-turn
// checks, standings. Zero Nakama dependencies, so every rule here is unit
// testable in isolation and the same functions can be ported to the Dart client
// for the offline AI game.
//
// WinThresholdOptions are the Power targets an unrated game may choose.
var WinThresholdOptions = []int{15, 18, 21, 25, 30}

// validWinThreshold reports whether v is one of WinThresholdOptions.
func validWinThreshold(v int) bool {
	for _, o := range WinThresholdOptions {
		if o == v {
			return true
		}
	}
	return false
}

// WinThreshold, MaxReserve and MaxCoins live in config.go as env-driven vars
// (BACKEND_DOC §18). ArtifactPower and ChannelMinSupply stay const — they are
// GDD-fixed rules, not tunable knobs.
const (
	ArtifactPower    = 3
	ChannelMinSupply = 4 // supply must hold >= 4 of a colour before Channel 2
	MaxHarvestCoins  = 3
)

// ---------- Errors ----------

// RuleError is a rejection the client can act on. Code is stable and safe to
// switch on; Message is for logs and debug UI, never for end-user display —
// the client owns the player-facing wording per code.
type RuleError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (e *RuleError) Error() string { return e.Message }

func ruleErr(code, msg string) *RuleError { return &RuleError{Code: code, Message: msg} }

// Rejection codes (wire contract — see API_DOC §6.2, op 103).
const (
	ErrNotYourTurn      = "not_your_turn"
	ErrBadPayload       = "bad_payload"
	ErrUnknownAction    = "unknown_action"
	ErrHarvestCount     = "harvest_count"
	ErrHarvestDuplicate = "harvest_duplicate"
	ErrHarvestAether    = "harvest_aether"
	ErrSupplyEmpty      = "supply_empty"
	ErrChannelAether    = "channel_aether"
	ErrChannelSupplyLow = "channel_supply_low"
	ErrUnknownCard      = "unknown_card"
	ErrCardNotAccess    = "card_not_accessible"
	ErrCannotAfford     = "cannot_afford"
	ErrReserveFull      = "reserve_full"
	ErrCardNotVisible   = "card_not_visible"
	ErrBadTier          = "bad_tier"
	ErrDeckEmpty        = "deck_empty"
	ErrCoinLimit        = "coin_limit"
	ErrGameNotRunning   = "game_not_running"
)

// Removed in the coin-limit house rule (2026-10): must_return_coins,
// return_count_mismatch and return_coins_not_held. The server never sends them
// any more; see API_DOC §6.3.

// ---------- Cost calculation (GDD v2 §5.5, §5.6) ----------

// AffinityBonus counts how many hired cards of each element a player has.
// Each hired card grants a permanent 1-coin discount in its own element.
func AffinityBonus(hired []CharacterCard) Cost {
	bonus := Cost{}
	for _, c := range hired {
		bonus[c.Affinity]++
	}
	return bonus
}

// CalculateActualCost returns the coins payable after the affinity discount.
// A component floors at 0 and surplus never overflows into another element.
func CalculateActualCost(hireCost Cost, affinityBonus Cost) Cost {
	result := Cost{}
	for elem, qty := range hireCost {
		actual := qty - affinityBonus[elem]
		if actual > 0 {
			result[elem] = actual
		}
	}
	return result
}

// CanAfford reports whether the player's coins, with Aether covering any
// shortfall one-for-one, meet the discounted cost.
func CanAfford(playerCoins Cost, actualCost Cost) bool {
	aetherNeeded := 0
	for elem, need := range actualCost {
		if have := playerCoins[elem]; have < need {
			aetherNeeded += need - have
		}
	}
	return aetherNeeded <= playerCoins[EAether]
}

// CoinsToSpend computes the exact deduction for a hire, spending the player's
// own colour first and Aether only for the remainder. The second return value
// is false when the player cannot afford the card.
func CoinsToSpend(playerCoins Cost, actualCost Cost) (Cost, bool) {
	if !CanAfford(playerCoins, actualCost) {
		return nil, false
	}
	spend := Cost{}
	aetherUsed := 0
	for elem, need := range actualCost {
		have := playerCoins[elem]
		if have >= need {
			spend[elem] = need
		} else {
			if have > 0 {
				spend[elem] = have
			}
			aetherUsed += need - have
		}
	}
	if aetherUsed > 0 {
		spend[EAether] = aetherUsed
	}
	return spend, true
}

// ---------- Supply helpers ----------

// TotalCoins sums every denomination in a Cost map, Aether included.
func TotalCoins(coins Cost) int {
	total := 0
	for _, v := range coins {
		total += v
	}
	return total
}

// PlayerPower is hired-card Power plus 3 per claimed artifact (GDD v2 §9).
func PlayerPower(hired []CharacterCard, artifactCount int) int {
	power := artifactCount * ArtifactPower
	for _, c := range hired {
		power += c.Power
	}
	return power
}

// ---------- Coin hold limit (house rule, GDD v2 §5.4) ----------
//
// DELIBERATE DEPARTURE FROM SPLENDOR. Official Splendor lets a player take coins
// past 10 and then hand the excess back at the end of the turn. Veynoria does
// not: a player may never hold more than MaxCoins (10, Aether included), so a
// Harvest or Channel that would cross the limit is rejected outright with
// coin_limit, and there is no return step. Taking 1 or 2 coins to land exactly
// on the limit stays legal. Reserving stays legal at the limit but then grants
// no Aether (see ReserveGrantsAether).

// CoinRoom is how many more coins the player may take before reaching the
// hold limit. Never negative.
func CoinRoom(coins Cost) int {
	if room := MaxCoins - TotalCoins(coins); room > 0 {
		return room
	}
	return 0
}

// checkCoinLimit rejects a take of `taking` coins that would push the player
// above the hold limit.
func checkCoinLimit(playerCoins Cost, taking int) error {
	if taking > CoinRoom(playerCoins) {
		return ruleErr(ErrCoinLimit, "cannot hold more than "+strconv.Itoa(MaxCoins)+" coins")
	}
	return nil
}

// ReserveGrantsAether reports whether a reservation hands the player an Aether
// coin: only while the supply still has one AND the player has room for it.
// At the hold limit the reservation itself is still legal; it simply comes
// without the Aether, exactly as when the Aether pile is empty.
func ReserveGrantsAether(playerCoins Cost, aetherSupply int) bool {
	return aetherSupply > 0 && CoinRoom(playerCoins) > 0
}

// ---------- Action validation (GDD v2 §5.3) ----------

// ValidateHarvest checks ACTION_HARVEST (op 1): up to 3 coins of distinct
// non-Aether colours, never taking the player above the hold limit. Splendor's
// FAQ allows taking fewer than 3 voluntarily, which players need in order to
// fill up to exactly 10, so 1 and 2 are legal.
func ValidateHarvest(elements []Element, supply Cost, playerCoins Cost) error {
	if len(elements) == 0 || len(elements) > MaxHarvestCoins {
		return ruleErr(ErrHarvestCount, "harvest takes 1 to 3 coins of different elements")
	}
	seen := map[Element]bool{}
	for _, e := range elements {
		if e == EAether {
			return ruleErr(ErrHarvestAether, "cannot harvest Aether")
		}
		if !isElement(e) {
			return ruleErr(ErrHarvestCount, "unknown element: "+string(e))
		}
		if seen[e] {
			return ruleErr(ErrHarvestDuplicate, "harvest elements must be different colours")
		}
		if supply[e] <= 0 {
			return ruleErr(ErrSupplyEmpty, "element not available in supply: "+string(e))
		}
		seen[e] = true
	}
	return checkCoinLimit(playerCoins, len(elements))
}

// ValidateChannel checks ACTION_CHANNEL (op 2): 2 of one colour, legal only
// while the supply still holds at least 4 of it and the player has room for
// both coins under the hold limit.
func ValidateChannel(element Element, supply Cost, playerCoins Cost) error {
	if element == EAether {
		return ruleErr(ErrChannelAether, "cannot channel Aether")
	}
	if !isElement(element) {
		return ruleErr(ErrChannelSupplyLow, "unknown element: "+string(element))
	}
	if supply[element] < ChannelMinSupply {
		return ruleErr(ErrChannelSupplyLow, "supply must hold at least 4 of "+string(element)+" to channel")
	}
	return checkCoinLimit(playerCoins, 2)
}

// ValidateHire checks ACTION_HIRE (op 3) and returns the coins to deduct.
// The card must be face-up on the board or in the player's own reserve; the
// client's claimed source and Aether count are ignored, the server derives both.
func ValidateHire(cardID string, playerCoins Cost, playerReserve []string, visibleCards []string, hiredCards []CharacterCard) (Cost, error) {
	card, ok := cardByID[cardID]
	if !ok {
		return nil, ruleErr(ErrUnknownCard, "unknown card: "+cardID)
	}
	if !containsString(playerReserve, cardID) && !containsString(visibleCards, cardID) {
		return nil, ruleErr(ErrCardNotAccess, "card not accessible: "+cardID)
	}

	actual := CalculateActualCost(card.HireCost, AffinityBonus(hiredCards))
	spend, ok := CoinsToSpend(playerCoins, actual)
	if !ok {
		return nil, ruleErr(ErrCannotAfford, "cannot afford card: "+cardID)
	}
	return spend, nil
}

// ValidateJail checks ACTION_JAIL / reserve (op 4). An empty cardID means a
// blind draw from the top of tier.
func ValidateJail(cardID string, tier int, reserveCount int, visibleCards []string) error {
	if reserveCount >= MaxReserve {
		return ruleErr(ErrReserveFull, "reserve is full")
	}
	if cardID != "" {
		if !containsString(visibleCards, cardID) {
			return ruleErr(ErrCardNotVisible, "card not visible: "+cardID)
		}
		return nil
	}
	if tier < 1 || tier > 3 {
		return ruleErr(ErrBadTier, "tier must be 1, 2 or 3")
	}
	return nil
}

// ---------- End-of-turn checks (GDD v2 §5.4) ----------

// CheckArtifacts returns the ID of the first unclaimed artifact the player's
// affinities satisfy, or "" for none. At most one artifact per turn (GDD §5.4).
// Artifacts are scanned in the order they were revealed, which is the shuffled
// order fixed at setup, so the choice is deterministic for a given match.
func CheckArtifacts(hiredCards []CharacterCard, availableArtifacts []Artifact) string {
	return CheckArtifactsPreferring(hiredCards, availableArtifacts, "")
}

// CheckArtifactsPreferring is CheckArtifacts with the player's choice: when
// `preferred` is one of the artifacts the player qualifies for, it is the
// one claimed (Splendor lets the player choose among several nobles);
// otherwise the first qualifying one is, as before. Still one per turn.
func CheckArtifactsPreferring(hiredCards []CharacterCard, availableArtifacts []Artifact, preferred string) string {
	first := ""
	for _, id := range qualifyingArtifacts(hiredCards, availableArtifacts) {
		if id == preferred {
			return id
		}
		if first == "" {
			first = id
		}
	}
	return first
}

// qualifyingArtifacts lists, in table order, every artifact the player's
// hired cards meet.
func qualifyingArtifacts(hiredCards []CharacterCard, availableArtifacts []Artifact) []string {
	var out []string
	affinity := AffinityBonus(hiredCards)
	for _, art := range availableArtifacts {
		qualifies := true
		for elem, need := range art.Requirement {
			if affinity[elem] < need {
				qualifies = false
				break
			}
		}
		if qualifies {
			out = append(out, art.ID)
		}
	}
	return out
}

// ---------- Standings & win detection (GDD v2 §9) ----------

// Standing is one row of the final table, ranked.
type Standing struct {
	Index       int    `json:"index"`
	UserID      string `json:"userId"`
	DisplayName string `json:"displayName"`
	Power       int    `json:"power"`
	HiredCount  int    `json:"hiredCount"`
	Conceded    bool   `json:"conceded"`
	Rank        int    `json:"rank"` // 1-based; equal ranks share a number
}

// ComputeStandings ranks the table and names the winner.
//
// A player who conceded or was auto-lost for abandonment can never place above
// a player still in the game, however much Power they hold — that is the whole
// point of the "concede is a rated loss" rule. Among the remaining players the
// order is most Power, then fewest hired characters (the more efficient engine),
// and a tie on both is a shared victory.
//
// The second return value is the winning seat index, or -1 for a shared
// victory, which also covers the degenerate case where everyone conceded.
func ComputeStandings(players []PlayerState) ([]Standing, int) {
	rows := make([]Standing, len(players))
	for i, p := range players {
		rows[i] = Standing{
			Index:       i,
			UserID:      p.UserID,
			DisplayName: p.DisplayName,
			Power:       PlayerPower(p.HiredCards, len(p.Artifacts)),
			HiredCount:  len(p.HiredCards),
			Conceded:    p.Conceded,
		}
	}

	better := func(a, b Standing) bool {
		if a.Conceded != b.Conceded {
			return !a.Conceded // still in the game always outranks a quitter
		}
		if a.Power != b.Power {
			return a.Power > b.Power
		}
		if a.HiredCount != b.HiredCount {
			return a.HiredCount < b.HiredCount
		}
		return a.Index < b.Index // stable, never a ranking criterion on its own
	}
	sort.SliceStable(rows, func(i, j int) bool { return better(rows[i], rows[j]) })

	tiedWith := func(a, b Standing) bool {
		return a.Conceded == b.Conceded && a.Power == b.Power && a.HiredCount == b.HiredCount
	}
	for i := range rows {
		if i > 0 && tiedWith(rows[i], rows[i-1]) {
			rows[i].Rank = rows[i-1].Rank
		} else {
			rows[i].Rank = i + 1
		}
	}

	if len(rows) == 0 || rows[0].Conceded {
		return rows, -1 // nobody left standing: no winner, no rating gain
	}
	if len(rows) > 1 && tiedWith(rows[0], rows[1]) {
		return rows, -1 // shared victory
	}
	return rows, rows[0].Index
}

// DetermineWinner returns the winning seat index, or -1 for a shared victory.
func DetermineWinner(players []PlayerState) int {
	_, winner := ComputeStandings(players)
	return winner
}

// ---------- small helpers ----------

func isElement(e Element) bool {
	for _, a := range AllElements {
		if a == e {
			return true
		}
	}
	return false
}

func containsString(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
}
