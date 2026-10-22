package main

import (
	"math/rand"
	"testing"
)

// usePersonas swaps in a small roster for a test and restores it after.
func usePersonas(t *testing.T, list []*persona) {
	t.Helper()
	personaMu.Lock()
	oldList, oldReady, oldBusy := personas, personaReady, personaBusy
	personas, personaReady, personaBusy = list, true, map[string]string{}
	personaMu.Unlock()
	t.Cleanup(func() {
		personaMu.Lock()
		personas, personaReady, personaBusy = oldList, oldReady, oldBusy
		personaMu.Unlock()
	})
}

// A public table with one player fills with personas over time, then runs
// the ready check; personas press Ready after a moment and look like players.
func TestPublicTable_FillsWithPersonas(t *testing.T) {
	usePersonas(t, []*persona{
		{Key: "a", Name: "سارا", Skill: AIHard, BaseRating: 1100, Avatar: "A-03", UserID: "persona-uid-a"},
		{Key: "b", Name: "reza_kh", Skill: AINormal, BaseRating: 1020, Avatar: "A-07", UserID: "persona-uid-b"},
	})
	ms := NewMatchStateSeeded(nil, nil, true, 3, 7)
	ms.Public, ms.ReadyCheck = true, true
	human := newPlayerState("human-1", "Ehsan")
	human.Disconnected = false
	ms.Players = append(ms.Players, human)
	ms.trackPresence(presenceFor("human-1"))

	now := int64(1_000_000)
	planArrivals(ms, now)
	if len(ms.botArrivals) != 2 {
		t.Fatalf("planned %d arrivals, want 2", len(ms.botArrivals))
	}
	last := ms.botArrivals[1]
	if last-now < 6000 || last-now > 330000 {
		t.Errorf("table fills after %d ms, want 6 s .. 330 s", last-now)
	}

	disp := &mockDispatcher{}
	tc := turnCtx{ctx: testContext(), logger: &mockLogger{t}, dispatcher: disp, now: last}
	ms = fillPublicTable(ms, tc)
	if len(ms.Players) != 3 || ms.Phase != PhaseReadyCheck {
		t.Fatalf("players=%d phase=%s, want 3 and readyCheck", len(ms.Players), ms.Phase)
	}
	for i := 1; i < 3; i++ {
		p := ms.Players[i]
		if !p.Persona || p.Ready || p.ReadyAtMs == 0 {
			t.Errorf("seat %d: persona=%v ready=%v readyAt=%d, want a persona not yet ready", i, p.Persona, p.Ready, p.ReadyAtMs)
		}
		v := ms.ViewFor("human-1", last).Players[i]
		if v.IsAI || v.AIDifficulty != "" || v.DisplayName == "" || v.AvatarID == "" {
			t.Errorf("seat %d looks like a bot to the player: %+v", i, v)
		}
	}

	// the personas press Ready in their own time; the human too, and play starts
	tc.now = last + 11_000
	ms = checkReadyCheck(ms, tc)
	ms = handleReady(ms, "human-1", tc)
	if ms.Phase != PhasePlaying {
		t.Fatalf("phase = %s after everyone is ready, want playing", ms.Phase)
	}
	if !ms.Rated {
		t.Error("a table of one player and personas must stay rated")
	}
}

// A second real searcher takes the place of a planned persona.
func TestPublicTable_HumanReplacesPlannedPersona(t *testing.T) {
	ms := NewMatchStateSeeded(nil, nil, true, 4, 3)
	ms.Public = true
	ms.Players = append(ms.Players, newPlayerState("h1", "A"))
	planArrivals(ms, 0)
	if len(ms.botArrivals) != 3 {
		t.Fatalf("planned %d, want 3", len(ms.botArrivals))
	}
	ms.Players = append(ms.Players, newPlayerState("h2", "B"))
	humanArrived(ms)
	if len(ms.botArrivals) != 2 {
		t.Errorf("after a second player, %d personas still planned, want 2", len(ms.botArrivals))
	}
}

// Personas think like people: never instant, never past the clock.
func TestHumanThink_WithinTheClock(t *testing.T) {
	ms := NewMatchStateSeeded([]string{"p", "q"}, []string{"P", "Q"}, true, 2, 9)
	ms.WinThresholdVal = 18
	rng := rand.New(rand.NewSource(1))
	minMs, maxMs := int64(1<<62), int64(0)
	regular := 0
	for i := 0; i < 2000; i++ {
		ms.Players[0].TurnsTaken = i % 12
		d := humanThinkMs(ms, 0, rng)
		if d >= 7000 && d <= 35000 {
			regular++
		}
		if d < minMs {
			minMs = d
		}
		if d > maxMs {
			maxMs = d
		}
	}
	if minMs < 7000 {
		t.Errorf("fastest move %d ms, want at least 7 s", minMs)
	}
	if regular < 1800 {
		t.Errorf("%d of 2000 moves took 7-35 s, want nearly all", regular)
	}
	if maxMs > int64(TurnSeconds-3)*1000 {
		t.Errorf("slowest move %d ms, too close to the %d s clock", maxMs, TurnSeconds)
	}
	if maxMs < 45000 {
		t.Errorf("slowest move %d ms; hard decisions should sometimes take 45 s or more", maxMs)
	}
}
