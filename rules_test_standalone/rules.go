package rules

// rules.go â€” pure game logic: cost calculator, action validators, end-of-turn checks.
// Zero Nakama dependencies so these functions are unit-testable in isolation.

// Standalone unit-test mirror; intentionally keeps these as consts. The runtime
// package (../runtime/config.go) externalizes WinThreshold/MaxReserve/MaxCoins
// as env-driven vars per BACKEND_DOC §18.
const (
	WinThreshold    = 15
	MaxReserve      = 3
	MaxCoins        = 10
	ArtifactPower   = 3
	ChannelMinSupply = 4 // supply must have ≥4 of a color to Channel 2
)

// ---------- Cost calculation (GDD Â§3.4, Â§3.5) ----------

// AffinityBonus computes how many hired cards of each element a player has.
func AffinityBonus(hired []string, hiredDetails []CharacterCard) Cost {
	bonus := Cost{}
	for _, c := range hiredDetails {
		bonus[c.Affinity]++
	}
	return bonus
}

// CalculateActualCost returns the coins a player must pay after affinity discount (GDD Â§3.4).
// Costs never go below 0; there is no overflow into other elements.
func CalculateActualCost(hireCost Cost, affinityBonus Cost) Cost {
	result := Cost{}
	for elem, qty := range hireCost {
		discount := affinityBonus[elem]
		actual := qty - discount
		if actual < 0 {
			actual = 0
		}
		if actual > 0 {
			result[elem] = actual
		}
	}
	return result
}

// CanAfford returns true if the player's coins (including Aether wildcard) cover the cost (GDD Â§3.5).
func CanAfford(playerCoins Cost, actualCost Cost) bool {
	aetherNeeded := 0
	for elem, need := range actualCost {
		have := playerCoins[elem]
		if have < need {
			aetherNeeded += need - have
		}
	}
	return aetherNeeded <= playerCoins[EAether]
}

// CoinsToSpend computes the exact coins deducted from the player when hiring,
// applying Aether for any shortfall. Returns the deduction map or an error string.
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
			spend[elem] = have
			aetherUsed += need - have
		}
	}
	if aetherUsed > 0 {
		spend[EAether] = aetherUsed
	}
	return spend, true
}

// ---------- Supply helpers ----------

// TotalCoins returns the sum of all coins in a Cost map.
func TotalCoins(coins Cost) int {
	total := 0
	for _, v := range coins {
		total += v
	}
	return total
}

// PlayerPower computes a player's current power from hired cards + artifacts (GDD Â§7).
func PlayerPower(hired []CharacterCard, artifactCount int) int {
	power := artifactCount * ArtifactPower
	for _, c := range hired {
		power += c.Power
	}
	return power
}

// ---------- Action validation (GDD Â§3.3) ----------

type ActionError string

func (e ActionError) Error() string { return string(e) }

// ValidateHarvest checks ACTION_HARVEST (op 1): 3 different element colors from supply.
// elements must be 3 distinct non-Aether elements present in supply.
func ValidateHarvest(elements []Element, supply Cost) error {
	if len(elements) != 3 {
		// GDD: if fewer than 3 colors available, take as many as possible
		available := 0
		for _, e := range AllElements {
			if supply[e] > 0 {
				available++
			}
		}
		if len(elements) != available {
			return ActionError("harvest must take exactly 3 different elements (or all available if fewer than 3)")
		}
	}
	seen := map[Element]bool{}
	for _, e := range elements {
		if e == EAether {
			return ActionError("cannot harvest Aether")
		}
		if seen[e] {
			return ActionError("harvest elements must be different colors")
		}
		if supply[e] <= 0 {
			return ActionError("element not available in supply: " + string(e))
		}
		seen[e] = true
	}
	return nil
}

// ValidateChannel checks ACTION_CHANNEL (op 2): 2 same element, supply must have â‰¥4.
func ValidateChannel(element Element, supply Cost) error {
	if element == EAether {
		return ActionError("cannot channel Aether")
	}
	if supply[element] < ChannelMinSupply {
		return ActionError("supply must have at least 4 of " + string(element) + " to channel")
	}
	return nil
}

