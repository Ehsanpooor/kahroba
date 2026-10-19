package main

import (
	"context"
	"testing"
)

// deck_test.go — structural invariants of the 90-card deck and the 10 artifacts.
//
// The card table is a port of the Splendor deck, and a hand edit that breaks its
// shape changes the balance of the whole game without breaking anything visibly.
// These assertions are the guard rail: they encode the shape rather than the
// individual numbers, so they catch a bad edit without duplicating the table.

func testContext() context.Context { return context.Background() }

func TestDeck_CountsPerTierAndRace(t *testing.T) {
	if len(AllCards) != 90 {
		t.Fatalf("deck holds %d cards, want 90", len(AllCards))
	}

	want := map[int]int{1: 8, 2: 6, 3: 4}
	counts := map[Element]map[int]int{}
	for _, c := range AllCards {
		if counts[c.Affinity] == nil {
			counts[c.Affinity] = map[int]int{}
		}
		counts[c.Affinity][c.Tier]++
	}

	if len(counts) != 5 {
		t.Fatalf("deck covers %d affinities, want 5", len(counts))
	}
	for _, elem := range AllElements {
		for tier, n := range want {
			if got := counts[elem][tier]; got != n {
				t.Errorf("%s tier %d holds %d cards, want %d", elem, tier, got, n)
			}
		}
	}
}

func TestDeck_UniqueIDsAndLookup(t *testing.T) {
	seen := map[string]bool{}
	for _, c := range AllCards {
		if seen[c.ID] {
			t.Errorf("duplicate card ID %s", c.ID)
		}
		seen[c.ID] = true

		if cardByID[c.ID] == nil {
			t.Errorf("%s is missing from the lookup map", c.ID)
		}
		if c.Name == "" {
			t.Errorf("%s has no name", c.ID)
		}
		if c.Tier < 1 || c.Tier > 3 {
			t.Errorf("%s has tier %d", c.ID, c.Tier)
		}
		if c.Power < 0 || c.Power > 5 {
			t.Errorf("%s has power %d", c.ID, c.Power)
		}
		if len(c.HireCost) == 0 {
			t.Errorf("%s costs nothing", c.ID)
		}
		for elem, qty := range c.HireCost {
			if elem == EAether {
				t.Errorf("%s costs Aether, which is only ever a wildcard payment", c.ID)
			}
			if qty < 1 || qty > 7 {
				t.Errorf("%s costs %d %s, outside the 1..7 range", c.ID, qty, elem)
			}
		}
	}
	if len(cardByID) != 90 {
		t.Errorf("lookup map holds %d cards, want 90", len(cardByID))
	}
}

// Power is distributed identically across the five races, which is what keeps
// no race strictly better to build into than another.
func TestDeck_PowerDistribution(t *testing.T) {
	perRace := map[Element]int{}
	shape := map[Element]map[int][]int{} // affinity -> tier -> power values

	for _, c := range AllCards {
		perRace[c.Affinity] += c.Power
		if shape[c.Affinity] == nil {
			shape[c.Affinity] = map[int][]int{}
		}
		shape[c.Affinity][c.Tier] = append(shape[c.Affinity][c.Tier], c.Power)
	}

	total := 0
	for _, elem := range AllElements {
		if perRace[elem] != 28 {
			t.Errorf("%s cards total %d Power, want 28", elem, perRace[elem])
		}
		total += perRace[elem]

		// Tier 1: seven cards at 0 Power, one at 1.
		assertPowerCounts(t, elem, 1, shape[elem][1], map[int]int{0: 7, 1: 1})
		// Tier 2: two at 1, three at 2, one at 3.
		assertPowerCounts(t, elem, 2, shape[elem][2], map[int]int{1: 2, 2: 3, 3: 1})
		// Tier 3: one at 3, two at 4, one at 5.
		assertPowerCounts(t, elem, 3, shape[elem][3], map[int]int{3: 1, 4: 2, 5: 1})
	}

	if total != 140 {
		t.Errorf("deck totals %d Power, want 140", total)
	}
}

