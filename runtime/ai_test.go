package main

import (
	"math/rand"
	"testing"
	"time"
)

// ai_test.go — correctness and, more importantly, strength.
//
// A bot that never makes an illegal move is easy; a bot worth playing is not.
// The tests below assert the things that make the engine worth shipping: that
// the levels are genuinely ordered by strength in head-to-head play, that all
// three beat a random player decisively, that the search cannot see hidden
// cards, and that the shipped time budget is actually met.

// ---------- self-play harness ----------

// newSelfPlayGame deals a real game: full decks, shuffled, four cards up per tier.
func newSelfPlayGame(players int, rng *rand.Rand) aiState {
	var st aiState
	st.n = players
	st.cur = 0
	st.threshold = WinThreshold
	st.coinLimit = MaxCoins
	st.reserveMx = MaxReserveCap

	supplyPer := 7
	switch players {
	case 2:
		supplyPer = 4
	case 3:
		supplyPer = 5
	}
	for i := 0; i < nColors; i++ {
		st.supply[i] = supplyPer
	}
	st.supply[gAether] = 5

	for t := 1; t <= 3; t++ {
		deck := append([]uint8(nil), aiTierCards[t]...)
		rng.Shuffle(len(deck), func(i, j int) { deck[i], deck[j] = deck[j], deck[i] })
		for i := 0; i < boardWidth && i < len(deck); i++ {
			st.board[t][i] = deck[i]
		}
		st.boardN[t] = boardWidth
		rest := deck[boardWidth:]
		copy(st.decks[t][:len(rest)], rest)
		st.deckN[t] = len(rest)
	}

	arts := rng.Perm(len(aiArtifacts))
	n := players + 1
	if n > maxArts {
		n = maxArts
	}
	for i := 0; i < n; i++ {
		st.arts[i] = uint8(arts[i])
	}
	st.artsN = n

	return st
}

// knowledgeFor derives what one seat legitimately knows: everything except the
// draw piles and other players' reserved cards.
func knowledgeFor(st *aiState, viewer int) aiKnowledge {
	know := aiKnowledge{seen: make([]bool, len(aiCards))}
	for i := range know.seen {
		know.seen[i] = true
	}
	for t := 1; t <= 3; t++ {
		for i := 0; i < st.deckN[t]; i++ {
			know.seen[st.decks[t][i]] = false
		}
	}
	for seat := 0; seat < st.n; seat++ {
		p := &st.players[seat]
		for i := 0; i < int(p.reserveN); i++ {
			know.reserveTiers[seat][i] = aiCards[p.reserve[i]].tier
			know.reserveN[seat]++
			if seat != viewer {
				know.seen[p.reserve[i]] = false
			}
		}
	}
	return know
}

// playGame runs one complete game between the supplied profiles and returns the
// winning seat, or -1 for a shared result.
func playGame(t *testing.T, profiles []aiProfile, seed int64) int {
	t.Helper()
	rng := rand.New(rand.NewSource(seed))
	st := newSelfPlayGame(len(profiles), rng)

	for turn := 0; turn < 600 && !st.ended; turn++ {
		seat := st.cur
		know := knowledgeFor(&st, seat)
		before := st.cur

		decision := chooseMoveWithProfile(st, know, profiles[seat], rng)
		st.apply(decision.move)

		if st.cur == before && !st.ended {
			t.Fatalf("seat %d played a move that did not end its turn", seat)
		}
	}
	if !st.ended {
		// A game that never reaches the threshold is itself a finding: it would
		// mean the agents cannot build an engine at all.
		t.Fatalf("game did not finish in 600 turns; scores %d/%d",
			st.players[0].power(), st.players[1].power())
	}

	values := st.terminalValues()
	best, bestValue, tied := -1, 0.0, false
	for i := 0; i < st.n; i++ {
		switch {
		case values[i] > bestValue:
			best, bestValue, tied = i, values[i], false
		case values[i] == bestValue && values[i] > 0:
			tied = true
		}
	}
	if tied {
		return -1
	}
	return best
}

