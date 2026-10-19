package main

import (
	"reflect"
	"testing"
)

// ---------- CalculateActualCost ----------

func TestCalculateActualCost_NoDiscount(t *testing.T) {
	cost := Cost{ELight: 2, EWater: 1}
	bonus := Cost{}
	got := CalculateActualCost(cost, bonus)
	want := Cost{ELight: 2, EWater: 1}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestCalculateActualCost_PartialDiscount(t *testing.T) {
	// Card costs Light:3, player has 2 Light affinity → pays Light:1
	cost := Cost{ELight: 3, ENature: 2}
	bonus := Cost{ELight: 2}
	got := CalculateActualCost(cost, bonus)
	want := Cost{ELight: 1, ENature: 2}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestCalculateActualCost_FullDiscountDropsToZero(t *testing.T) {
	// Affinity covers entire cost component → that element disappears from result
	cost := Cost{ELight: 3, EFire: 2}
	bonus := Cost{ELight: 5} // over-discount: no overflow into EFire
	got := CalculateActualCost(cost, bonus)
	want := Cost{EFire: 2} // ELight drops to 0 (removed), EFire unchanged
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestCalculateActualCost_NoOverflowBetweenElements(t *testing.T) {
	// Surplus Light discount never bleeds into Water cost
	cost := Cost{ELight: 1, EWater: 3}
	bonus := Cost{ELight: 10}
	got := CalculateActualCost(cost, bonus)
	want := Cost{EWater: 3}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("overflow bleed: got %v want %v", got, want)
	}
}

func TestCalculateActualCost_FreeCost(t *testing.T) {
	// All costs covered → empty result (free hire)
	cost := Cost{ENature: 2, EFire: 1}
	bonus := Cost{ENature: 3, EFire: 2}
	got := CalculateActualCost(cost, bonus)
	if len(got) != 0 {
		t.Errorf("expected free cost, got %v", got)
	}
}

// ---------- CanAfford ----------

func TestCanAfford_ExactCoins(t *testing.T) {
	coins := Cost{ELight: 2, EWater: 1}
	cost := Cost{ELight: 2, EWater: 1}
	if !CanAfford(coins, cost) {
		t.Error("expected can afford exact coins")
	}
}

func TestCanAfford_WithAether(t *testing.T) {
	// Player has 1 Light and 2 Aether; cost is Light:3 → needs 2 Aether
	coins := Cost{ELight: 1, EAether: 2}
	cost := Cost{ELight: 3}
	if !CanAfford(coins, cost) {
		t.Error("expected can afford via Aether substitution")
	}
}

func TestCanAfford_NotEnoughAether(t *testing.T) {
	coins := Cost{ELight: 1, EAether: 1}
	cost := Cost{ELight: 3} // needs 2 Aether but only has 1
	if CanAfford(coins, cost) {
		t.Error("expected cannot afford")
	}
}

func TestCanAfford_Empty(t *testing.T) {
	// Free card (cost already reduced to zero) — always affordable
	if !CanAfford(Cost{}, Cost{}) {
		t.Error("empty cost should always be affordable")
	}
}

// ---------- CoinsToSpend ----------

func TestCoinsToSpend_NoAether(t *testing.T) {
	coins := Cost{EFire: 3, ELight: 2}
	cost := Cost{EFire: 2, ELight: 1}
	spend, ok := CoinsToSpend(coins, cost)
	if !ok {
		t.Fatal("expected ok")
	}
	if spend[EFire] != 2 || spend[ELight] != 1 {
		t.Errorf("unexpected spend: %v", spend)
	}
}

func TestCoinsToSpend_AetherFillsShortfall(t *testing.T) {
	// Player has 1 Water and 2 Aether; needs Water:3 → spends Water:1, Aether:2
	coins := Cost{EWater: 1, EAether: 2}
	cost := Cost{EWater: 3}
	spend, ok := CoinsToSpend(coins, cost)
	if !ok {
		t.Fatal("expected ok")
	}
	if spend[EWater] != 1 {
		t.Errorf("expected EWater spend=1 got %d", spend[EWater])
	}
	if spend[EAether] != 2 {
		t.Errorf("expected EAether spend=2 got %d", spend[EAether])
	}
}

func TestCoinsToSpend_CannotAfford(t *testing.T) {
	coins := Cost{EFire: 1}
	cost := Cost{EFire: 5}
	_, ok := CoinsToSpend(coins, cost)
	if ok {
		t.Error("expected cannot afford")
	}
}

// ---------- ValidateHarvest ----------

func TestValidateHarvest_Valid3Different(t *testing.T) {
	supply := Cost{ELight: 2, EWater: 3, ENature: 1, EFire: 4, EShadow: 2}
	err := ValidateHarvest([]Element{ELight, EWater, ENature}, supply, Cost{})
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestValidateHarvest_DuplicateElement(t *testing.T) {
	supply := Cost{ELight: 4, EWater: 3}
	err := ValidateHarvest([]Element{ELight, ELight, EWater}, supply, Cost{})
	if err == nil {
		t.Error("expected error for duplicate element")
	}
}

func TestValidateHarvest_AetherNotAllowed(t *testing.T) {
	supply := Cost{ELight: 2, EWater: 2, EAether: 5}
	err := ValidateHarvest([]Element{ELight, EWater, EAether}, supply, Cost{})
	if err == nil {
		t.Error("expected error for Aether in harvest")
	}
}

func TestValidateHarvest_ElementNotInSupply(t *testing.T) {
	supply := Cost{ELight: 0, EWater: 3, ENature: 2, EFire: 1, EShadow: 2}
	err := ValidateHarvest([]Element{ELight, EWater, ENature}, supply, Cost{})
	if err == nil {
		t.Error("expected error for empty supply element")
	}
}

// ---------- ValidateChannel ----------

func TestValidateChannel_Valid(t *testing.T) {
	supply := Cost{EFire: 5}
	err := ValidateChannel(EFire, supply, Cost{})
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestValidateChannel_ExactlyFour(t *testing.T) {
	supply := Cost{EWater: 4}
	err := ValidateChannel(EWater, supply, Cost{})
	if err != nil {
		t.Errorf("supply of exactly 4 should allow channel: %v", err)
	}
}

func TestValidateChannel_BelowFour(t *testing.T) {
	supply := Cost{EShadow: 3}
	err := ValidateChannel(EShadow, supply, Cost{})
	if err == nil {
		t.Error("expected error for supply < 4")
	}
}

func TestValidateChannel_AetherNotAllowed(t *testing.T) {
	supply := Cost{EAether: 5}
	err := ValidateChannel(EAether, supply, Cost{})
	if err == nil {
		t.Error("expected error for channeling Aether")
	}
}

// ---------- ValidateJail ----------

func TestValidateJail_ValidVisible(t *testing.T) {
	visible := []string{"H-01", "H-02", "M-03"}
	err := ValidateJail("H-01", 0, 0, visible)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestValidateJail_ReserveFull(t *testing.T) {
	visible := []string{"H-01"}
	err := ValidateJail("H-01", 0, MaxReserve, visible)
	if err == nil {
		t.Error("expected error when reserve full")
	}
}

func TestValidateJail_CardNotVisible(t *testing.T) {
	visible := []string{"H-02", "M-03"}
	err := ValidateJail("H-01", 0, 0, visible)
	if err == nil {
		t.Error("expected error for card not visible")
	}
}

func TestValidateJail_BlindDraw_ValidTier(t *testing.T) {
	err := ValidateJail("", 2, 1, nil)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestValidateJail_BlindDraw_BadTier(t *testing.T) {
	err := ValidateJail("", 5, 0, nil)
	if err == nil {
		t.Error("expected error for invalid tier")
	}
}

// ---------- CheckArtifacts ----------

func TestCheckArtifacts_Qualifies(t *testing.T) {
	// A-01 requires Fire:4, Nature:4 (Splendor-exact, corrected 2026-10-15)
	hired := make([]CharacterCard, 0)
	for i := 0; i < 4; i++ {
		hired = append(hired, CharacterCard{Affinity: EFire})
		hired = append(hired, CharacterCard{Affinity: ENature})
	}
	arts := []Artifact{AllArtifacts[0]} // A-01
	got := CheckArtifacts(hired, arts)
	if got != "A-01" {
		t.Errorf("expected A-01, got %q", got)
	}
}

// The pre-correction requirement (Light:4, Nature:4) must no longer satisfy
// A-01, and one card short of the real one must not either.
func TestCheckArtifacts_OldRequirementNoLongerQualifies(t *testing.T) {
	arts := []Artifact{AllArtifacts[0]} // A-01
	old := make([]CharacterCard, 0)
	for i := 0; i < 4; i++ {
		old = append(old, CharacterCard{Affinity: ELight}, CharacterCard{Affinity: ENature})
	}
	if got := CheckArtifacts(old, arts); got != "" {
		t.Errorf("Light 4 + Nature 4 claimed %q; A-01 now needs Fire 4 + Nature 4", got)
	}

	short := make([]CharacterCard, 0)
	for i := 0; i < 4; i++ {
		short = append(short, CharacterCard{Affinity: ENature})
	}
	for i := 0; i < 3; i++ {
		short = append(short, CharacterCard{Affinity: EFire})
	}
	if got := CheckArtifacts(short, arts); got != "" {
		t.Errorf("Fire 3 + Nature 4 claimed %q; one Fire card short", got)
	}
}

func TestCheckArtifacts_NotQualified(t *testing.T) {
	hired := []CharacterCard{
		{Affinity: ELight},
		{Affinity: ELight},
	}
	arts := []Artifact{AllArtifacts[0]} // A-01 needs Fire 4 + Nature 4
	got := CheckArtifacts(hired, arts)
	if got != "" {
		t.Errorf("should not qualify, got %q", got)
	}
}

func TestCheckArtifacts_EmptyArtifacts(t *testing.T) {
	hired := []CharacterCard{{Affinity: ELight}}
	got := CheckArtifacts(hired, nil)
	if got != "" {
		t.Errorf("no artifacts available, expected empty, got %q", got)
	}
}

// ---------- DetermineWinner ----------

func TestDetermineWinner_Clear(t *testing.T) {
	players := []PlayerState{
		{HiredCards: []CharacterCard{{Power: 5}, {Power: 5}}, Artifacts: []string{"A-01"}},                     // 10+3=13
		{HiredCards: []CharacterCard{{Power: 5}, {Power: 5}, {Power: 5}}, Artifacts: []string{"A-01", "A-02"}}, // 15+6=21
	}
	if got := DetermineWinner(players); got != 1 {
		t.Errorf("expected player 1 to win, got %d", got)
	}
}

func TestDetermineWinner_TiebreakerFewerCards(t *testing.T) {
	// Equal power, player 0 has fewer cards → wins
	players := []PlayerState{
		{HiredCards: []CharacterCard{{Power: 3}, {Power: 3}}},             // 6 power, 2 cards
		{HiredCards: []CharacterCard{{Power: 2}, {Power: 2}, {Power: 2}}}, // 6 power, 3 cards
	}
	if got := DetermineWinner(players); got != 0 {
		t.Errorf("expected player 0 (fewer cards), got %d", got)
	}
}

func TestDetermineWinner_TiebreakerShared(t *testing.T) {
	// Equal power, equal card count → shared (-1)
	players := []PlayerState{
		{HiredCards: []CharacterCard{{Power: 3}, {Power: 3}}},
		{HiredCards: []CharacterCard{{Power: 3}, {Power: 3}}},
	}
	if got := DetermineWinner(players); got != -1 {
		t.Errorf("expected shared victory (-1), got %d", got)
	}
}

// ---------- Coin hold limit (house rule) ----------
//
// Veynoria deliberately departs from Splendor here: a take that would put the
// player above 10 coins is rejected outright instead of being followed by a
// return step.

func ruleCode(err error) string {
	if re, ok := err.(*RuleError); ok {
		return re.Code
	}
	return ""
}

func TestCoinRoom(t *testing.T) {
	cases := []struct {
		coins Cost
		want  int
	}{
		{Cost{}, 10},
		{Cost{ELight: 3, EWater: 3, ENature: 3}, 1},
		{Cost{ELight: 4, EWater: 3, ENature: 3}, 0},
		{Cost{ELight: 4, EWater: 3, EAether: 3}, 0}, // Aether counts towards the limit
		{Cost{ELight: 6, EWater: 6}, 0},             // never negative
	}
	for _, c := range cases {
		if got := CoinRoom(c.coins); got != c.want {
			t.Errorf("CoinRoom(%v) = %d, want %d", c.coins, got, c.want)
		}
	}
}

func TestValidateHarvest_CoinLimit(t *testing.T) {
	supply := Cost{ELight: 4, EWater: 4, ENature: 4, EFire: 4, EShadow: 4}
	three := []Element{ELight, EWater, ENature}
	two := []Element{ELight, EWater}
	one := []Element{ELight}

	at8 := Cost{EFire: 4, EShadow: 4}
	at9 := Cost{EFire: 4, EShadow: 4, EAether: 1} // Aether counts
	at10 := Cost{EFire: 4, EShadow: 4, EAether: 2}

	cases := []struct {
		name  string
		held  Cost
		take  []Element
		legal bool
	}{
		{"8 coins, take 3", at8, three, false},
		{"8 coins, take 2", at8, two, true},
		{"8 coins, take 1", at8, one, true},
		{"9 coins, take 3", at9, three, false},
		{"9 coins, take 2", at9, two, false},
		{"9 coins, take 1", at9, one, true},
		{"10 coins, take 3", at10, three, false},
		{"10 coins, take 2", at10, two, false},
		{"10 coins, take 1", at10, one, false},
		{"7 coins, take 3", Cost{EFire: 7}, three, true},
	}
	for _, c := range cases {
		err := ValidateHarvest(c.take, supply, c.held)
		switch {
		case c.legal && err != nil:
			t.Errorf("%s: rejected (%v), want legal", c.name, err)
		case !c.legal && ruleCode(err) != ErrCoinLimit:
			t.Errorf("%s: got %v, want %s", c.name, err, ErrCoinLimit)
		}
	}
}

// A malformed take is reported as malformed, not as a coin-limit problem.
func TestValidateHarvest_ShapeCheckedBeforeLimit(t *testing.T) {
	supply := Cost{ELight: 4, EWater: 4}
	err := ValidateHarvest([]Element{ELight, ELight}, supply, Cost{EFire: 10})
	if ruleCode(err) != ErrHarvestDuplicate {
		t.Errorf("got %v, want %s", err, ErrHarvestDuplicate)
	}
}

func TestValidateChannel_CoinLimit(t *testing.T) {
	supply := Cost{EFire: 7}
	if err := ValidateChannel(EFire, supply, Cost{EWater: 9}); ruleCode(err) != ErrCoinLimit {
		t.Errorf("channel at 9 coins: got %v, want %s", err, ErrCoinLimit)
	}
	if err := ValidateChannel(EFire, supply, Cost{EWater: 10}); ruleCode(err) != ErrCoinLimit {
		t.Errorf("channel at 10 coins: got %v, want %s", err, ErrCoinLimit)
	}
	if err := ValidateChannel(EFire, supply, Cost{EWater: 8}); err != nil {
		t.Errorf("channel at 8 coins lands exactly on 10 and must be legal: %v", err)
	}
}

func TestReserveGrantsAether(t *testing.T) {
	at9 := Cost{ELight: 5, EWater: 4}
	at10 := Cost{ELight: 5, EWater: 4, EAether: 1}
	if !ReserveGrantsAether(at9, 5) {
		t.Error("reserving at 9 coins with Aether in supply must grant one")
	}
	if ReserveGrantsAether(at10, 5) {
		t.Error("reserving at 10 coins must grant no Aether")
	}
	if ReserveGrantsAether(at9, 0) {
		t.Error("reserving with no Aether left in the supply must grant none")
	}
}
