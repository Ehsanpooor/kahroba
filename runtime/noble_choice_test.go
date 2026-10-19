package main

import "testing"

// With enough cards for two nobles at once, the player's choice wins; with
// no choice (or a choice they do not qualify for) the first in table order
// is taken. Only one per turn either way.
func TestCheckArtifactsPreferring_PlayerChooses(t *testing.T) {
	// A-01 needs Fire 4 + Nature 4; A-04 needs Fire 4 + Shadow 4.
	hired := make([]CharacterCard, 0)
	for i := 0; i < 4; i++ {
		hired = append(hired, CharacterCard{Affinity: EFire}, CharacterCard{Affinity: ENature},
			CharacterCard{Affinity: EShadow})
	}
	arts := []Artifact{AllArtifacts[0], AllArtifacts[3]}
	if got := qualifyingArtifacts(hired, arts); len(got) != 2 {
		t.Fatalf("qualifies for %v, want both A-01 and A-04", got)
	}
	cases := []struct{ pref, want string }{
		{"A-04", "A-04"},
		{"A-01", "A-01"},
		{"", "A-01"},
		{"A-09", "A-01"}, // not one they qualify for
	}
	for _, c := range cases {
		if got := CheckArtifactsPreferring(hired, arts, c.pref); got != c.want {
			t.Errorf("preferring %q: got %q, want %q", c.pref, got, c.want)
		}
	}
}