// testProfiles are the shipped levels at a reduced search budget, so the
// strength comparison runs in seconds rather than minutes. The relative ordering
// is what is under test; TestAIShippedBudget covers the real budget.
func testProfile(d AIDifficulty) aiProfile {
	p := profileFor(d)
	p.thinkMin, p.thinkMax = 0, 0
	switch d {
	case AIHard:
		p.cfg.maxSimulations = 1200
		p.cfg.timeBudget = 0
	case AINormal:
		p.cfg.maxSimulations = 120
		p.cfg.timeBudget = 0
	}
	return p
}

// randomProfile plays legal moves with no judgement at all: the floor that any
// difficulty must clear comfortably.
func randomProfile() aiProfile {
	return aiProfile{weights: defaultWeights, cfg: searchConfig{maxSimulations: 0}, blunder: 1.0, topK: 1}
}

// duel plays games with the seat order alternating, so the first-player
// advantage cannot decide the result, and returns wins for profile A.
func duel(t *testing.T, a, b aiProfile, games int, seed int64) (winsA, winsB, draws int) {
	t.Helper()
	for g := 0; g < games; g++ {
		var profiles []aiProfile
		aSeat := g % 2
		if aSeat == 0 {
			profiles = []aiProfile{a, b}
		} else {
			profiles = []aiProfile{b, a}
		}
		switch playGame(t, profiles, seed+int64(g)) {
		case aSeat:
			winsA++
		case -1:
			draws++
		default:
			winsB++
		}
	}
	return
}

// ---------- strength ----------

// Every difficulty must beat a player choosing uniformly at random by a wide
// margin. An agent that cannot do this is not an opponent, it is a dice roll.
func TestAIBeatsRandomPlay(t *testing.T) {
	if testing.Short() {
		t.Skip("strength tests are slow")
	}
	cases := []struct {
		name    string
		profile aiProfile
		minWins int
	}{
		{"easy", testProfile(AIEasy), 26},
		{"normal", testProfile(AINormal), 30},
		{"hard", testProfile(AIHard), 30},
	}
	const games = 32

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			wins, losses, draws := duel(t, tc.profile, randomProfile(), games, 900)
			t.Logf("%s vs random: %d-%d-%d", tc.name, wins, losses, draws)
			if wins < tc.minWins {
				t.Errorf("%s won only %d of %d against random play, want at least %d",
					tc.name, wins, games, tc.minWins)
			}
		})
	}
}

// The levels must be ordered by strength. This is the test that would catch a
// change that makes the evaluation or the search worse rather than better.
func TestAIDifficultyLadder(t *testing.T) {
	if testing.Short() {
		t.Skip("strength tests are slow")
	}
	const games = 40

	t.Run("normal beats easy", func(t *testing.T) {
		wins, losses, draws := duel(t, testProfile(AINormal), testProfile(AIEasy), games, 1700)
		t.Logf("normal vs easy: %d-%d-%d", wins, losses, draws)
		if wins <= losses {
			t.Errorf("normal won %d and lost %d against easy; the ladder is inverted", wins, losses)
		}
	})

	t.Run("hard beats easy", func(t *testing.T) {
		wins, losses, draws := duel(t, testProfile(AIHard), testProfile(AIEasy), games, 2300)
		t.Logf("hard vs easy: %d-%d-%d", wins, losses, draws)
		if wins < games*6/10 {
			t.Errorf("hard won only %d of %d against easy, want a clear majority", wins, games)
		}
	})

	t.Run("hard is at least normal's equal", func(t *testing.T) {
		wins, losses, draws := duel(t, testProfile(AIHard), testProfile(AINormal), games, 3100)
		t.Logf("hard vs normal: %d-%d-%d", wins, losses, draws)
		if wins+draws < losses {
			t.Errorf("hard lost the series to normal (%d-%d-%d)", wins, losses, draws)
		}
	})
}

