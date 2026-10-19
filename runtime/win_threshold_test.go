package main

import "testing"

// An unrated game may choose its target; a rated one always plays to the default.
func TestWinThreshold_ChosenOnlyForUnratedGames(t *testing.T) {
	m := &SplendorMatch{}
	cases := []struct {
		name   string
		params map[string]interface{}
		want   int
	}{
		{"private 18", map[string]interface{}{"rated": false, "playerCount": 2, "winThreshold": 18}, 18},
		{"private 21", map[string]interface{}{"rated": false, "playerCount": 3, "winThreshold": 21}, 21},
		{"private 30", map[string]interface{}{"rated": false, "playerCount": 2, "winThreshold": 30}, 30},
		{"private default", map[string]interface{}{"rated": false, "playerCount": 2}, WinThreshold},
		{"not an option", map[string]interface{}{"rated": false, "playerCount": 2, "winThreshold": 17}, WinThreshold},
		{"rated ignores it", map[string]interface{}{"rated": true, "playerCount": 2, "winThreshold": 21}, WinThreshold},
	}
	for _, c := range cases {
		state, _, _ := m.MatchInit(testContext(), &mockLogger{t}, nil, nil, c.params)
		if got := state.(*MatchState).WinThresholdVal; got != c.want {
			t.Errorf("%s: WinThresholdVal = %d, want %d", c.name, got, c.want)
		}
	}
	if WinThreshold != 18 {
		t.Errorf("default WinThreshold = %d, want 18", WinThreshold)
	}
}