// ValidateHire checks ACTION_HIRE (op 3).
// cardID must exist in visibleCards or playerReserve.
// Returns the actual cost to spend (after discounts) if valid.
func ValidateHire(cardID string, fromReserve bool, playerCoins Cost, playerReserve []string, visibleCards []string, hiredCards []CharacterCard) (Cost, error) {
	card, ok := cardByID[cardID]
	if !ok {
		return nil, ActionError("unknown card: " + cardID)
	}

	// Check card is accessible
	inReserve := false
	for _, id := range playerReserve {
		if id == cardID {
			inReserve = true
			break
		}
	}
	inVisible := false
	for _, id := range visibleCards {
		if id == cardID {
			inVisible = true
			break
		}
	}
	if !inReserve && !inVisible {
		return nil, ActionError("card not accessible: " + cardID)
	}

	bonus := AffinityBonus(nil, hiredCards)
	actual := CalculateActualCost(card.HireCost, bonus)
	spend, ok := CoinsToSpend(playerCoins, actual)
	if !ok {
		return nil, ActionError("cannot afford card: " + cardID)
	}
	return spend, nil
}

// ValidateJail checks ACTION_JAIL / Recruit to Reserve (op 4).
// cardID may be a visible card ID or "" to draw blind from a tier.
// reserveCount is the player's current reserve size.
func ValidateJail(cardID string, tier int, reserveCount int, visibleCards []string) error {
	if reserveCount >= MaxReserve {
		return ActionError("reserve is full (max 3)")
	}
	if cardID != "" {
		found := false
		for _, id := range visibleCards {
			if id == cardID {
				found = true
				break
			}
		}
		if !found {
			return ActionError("card not visible: " + cardID)
		}
		return nil
	}
	// blind draw: validate tier
	if tier < 1 || tier > 3 {
		return ActionError("tier must be 1, 2, or 3")
	}
	return nil
}

// ---------- End-of-turn checks (GDD Â§3.3) ----------

// CoinsOverLimit returns the number of excess coins a player must return.
func CoinsOverLimit(coins Cost) int {
	total := TotalCoins(coins)
	if total > MaxCoins {
		return total - MaxCoins
	}
	return 0
}

// CheckArtifacts returns the ID of the first unclaimed artifact the player qualifies for,
// or "" if none. Only one artifact per turn (GDD Â§3.3).
func CheckArtifacts(hiredCards []CharacterCard, availableArtifacts []Artifact) string {
	// compute player's affinity counts
	affinity := Cost{}
	for _, c := range hiredCards {
		affinity[c.Affinity]++
	}
	for _, art := range availableArtifacts {
		qualifies := true
		for elem, need := range art.Requirement {
			if affinity[elem] < need {
				qualifies = false
				break
			}
		}
		if qualifies {
			return art.ID
		}
	}
	return ""
}

// ---------- Win detection (GDD Â§7) ----------

// DetermineWinner returns the index of the winning player given final standings.
// Tiebreaker 1: fewer hired characters. Tiebreaker 2: shared victory (returns -1).
func DetermineWinner(players []PlayerState) int {
	maxPower := -1
	for _, p := range players {
		pw := PlayerPower(p.HiredCards, len(p.Artifacts))
		if pw > maxPower {
			maxPower = pw
		}
	}

	// collect all tied players
	var tied []int
	for i, p := range players {
		if PlayerPower(p.HiredCards, len(p.Artifacts)) == maxPower {
			tied = append(tied, i)
		}
	}
	if len(tied) == 1 {
		return tied[0]
	}

	// Tiebreaker 1: fewest hired characters
	minHired := -1
	for _, idx := range tied {
		n := len(players[idx].HiredCards)
		if minHired == -1 || n < minHired {
			minHired = n
		}
	}
	var stillTied []int
	for _, idx := range tied {
		if len(players[idx].HiredCards) == minHired {
			stillTied = append(stillTied, idx)
		}
	}
	if len(stillTied) == 1 {
		return stillTied[0]
	}

	// Tiebreaker 2: shared victory
	return -1
}