// A search that reads the deck would show up here: the agent must play the same
// way whether or not the true deck order sits in the state it was handed.
func TestSearchCannotSeeHiddenCards(t *testing.T) {
	rng := rand.New(rand.NewSource(4242))
	st := newSelfPlayGame(2, rng)

	// Give seat 1 a reserved card that seat 0 must not be able to identify.
	hidden := st.decks[3][0]
	st.players[1].reserve[0] = hidden
	st.players[1].reserveN = 1

	know := knowledgeFor(&st, 0)
	if know.seen[hidden] {
		t.Fatal("an opponent's reserved card was marked as seen by seat 0")
	}
	for t3 := 0; t3 < st.deckN[3]; t3++ {
		if know.seen[st.decks[3][t3]] {
			t.Fatalf("a card still in the tier 3 deck was marked as seen")
		}
	}

	// After determinization the searcher's copy must not hold the true deck order.
	sr := &searcher{
		root: st, weights: defaultWeights, rng: rng, viewer: 0,
		seen: know.seen, oppReserveTiers: know.reserveTiers, oppReserveN: know.reserveN,
	}
	identical := 0
	const trials = 40
	for i := 0; i < trials; i++ {
		sim := sr.root.clone()
		sim.determinize(sr.rng, sr.seen, sr.oppReserveTiers, sr.oppReserveN, sr.viewer)
		if sim.decks[3][0] == st.decks[3][0] {
			identical++
		}
		if sim.players[1].reserveN != 1 {
			t.Fatalf("determinization lost the opponent's reserved card")
		}
	}
	if identical == trials {
		t.Error("every determinization reproduced the true deck order; the deck is not actually hidden")
	}
}

// ---------- behaviour ----------

// Offered a strong card it can pay for outright, the engine takes it rather
// than collecting more coins.
func TestEngineBuysAnAffordableCard(t *testing.T) {
	rng := rand.New(rand.NewSource(7))
	st := newSelfPlayGame(2, rng)

	// Put a known tier 2 card on the board and fund it exactly.
	target := aiCardIndex["V-14"] // 3 Power, costs 6 Shadow
	st.board[2][0] = target
	st.players[0].coins[gShadow] = 6

	know := knowledgeFor(&st, 0)
	d := chooseMoveWithProfile(st, know, testProfile(AIHard), rng)

	if d.move.kind != mvHire {
		t.Fatalf("engine played %v instead of buying a fully funded 3-Power card", d.move.kind)
	}
	if d.move.card != target {
		t.Errorf("engine bought %s instead of the 3-Power card", aiCards[d.move.card].id)
	}
}

// With an artifact one card away, the engine should take the card that claims it.
func TestEngineClaimsAReachableArtifact(t *testing.T) {
	rng := rand.New(rand.NewSource(11))
	st := newSelfPlayGame(2, rng)

	// A-01 wants 4 Fire and 4 Nature. Give seat 0 four Nature and three Fire.
	st.arts[0] = aiArtIndex["A-01"]
	st.artsN = 1
	st.players[0].discount[gNature] = 4
	st.players[0].discount[gFire] = 3

	// Offer a Fire card the player can afford, plus a Light card of equal Power.
	fire := aiCardIndex["D-06"]  // Fire affinity, cheap
	light := aiCardIndex["H-07"] // Light affinity, cheap
	st.board[1][0] = light
	st.board[1][1] = fire
	st.boardN[1] = 2
	// Clear the higher tiers: with a 5-Power card also on offer the engine is
	// right to take the points instead, and the test would be asserting the
	// wrong thing.
	st.boardN[2], st.boardN[3] = 0, 0
	// Both cards affordable (D-06: Water 2 + Nature 1, H-07: Water 3), with
	// room left under the 10-coin limit so collecting is a live alternative.
	st.players[0].coins = Gems{gLight: 2, gWater: 3, gNature: 1, gFire: 1, gShadow: 1}

	know := knowledgeFor(&st, 0)
	d := chooseMoveWithProfile(st, know, testProfile(AIHard), rng)

	if d.move.kind != mvHire || d.move.card != fire {
		t.Errorf("engine played %v/%s; the Fire card completes a 3-Power artifact this turn",
			d.move.kind, cardLabel(d.move))
	}
}

