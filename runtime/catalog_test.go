package main

import (
	"encoding/json"
	"testing"
)

// catalog_test.go — the static data contract the client builds against.

func TestCatalogIsCompleteAndConsistent(t *testing.T) {
	raw, err := rpcGetCatalog(testContext(), &mockLogger{t}, nil, nil, "")
	if err != nil {
		t.Fatalf("get_catalog failed: %v", err)
	}

	var cat catalogResponse
	if err := json.Unmarshal([]byte(raw), &cat); err != nil {
		t.Fatalf("catalog did not decode: %v", err)
	}

	if len(cat.Cards) != 90 {
		t.Errorf("catalog carries %d cards, want 90", len(cat.Cards))
	}
	if len(cat.Artifacts) != 10 {
		t.Errorf("catalog carries %d artifacts, want 10", len(cat.Artifacts))
	}
	if cat.Version == "" {
		t.Error("catalog has no version, so a client cannot cache it")
	}

	// Every card the match protocol can name must resolve through the catalog,
	// otherwise the client cannot render the board.
	byID := make(map[string]catalogCard, len(cat.Cards))
	for _, c := range cat.Cards {
		byID[c.ID] = c
	}
	for _, src := range AllCards {
		got, ok := byID[src.ID]
		if !ok {
			t.Fatalf("%s is missing from the catalog", src.ID)
		}
		if got.Power != src.Power || got.Tier != src.Tier || got.Affinity != src.Affinity {
			t.Errorf("%s: catalog disagrees with the server table", src.ID)
		}
		for elem, n := range src.HireCost {
			if got.Cost[elem] != n {
				t.Errorf("%s: catalog cost %v differs from the server's %v", src.ID, got.Cost, src.HireCost)
				break
			}
		}
	}

	// Artifacts too: the requirement table is what the client draws on the tiles.
	artByID := make(map[string]catalogArtifact, len(cat.Artifacts))
	for _, a := range cat.Artifacts {
		artByID[a.ID] = a
	}
	for _, src := range AllArtifacts {
		got, ok := artByID[src.ID]
		if !ok {
			t.Fatalf("%s is missing from the catalog", src.ID)
		}
		if !sameCost(got.Requirement, src.Requirement) || got.Power != ArtifactPower {
			t.Errorf("%s: catalog %v/%d differs from the server's %v/%d",
				src.ID, got.Requirement, got.Power, src.Requirement, ArtifactPower)
		}
	}
	if a := artByID["A-01"]; a.Requirement[EFire] != 4 || a.Requirement[ENature] != 4 || a.Requirement[ELight] != 0 {
		t.Errorf("catalog A-01 = %v, want Fire 4 + Nature 4", a.Requirement)
	}
	if c := byID["V-04"]; c.Cost[ELight] != 2 || c.Cost[ENature] != 2 || c.CostTotal != 4 {
		t.Errorf("catalog V-04 = %v (total %d), want Light 2 + Nature 2", c.Cost, c.CostTotal)
	}

	// The coin-limit house rule: coin_limit is advertised, the retired
	// return-coins codes are gone.
	codes := map[string]bool{}
	for _, c := range cat.Config.RejectionCodes {
		codes[c] = true
	}
	if !codes[ErrCoinLimit] {
		t.Errorf("catalog does not list %q", ErrCoinLimit)
	}
	for _, gone := range []string{"must_return_coins", "return_count_mismatch", "return_coins_not_held"} {
		if codes[gone] {
			t.Errorf("catalog still lists the retired code %q", gone)
		}
	}

	if cat.Config.WinThreshold != WinThreshold || cat.Config.CoinHoldLimit != MaxCoins {
		t.Error("catalog config does not match the running configuration")
	}
	if len(cat.Config.RejectionCodes) == 0 {
		t.Error("catalog lists no rejection codes")
	}
	if len(cat.Config.Difficulties) != 3 {
		t.Errorf("catalog lists %d AI difficulties, want 3", len(cat.Config.Difficulties))
	}
}

// The version must be stable across calls, or clients would re-download the
// deck on every launch.
func TestCatalogVersionIsStable(t *testing.T) {
	a, _ := rpcGetCatalog(testContext(), &mockLogger{t}, nil, nil, "")
	b, _ := rpcGetCatalog(testContext(), &mockLogger{t}, nil, nil, "")
	if a != b {
		t.Error("two catalog calls returned different payloads")
	}

	var cat catalogResponse
	_ = json.Unmarshal([]byte(a), &cat)

	// A client that already holds this version is told so instead of being sent
	// the whole deck again.
	payload, _ := json.Marshal(getCatalogRequest{KnownVersion: cat.Version})
	resp, err := rpcGetCatalog(testContext(), &mockLogger{t}, nil, nil, string(payload))
	if err != nil {
		t.Fatalf("conditional fetch failed: %v", err)
	}
	var short map[string]interface{}
	_ = json.Unmarshal([]byte(resp), &short)
	if short["unchanged"] != true {
		t.Errorf("a matching knownVersion should return unchanged=true, got %s", resp)
	}
}