func assertPowerCounts(t *testing.T, elem Element, tier int, powers []int, want map[int]int) {
	t.Helper()
	got := map[int]int{}
	for _, p := range powers {
		got[p]++
	}
	for power, n := range want {
		if got[power] != n {
			t.Errorf("%s tier %d has %d cards at %d Power, want %d", elem, tier, got[power], power, n)
		}
	}
	for power, n := range got {
		if want[power] == 0 {
			t.Errorf("%s tier %d has %d unexpected cards at %d Power", elem, tier, n, power)
		}
	}
}

// The top card of each race costs 7 of an allied element plus 3 of its own.
// GDD v2 calls this shape load-bearing for the strategy, and two races had it
// wrong before the 2026-09-05 correction.
func TestDeck_TopCardsKeepTheSevenThreeShape(t *testing.T) {
	found := map[Element]bool{}
	for _, c := range AllCards {
		if c.Tier != 3 || c.Power != 5 {
			continue
		}
		found[c.Affinity] = true

		if len(c.HireCost) != 2 {
			t.Errorf("%s (%s) costs %d elements, want exactly 2", c.ID, c.Affinity, len(c.HireCost))
			continue
		}
		if c.HireCost[c.Affinity] != 3 {
			t.Errorf("%s (%s) pays %d of its own element, want 3", c.ID, c.Affinity, c.HireCost[c.Affinity])
		}
		sevens := 0
		for elem, qty := range c.HireCost {
			if qty == 7 {
				sevens++
				if elem == c.Affinity {
					t.Errorf("%s pays 7 of its own element; the 7 must be the allied element", c.ID)
				}
			}
		}
		if sevens != 1 {
			t.Errorf("%s has %d components of 7, want exactly 1", c.ID, sevens)
		}
	}
	for _, elem := range AllElements {
		if !found[elem] {
			t.Errorf("%s has no 5-Power tier 3 card", elem)
		}
	}
}

// Each race also has a single-element tier 3 card costing 7 of one colour.
func TestDeck_SingleColourTopCards(t *testing.T) {
	count := 0
	for _, c := range AllCards {
		if c.Tier != 3 || len(c.HireCost) != 1 {
			continue
		}
		count++
		for elem, qty := range c.HireCost {
			if qty != 7 {
				t.Errorf("%s is a single-element tier 3 card costing %d %s, want 7", c.ID, qty, elem)
			}
			if elem == c.Affinity {
				t.Errorf("%s costs 7 of its own element, which would be self-discounting", c.ID)
			}
		}
		if c.Power != 4 {
			t.Errorf("%s is the single-element tier 3 card but has %d Power, want 4", c.ID, c.Power)
		}
	}
	if count != 5 {
		t.Errorf("found %d single-element tier 3 cards, want one per race", count)
	}
}

// Tier 1 gives each race exactly one 1-Power card, costing 4 of a single element.
func TestDeck_Tier1EntryCards(t *testing.T) {
	count := 0
	for _, c := range AllCards {
		if c.Tier != 1 || c.Power != 1 {
			continue
		}
		count++
		if len(c.HireCost) != 1 {
			t.Errorf("%s is the tier 1 point card but costs %d elements, want 1", c.ID, len(c.HireCost))
			continue
		}
		for elem, qty := range c.HireCost {
			if qty != 4 {
				t.Errorf("%s costs %d %s, want 4", c.ID, qty, elem)
			}
		}
	}
	if count != 5 {
		t.Errorf("found %d tier 1 point cards, want one per race", count)
	}
}

