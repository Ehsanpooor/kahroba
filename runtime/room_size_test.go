package main

import "testing"

// A friends' room seats up to 6 with a larger bank: 8 or 9 of each colour,
// one more gold per player past 4, and players+1 nobles.
func TestRoomSize_FiveAndSixPlayers(t *testing.T) {
	for n, want := range map[int][3]int{2: {4, 5, 3}, 4: {7, 5, 5}, 5: {8, 6, 6}, 6: {9, 7, 7}} {
		ms := NewMatchStateSeeded(nil, nil, false, n, 1)
		for _, e := range AllElements {
			if ms.Supply[e] != want[0] {
				t.Errorf("%d players: %s supply %d, want %d", n, e, ms.Supply[e], want[0])
			}
		}
		if ms.AetherSupply != want[1] || len(ms.Artifacts) != want[2] {
			t.Errorf("%d players: gold %d nobles %d, want %d and %d", n, ms.AetherSupply, len(ms.Artifacts), want[1], want[2])
		}
	}
}

// The computer can take over any seat of a 6-player table.
func TestRoomSize_AIPlaysSixSeats(t *testing.T) {
	ms := NewMatchStateSeeded([]string{"a", "b", "c", "d", "e", "f"}, nil, false, 6, 3)
	ms.Phase = PhasePlaying
	for seat := range ms.Players {
		ms.CurrentTurn = seat
		st, know := buildAIState(ms, seat)
		if st.n != 6 {
			t.Fatalf("the AI sees %d players, want 6", st.n)
		}
		d := chooseMove(st, know, AIHard, ms.random())
		if op, _ := actionFor(d.move); op == 0 {
			t.Errorf("seat %d: no move", seat)
		}
	}
}