// The engine must not sit on a full hand it cannot spend.
func TestEngineDoesNotHoardCoins(t *testing.T) {
	rng := rand.New(rand.NewSource(13))
	st := newSelfPlayGame(2, rng)
	for i := 0; i < nColors; i++ {
		st.players[0].coins[i] = 2 // 10 coins: at the limit
	}

	know := knowledgeFor(&st, 0)
	d := chooseMoveWithProfile(st, know, testProfile(AIHard), rng)

	if d.move.kind == mvHarvest || d.move.kind == mvChannel {
		if d.move.take.total() > 0 {
			t.Errorf("engine took more coins while already holding the maximum of %d", MaxCoins)
		}
	}
}

// The move generator must offer only takes the server accepts under the hard
// 10-coin limit: at 8 up to two coins, at 9 one, at 10 none, and Channel only
// with room for both coins. Reserving stays on offer at the limit.
func TestMoveGeneratorRespectsCoinLimit(t *testing.T) {
	cases := []struct {
		held                    int
		maxTake                 int
		wantTriple, wantChannel bool
		wantPair, wantSingle    bool
	}{
		{held: 7, maxTake: 3, wantTriple: true, wantChannel: true},
		{held: 8, maxTake: 2, wantChannel: true, wantPair: true, wantSingle: true},
		{held: 9, maxTake: 1, wantSingle: true},
		{held: 10, maxTake: 0},
	}
	for _, c := range cases {
		rng := rand.New(rand.NewSource(21))
		st := newSelfPlayGame(4, rng)         // 7 per colour: Channel is available everywhere
		st.players[0].coins[gAether] = c.held // Aether counts towards the limit

		var list moveList
		st.generateMoves(&list)

		var triple, pair, single, channel, reserve bool
		for i := 0; i < list.n; i++ {
			m := list.moves[i]
			n := m.take.total()
			if (m.kind == mvHarvest || m.kind == mvChannel) && n > c.maxTake {
				t.Errorf("held %d: generated a take of %d coins (max %d)", c.held, n, c.maxTake)
			}
			switch {
			case m.kind == mvChannel:
				channel = true
			case m.kind == mvHarvest && n == 3:
				triple = true
			case m.kind == mvHarvest && n == 2:
				pair = true
			case m.kind == mvHarvest && n == 1:
				single = true
			case m.kind == mvReserve:
				reserve = true
			}
		}
		if triple != c.wantTriple || channel != c.wantChannel || pair != c.wantPair || single != c.wantSingle {
			t.Errorf("held %d: triple=%v pair=%v single=%v channel=%v, want %v/%v/%v/%v",
				c.held, triple, pair, single, channel, c.wantTriple, c.wantPair, c.wantSingle, c.wantChannel)
		}
		if !reserve {
			t.Errorf("held %d: reserving must stay available at any coin count", c.held)
		}
	}
}

// Reserving in the simulation mirrors the server: an Aether below the limit,
// none at it.
func TestSimulatedReserveAetherAtCoinLimit(t *testing.T) {
	for _, held := range []int{9, 10} {
		rng := rand.New(rand.NewSource(5))
		st := newSelfPlayGame(2, rng)
		st.players[0].coins[gLight] = held
		aether := st.supply[gAether]

		st.apply(aiMove{kind: mvReserve, card: st.board[1][0], tier: 1})

		got := st.players[0].coins
		wantAether := 1
		if held == MaxCoins {
			wantAether = 0
		}
		if got[gAether] != wantAether || st.supply[gAether] != aether-wantAether {
			t.Errorf("held %d: reserve gave %d Aether (supply %d -> %d), want %d",
				held, got[gAether], aether, st.supply[gAether], wantAether)
		}
		if got.total() > MaxCoins {
			t.Errorf("held %d: reserve left the seat on %d coins", held, got.total())
		}
	}
}

