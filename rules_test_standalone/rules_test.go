package rules

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
	// Card costs Light:3, player has 2 Light affinity â†’ pays Light:1
	cost := Cost{ELight: 3, ENature: 2}
	bonus := Cost{ELight: 2}
	got := CalculateActualCost(cost, bonus)
	want := Cost{ELight: 1, ENature: 2}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v want %v", got, want)
	}
}

func TestCalculateActualCost_FullDiscountDropsToZero(t *testing.T) {
	// Affinity covers entire cost component â†’ that element disappears from result
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
	// All costs covered â†’ empty result (free hire)
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
	// Player has 1 Light and 2 Aether; cost is Light:3 â†’ needs 2 Aether
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
	// Free card (cost already reduced to zero) â€” always affordable
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
	// Player has 1 Water and 2 Aether; needs Water:3 â†’ spends Water:1, Aether:2
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
	err := ValidateHarvest([]Element{ELight, EWater, ENature}, supply)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestValidateHarvest_DuplicateElement(t *testing.T) {
	supply := Cost{ELight: 4, EWater: 3}
	err := ValidateHarvest([]Element{ELight, ELight, EWater}, supply)
	if err == nil {
		t.Error("expected error for duplicate element")
	}
}

func TestValidateHarvest_AetherNotAllowed(t *testing.T) {
	supply := Cost{ELight: 2, EWater: 2, EAether: 5}
	err := ValidateHarvest([]Element{ELight, EWater, EAether}, supply)
	if err == nil {
		t.Error("expected error for Aether in harvest")
	}
}

func TestValidateHarvest_ElementNotInSupply(t *testing.T) {
	supply := Cost{ELight: 0, EWater: 3, ENature: 2, EFire: 1, EShadow: 2}
	err := ValidateHarvest([]Element{ELight, EWater, ENature}, supply)
	if err == nil {
		t.Error("expected error for empty supply element")
	}
}

// ---------- ValidateChannel ----------

func TestValidateChannel_Valid(t *testing.T) {
	supply := Cost{EFire: 5}
	err := ValidateChannel(EFire, supply)
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestValidateChannel_ExactlyFour(t *testing.T) {
	supply := Cost{EWater: 4}
	err := ValidateChannel(EWater, supply)
	if err != nil {
		t.Errorf("supply of exactly 4 should allow channel: %v", err)
	}
}

func TestValidateChannel_BelowFour(t *testing.T) {
	supply := Cost{EShadow: 3}
	err := ValidateChannel(EShadow, supply)
	if err == nil {
		t.Error("expected error for supply < 4")
	}
}

func TestValidateChannel_AetherNotAllowed(t *testing.T) {
	supply := Cost{EAether: 5}
	err := ValidateChannel(EAether, supply)
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
	// A-01 requires Light:4, Nature:4
	hired := make([]CharacterCard, 0)
	for i := 0; i < 4; i++ {
		hired = append(hired, CharacterCard{Affinity: ELight})
		hired = append(hired, CharacterCard{Affinity: ENature})
	}
	arts := []Artifact{AllArtifacts[0]} // A-01
	got := CheckArtifacts(hired, arts)
	if got != "A-01" {
		t.Errorf("expected A-01, got %q", got)
	}
}

func TestCheckArtifacts_NotQualified(t *testing.T) {
	hired := []CharacterCard{
		{Affinity: ELight},
		{Affinity: ELight},
	}
	arts := []Artifact{AllArtifacts[0]} // A-01 needs 4+4
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
		{HiredCards: []CharacterCard{{Power: 5}, {Power: 5}}, Artifacts: []string{"A-01"}}, // 10+3=13
		{HiredCards: []CharacterCard{{Power: 5}, {Power: 5}, {Power: 5}}, Artifacts: []string{"A-01", "A-02"}}, // 15+6=21
	}
	if got := DetermineWinner(players); got != 1 {
		t.Errorf("expected player 1 to win, got %d", got)
	}
}

func TestDetermineWinner_TiebreakerFewerCards(t *testing.T) {
	// Equal power, player 0 has fewer cards â†’ wins
	players := []PlayerState{
		{HiredCards: []CharacterCard{{Power: 3}, {Power: 3}}}, // 6 power, 2 cards
		{HiredCards: []CharacterCard{{Power: 2}, {Power: 2}, {Power: 2}}}, // 6 power, 3 cards
	}
	if got := DetermineWinner(players); got != 0 {
		t.Errorf("expected player 0 (fewer cards), got %d", got)
	}
}

func TestDetermineWinner_TiebreakerShared(t *testing.T) {
	// Equal power, equal card count â†’ shared (-1)
	players := []PlayerState{
		{HiredCards: []CharacterCard{{Power: 3}, {Power: 3}}},
		{HiredCards: []CharacterCard{{Power: 3}, {Power: 3}}},
	}
	if got := DetermineWinner(players); got != -1 {
		t.Errorf("expected shared victory (-1), got %d", got)
	}
}

// ---------- CoinsOverLimit ----------

func TestCoinsOverLimit_Under(t *testing.T) {
	coins := Cost{ELight: 3, EWater: 3, ENature: 3}
	if got := CoinsOverLimit(coins); got != 0 {
		t.Errorf("expected 0, got %d", got)
	}
}

func TestCoinsOverLimit_AtLimit(t *testing.T) {
	coins := Cost{ELight: 4, EWater: 3, ENature: 3}
	if got := CoinsOverLimit(coins); got != 0 {
		t.Errorf("expected 0 at exactly 10, got %d", got)
	}
}

func TestCoinsOverLimit_Over(t *testing.T) {
	coins := Cost{ELight: 4, EWater: 4, ENature: 4}
	if got := CoinsOverLimit(coins); got != 2 {
		t.Errorf("expected 2, got %d", got)
	}
}