// The 10 artifacts are the Splendor nobles: five ask for two colours at 4, five
// for three colours at 3.
func TestArtifacts_Shape(t *testing.T) {
	if len(AllArtifacts) != 10 {
		t.Fatalf("there are %d artifacts, want 10", len(AllArtifacts))
	}

	twos, threes := 0, 0
	seen := map[string]bool{}
	for _, a := range AllArtifacts {
		if seen[a.ID] {
			t.Errorf("duplicate artifact ID %s", a.ID)
		}
		seen[a.ID] = true
		if a.Name == "" {
			t.Errorf("%s has no name", a.ID)
		}

		switch len(a.Requirement) {
		case 2:
			twos++
			for elem, n := range a.Requirement {
				if n != 4 {
					t.Errorf("%s asks for %d %s, want 4", a.ID, n, elem)
				}
			}
		case 3:
			threes++
			for elem, n := range a.Requirement {
				if n != 3 {
					t.Errorf("%s asks for %d %s, want 3", a.ID, n, elem)
				}
			}
		default:
			t.Errorf("%s asks for %d elements, want 2 or 3", a.ID, len(a.Requirement))
		}
	}

	if twos != 5 || threes != 5 {
		t.Errorf("artifact split is %d two-colour and %d three-colour, want 5 and 5", twos, threes)
	}
}

// Setup deals the right board whatever the table size (GDD v2 §5.2).
func TestSetup_SupplyAndArtifactsByPlayerCount(t *testing.T) {
	cases := []struct {
		players   int
		perColour int
		artifacts int
	}{
		{2, 4, 3},
		{3, 5, 4},
		{4, 7, 5},
	}

	for _, tc := range cases {
		ids := make([]string, tc.players)
		for i := range ids {
			ids[i] = string(rune('a' + i))
		}
		ms := NewMatchState(ids, ids, false, tc.players)

		for _, elem := range AllElements {
			if got := ms.Supply[elem]; got != tc.perColour {
				t.Errorf("%d players: %s supply = %d, want %d", tc.players, elem, got, tc.perColour)
			}
		}
		if ms.AetherSupply != 5 {
			t.Errorf("%d players: Aether supply = %d, want 5", tc.players, ms.AetherSupply)
		}
		if len(ms.Artifacts) != tc.artifacts {
			t.Errorf("%d players: revealed %d artifacts, want %d", tc.players, len(ms.Artifacts), tc.artifacts)
		}

		if len(ms.Tier1Visible) != 4 || len(ms.Tier2Visible) != 4 || len(ms.Tier3Visible) != 4 {
			t.Errorf("%d players: face-up rows are %d/%d/%d, want 4 each",
				tc.players, len(ms.Tier1Visible), len(ms.Tier2Visible), len(ms.Tier3Visible))
		}
		if len(ms.Tier1Deck) != 36 || len(ms.Tier2Deck) != 26 || len(ms.Tier3Deck) != 16 {
			t.Errorf("%d players: draw piles are %d/%d/%d, want 36/26/16",
				tc.players, len(ms.Tier1Deck), len(ms.Tier2Deck), len(ms.Tier3Deck))
		}
	}
}

// The 2026-10-15 data correction, pinned: V-04 and the four artifacts that had
// drifted from Splendor. Two independent datasets agree on these values, so a
// change here is a regression, not a balance tweak.
func TestCorrectedSplendorDataIsPinned(t *testing.T) {
	if got, want := cardByID["V-04"].HireCost, (Cost{ELight: 2, ENature: 2}); !sameCost(got, want) {
		t.Errorf("V-04 costs %v, want %v", got, want)
	}

	want := map[string]Cost{
		"A-01": {EFire: 4, ENature: 4},
		"A-05": {EWater: 4, ELight: 4},
		"A-07": {EWater: 3, ELight: 3, EShadow: 3},
		"A-10": {EFire: 3, ENature: 3, EWater: 3},
	}
	for _, a := range AllArtifacts {
		if w, ok := want[a.ID]; ok && !sameCost(a.Requirement, w) {
			t.Errorf("%s requires %v, want %v", a.ID, a.Requirement, w)
		}
	}
}

// sameCost compares two costs ignoring zero entries.
func sameCost(a, b Cost) bool {
	for _, e := range AllElements {
		if a[e] != b[e] {
			return false
		}
	}
	return a[EAether] == b[EAether]
}