// The simulation ends a frozen position the way the server does: once every
// seat still in the game has passed in a row, nobody can move again.
func TestSimulationEndsWhenEveryoneIsBoxedIn(t *testing.T) {
	rng := rand.New(rand.NewSource(17))
	st := newSelfPlayGame(2, rng)
	for seat := 0; seat < 2; seat++ {
		p := &st.players[seat]
		p.coins = Gems{gLight: MaxCoins}
		p.reserveN = MaxReserveCap
	}
	// Nothing in reach costs Light, so nothing is affordable.
	for t3 := 1; t3 <= 3; t3++ {
		n := 0
		for _, idx := range aiTierCards[t3] {
			if aiCards[idx].cost[gLight] == 0 && n < boardWidth {
				st.board[t3][n] = idx
				n++
			}
		}
		st.boardN[t3] = n
	}
	for seat := 0; seat < 2; seat++ {
		for i := 0; i < MaxReserveCap; i++ {
			st.players[seat].reserve[i] = st.board[1][i]
		}
	}

	var list moveList
	st.generateMoves(&list)
	if list.n != 1 || list.moves[0].take.total() != 0 {
		t.Fatalf("boxed-in seat was offered %d moves, want only the pass", list.n)
	}

	st.apply(list.moves[0])
	if st.ended {
		t.Fatal("the game ended after one pass; seat 1 has not passed yet")
	}
	st.apply(aiMove{kind: mvHarvest})
	if !st.ended {
		t.Error("two consecutive passes by the only two seats should end the game")
	}
}

func cardLabel(m aiMove) string {
	if m.card == noCard {
		return "blind"
	}
	return aiCards[m.card].id
}

// ---------- budget ----------

// The shipped Hard profile must respect its time budget: an opponent that hangs
// the match loop is worse than a weak one.
func TestAIShippedBudgetIsRespected(t *testing.T) {
	rng := rand.New(rand.NewSource(99))
	st := newSelfPlayGame(4, rng)
	know := knowledgeFor(&st, 0)

	profile := profileFor(AIHard)
	profile.thinkMin, profile.thinkMax = 0, 0

	started := time.Now()
	d := chooseMoveWithProfile(st, know, profile, rng)
	elapsed := time.Since(started)

	budget := profile.cfg.timeBudget
	if elapsed > budget+150*time.Millisecond {
		t.Errorf("hard took %s against a %s budget", elapsed, budget)
	}
	if d.simulations < 500 {
		t.Errorf("hard managed only %d simulations in %s; the search is too slow to be strong",
			d.simulations, elapsed)
	}
	t.Logf("hard: %d simulations in %s (%.0f sims/sec)",
		d.simulations, elapsed.Round(time.Millisecond), float64(d.simulations)/elapsed.Seconds())
}

// Legality under stress: thousands of moves across table sizes, every one of
// them generated and applied by the engine, with the invariants checked.
func TestEngineNeverBreaksTheRules(t *testing.T) {
	for players := 2; players <= 4; players++ {
		rng := rand.New(rand.NewSource(int64(players) * 31))
		for game := 0; game < 6; game++ {
			st := newSelfPlayGame(players, rng)
			for turn := 0; turn < 500 && !st.ended; turn++ {
				seat := st.cur
				know := knowledgeFor(&st, seat)
				d := chooseMoveWithProfile(st, know, testProfile(AINormal), rng)
				st.apply(d.move)

				for i := 0; i < st.n; i++ {
					p := &st.players[i]
					if total := p.coins.total(); total > MaxCoins {
						t.Fatalf("%dp game %d: seat %d holds %d coins", players, game, i, total)
					}
					if int(p.reserveN) > MaxReserveCap {
						t.Fatalf("%dp game %d: seat %d reserved %d cards", players, game, i, p.reserveN)
					}
					for c := 0; c < nGems; c++ {
						if p.coins[c] < 0 {
							t.Fatalf("%dp game %d: seat %d has negative coins", players, game, i)
						}
					}
				}
				for c := 0; c < nGems; c++ {
					if st.supply[c] < 0 {
						t.Fatalf("%dp game %d: supply went negative", players, game)
					}
				}
			}
		}
	}
}

// ---------- benchmarks ----------

func BenchmarkAISimulation(b *testing.B) {
	rng := rand.New(rand.NewSource(1))
	st := newSelfPlayGame(2, rng)
	know := knowledgeFor(&st, 0)
	profile := profileFor(AIHard)
	profile.cfg.timeBudget = 0
	profile.cfg.maxSimulations = 2000

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		chooseMoveWithProfile(st, know, profile, rng)
	}
}

func BenchmarkMoveGeneration(b *testing.B) {
	rng := rand.New(rand.NewSource(2))
	st := newSelfPlayGame(4, rng)
	var list moveList
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		st.generateMoves(&list)
	}
}
