package main

import (
	"math/rand"
	"time"
)

// ai_engine.go — the public face of the game AI.
//
// One rule governs the whole design: **the AI sees exactly what a player in its
// seat would see.** It runs on the server, which knows the deck order and every
// opponent's reserve, and it deliberately throws that away before searching. A
// bot that peeks plays moves a human cannot explain, which reads as cheating
// long before it reads as strength.
//
// Difficulty is not a noise dial bolted onto one engine. Each level differs in
// what it can *perceive* as well as how far it looks, so the easier opponents
// make the kind of mistakes a weaker human makes — missing an artifact, taking
// coins with no plan — rather than randomly throwing away a won position.

type AIDifficulty string

const (
	AIEasy   AIDifficulty = "easy"
	AINormal AIDifficulty = "normal"
	AIHard   AIDifficulty = "hard"
	// AIVeryHard searches much longer; the strongest regulars of the public
	// tables play at this level.
	AIVeryHard AIDifficulty = "very_hard"
)

func normalizeDifficulty(d string) AIDifficulty {
	switch AIDifficulty(d) {
	case AIEasy:
		return AIEasy
	case AIHard:
		return AIHard
	case AIVeryHard, "veryhard", "very-hard":
		return AIVeryHard
	default:
		return AINormal
	}
}

// aiProfile is a complete opponent: what it can see, how hard it thinks, and
// how often it errs.
type aiProfile struct {
	weights evalWeights
	cfg     searchConfig

	// blunder is the chance of discarding the chosen move for a random legal
	// one. Kept low even on Easy: the weaker levels get their weakness mainly
	// from a narrower view of the board.
	blunder float64

	// topK > 1 makes the level choose among its best few moves rather than the
	// single best, which reads as a player with a plan who picks the wrong
	// version of it.
	topK int

	// think is the pause before acting, so a move does not land the instant the
	// player's own does.
	thinkMin, thinkMax time.Duration
}

func profileFor(d AIDifficulty) aiProfile {
	switch d {
	case AIEasy:
		// A beginner: buys cards, understands discounts, and genuinely does not
		// track the artifacts or plan more than the turn in front of it.
		w := defaultWeights
		w.seeArtifacts = false
		w.seeTargets = false
		w.aether = 0.15
		w.reserve = 0.05
		return aiProfile{
			weights:  w,
			cfg:      searchConfig{maxSimulations: 0}, // heuristic only, no search
			blunder:  0.18,
			topK:     3,
			thinkMin: 500 * time.Millisecond,
			thinkMax: 1200 * time.Millisecond,
		}

	case AIVeryHard:
		// Hard's eyes with four times the thought.
		return aiProfile{
			weights: defaultWeights,
			cfg: searchConfig{
				maxSimulations: 1600000,
				timeBudget:     AIVeryHardThinkMs * time.Millisecond,
				rolloutDepth:   12,
				explore:        0.85,
				progressive:    1.5,
				bootstrap:      32,
				rolloutSample:  5,
				rolloutRandom:  0.06,
			},
			blunder:  0,
			topK:     1,
			thinkMin: 900 * time.Millisecond,
			thinkMax: 2200 * time.Millisecond,
		}

	case AIHard:
		// Full perception and the whole time budget.
		return aiProfile{
			weights: defaultWeights,
			cfg: searchConfig{
				maxSimulations: 400000,
				timeBudget:     AIHardThinkMs * time.Millisecond,
				rolloutDepth:   10,
				explore:        0.9,
				progressive:    1.4,
				bootstrap:      24,
				rolloutSample:  4,
				rolloutRandom:  0.10,
			},
			blunder:  0,
			topK:     1,
			thinkMin: 700 * time.Millisecond,
			thinkMax: 1800 * time.Millisecond,
		}

	default: // AINormal
		// Sees everything but thinks briefly, and discounts the future more
		// steeply, so it plays a recognisably shallower game.
		w := defaultWeights
		w.artifact = 2.1
		w.targetSecond = 0.15
		return aiProfile{
			weights: w,
			cfg: searchConfig{
				maxSimulations: 20000,
				timeBudget:     AINormalThinkMs * time.Millisecond,
				rolloutDepth:   6,
				explore:        1.1,
				progressive:    1.0,
				bootstrap:      6,
				rolloutSample:  3,
				rolloutRandom:  0.20,
			},
			blunder:  0.05,
			topK:     2,
			thinkMin: 600 * time.Millisecond,
			thinkMax: 1500 * time.Millisecond,
		}
	}
}

// Search budgets in milliseconds. Env-overridable so a busy server can trade
// bot strength for CPU without a rebuild.
var (
	AIHardThinkMs     = time.Duration(getEnvInt("AI_HARD_THINK_MS", 320))
	AIVeryHardThinkMs = time.Duration(getEnvInt("AI_VERYHARD_THINK_MS", 1200))
	AINormalThinkMs   = time.Duration(getEnvInt("AI_NORMAL_THINK_MS", 45))
)

// ---------- decision entry point ----------

// aiDecision is what the engine returns: a move plus the numbers worth logging.
type aiDecision struct {
	move        aiMove
	simulations int
	elapsed     time.Duration
}

// chooseMove picks a move for the seat on turn in the supplied position.
// The caller has already restricted `st` to that seat's knowledge.
func chooseMove(st aiState, know aiKnowledge, d AIDifficulty, rng *rand.Rand) aiDecision {
	return chooseMoveWithProfile(st, know, profileFor(d), rng)
}

// chooseMoveWithProfile is the same decision with an explicit opponent profile.
// Tests use it to compare the levels at a reduced budget without changing the
// shipped ones.
func chooseMoveWithProfile(st aiState, know aiKnowledge, profile aiProfile, rng *rand.Rand) aiDecision {
	started := time.Now()

	// No search budget, or an easy opponent: heuristic choice among the top few.
	if profile.cfg.maxSimulations <= 0 {
		return aiDecision{
			move:    heuristicChoice(&st, &profile, rng),
			elapsed: time.Since(started),
		}
	}

	s := &searcher{
		root:            st,
		weights:         profile.weights,
		cfg:             profile.cfg,
		rng:             rng,
		viewer:          st.cur,
		seen:            know.seen,
		oppReserveTiers: know.reserveTiers,
		oppReserveN:     know.reserveN,
	}
	move, sims := s.search()

	if profile.blunder > 0 && rng.Float64() < profile.blunder {
		move = randomLegalMove(&st, rng)
	}

	return aiDecision{move: move, simulations: sims, elapsed: time.Since(started)}
}

// heuristicChoice ranks every legal move and samples among the best few.
func heuristicChoice(st *aiState, profile *aiProfile, rng *rand.Rand) aiMove {
	var list moveList
	st.generateMoves(&list)
	if list.n == 0 {
		return aiMove{kind: mvHarvest}
	}
	if profile.blunder > 0 && rng.Float64() < profile.blunder {
		return list.moves[rng.Intn(list.n)]
	}

	// Partial selection sort down to topK; the list is short enough that a full
	// sort would be wasted work.
	k := profile.topK
	if k < 1 {
		k = 1
	}
	if k > list.n {
		k = list.n
	}
	scores := make([]float64, list.n)
	for i := 0; i < list.n; i++ {
		scores[i] = st.moveHeuristic(list.moves[i], &profile.weights)
	}
	for i := 0; i < k; i++ {
		best := i
		for j := i + 1; j < list.n; j++ {
			if scores[j] > scores[best] {
				best = j
			}
		}
		list.moves[i], list.moves[best] = list.moves[best], list.moves[i]
		scores[i], scores[best] = scores[best], scores[i]
	}
	return list.moves[rng.Intn(k)]
}

func randomLegalMove(st *aiState, rng *rand.Rand) aiMove {
	var list moveList
	st.generateMoves(&list)
	if list.n == 0 {
		return aiMove{kind: mvHarvest}
	}
	return list.moves[rng.Intn(list.n)]
}

// ---------- building the AI's view of a real match ----------

// aiKnowledge carries what the searching seat may assume about hidden cards.
type aiKnowledge struct {
	seen         []bool // card index -> this seat has seen it
	reserveTiers [maxPlayers][MaxReserveCap]uint8
	reserveN     [maxPlayers]uint8
}

// buildAIState projects a live match into the search representation, from the
// point of view of one seat, discarding everything that seat cannot see.
func buildAIState(ms *MatchState, viewer int) (aiState, aiKnowledge) {
	var st aiState
	var know aiKnowledge

	st.n = len(ms.Players)
	if st.n > maxPlayers {
		st.n = maxPlayers
	}
	st.cur = ms.CurrentTurn
	st.first = ms.firstSeat()
	st.threshold = ms.WinThresholdVal
	st.finalRound = ms.Phase == PhaseFinalRound
	st.coinLimit = MaxCoins
	st.reserveMx = MaxReserve
	if st.reserveMx > MaxReserveCap {
		st.reserveMx = MaxReserveCap
	}

	know.seen = make([]bool, len(aiCards))

	rows := [4][]string{1: ms.Tier1Visible, 2: ms.Tier2Visible, 3: ms.Tier3Visible}
	for t := 1; t <= 3; t++ {
		n := 0
		for _, id := range rows[t] {
			idx, ok := aiCardIndex[id]
			if !ok || n >= boardWidth {
				continue
			}
			st.board[t][n] = idx
			know.seen[idx] = true
			n++
		}
		st.boardN[t] = n
	}

	for i := 0; i < nColors; i++ {
		st.supply[i] = ms.Supply[indexElement[i]]
	}
	st.supply[gAether] = ms.AetherSupply

	for i, a := range ms.Artifacts {
		if i >= maxArts {
			break
		}
		if idx, ok := aiArtIndex[a.ID]; ok {
			st.arts[st.artsN] = idx
			st.artsN++
		}
	}

	for seat := 0; seat < st.n; seat++ {
		src := &ms.Players[seat]
		dst := &st.players[seat]
		dst.conceded = src.Conceded
		dst.artifacts = len(src.Artifacts)

		for elem, n := range src.Coins {
			if gi, ok := elementIndex[elem]; ok {
				dst.coins[gi] = n
			}
		}
		for _, c := range src.HiredCards {
			dst.points += c.Power
			dst.cards++
			if gi, ok := elementIndex[c.Affinity]; ok {
				dst.discount[gi]++
			}
			// A hired card is face-up in front of its owner: public knowledge.
			if idx, ok := aiCardIndex[c.ID]; ok {
				know.seen[idx] = true
			}
		}

		for i, slot := range src.Reserve {
			if i >= MaxReserveCap {
				break
			}
			know.reserveTiers[seat][i] = uint8(slot.Tier)
			know.reserveN[seat]++

			if seat != viewer {
				continue // an opponent's reserved card is not ours to know
			}
			if idx, ok := aiCardIndex[slot.CardID]; ok {
				dst.reserve[dst.reserveN] = idx
				dst.reserveN++
				know.seen[idx] = true
			}
		}
	}

	return st, know
}

// ---------- turning a chosen move into a match action ----------

// actionFor converts an engine move into the op code and payload the match
// handler already validates. Routing the AI through the same messages as a human
// means it cannot make a move the rules engine would reject, and there is no
// second code path to keep in step.
func actionFor(m aiMove) (int64, interface{}) {
	switch m.kind {
	case mvChannel:
		for i := 0; i < nColors; i++ {
			if m.take[i] > 0 {
				return OpActionChannel, msgChannel{Element: indexElement[i]}
			}
		}
		return OpActionHarvest, msgHarvest{}

	case mvHire:
		return OpActionHire, msgHire{CharacterID: aiCards[m.card].id}

	case mvReserve:
		if m.card == noCard {
			return OpActionJail, msgJail{Tier: int(m.tier)}
		}
		return OpActionJail, msgJail{CharacterID: aiCards[m.card].id}

	default: // mvHarvest
		elements := make([]Element, 0, 3)
		for i := 0; i < nColors; i++ {
			for n := 0; n < m.take[i]; n++ {
				elements = append(elements, indexElement[i])
			}
		}
		return OpActionHarvest, msgHarvest{Elements: elements}
	}
}

// Playing styles: every computer player at a table plays its own way, so
// they do not all make the same choices (a table of personas that all play
// alike would give them away). A style shifts what a player values, not how
// strong it is. Personas keep theirs from game to game; the computer seats
// of a table each get a different one.
var aiStyles = []string{"builder", "noble", "reserver", "rusher", "collector"}

func withStyle(p aiProfile, style string) aiProfile {
	w := &p.weights
	switch style {
	case "builder": // discounts first, points later
		w.discountScale *= 1.3
		w.point *= 0.9
	case "noble": // chases the artifacts' (nobles') colours
		w.artifact *= 1.5
	case "reserver": // keeps cards back to plan
		w.reserve *= 2.6
	case "rusher": // goes for big cards early
		w.point *= 1.25
		w.target *= 1.2
		w.discountScale *= 0.85
	case "collector": // holds gems, then buys in bursts
		w.coinUseful *= 1.5
		w.hoard *= 2.0
	}
	return p
}

// styleOf is the style of the computer player in `seat`: a persona's own
// (from its account), else one per seat, all different at one table.
func styleOf(ms *MatchState, seat int) string {
	p := &ms.Players[seat]
	if p.Persona {
		return aiStyles[hashOf(p.UserID)%uint32(len(aiStyles))]
	}
	return aiStyles[(seat+int(ms.Seed%int64(len(aiStyles)))+len(aiStyles))%len(aiStyles)]
}
