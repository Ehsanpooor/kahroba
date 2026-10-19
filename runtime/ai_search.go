package main

import (
	"math"
	"math/rand"
	"time"
)

// ai_search.go — Information Set Monte Carlo Tree Search.
//
// The decks are hidden, so a search that reads them would be cheating and, worse,
// would plan around cards it cannot know are there. IS-MCTS handles this by
// re-dealing the unseen cards at the start of every simulation and keeping one
// tree indexed by what the player can actually observe. A move's statistics are
// weighted by how often it was *available* across those deals, not merely how
// often it was tried, so a card that only appears in some deals is not
// over-credited.
//
// Three refinements carry most of the strength at a small time budget:
//
//   - Progressive bias. The heuristic from ai_eval.go steers selection early and
//     fades as real statistics accumulate, so a 30 ms search is still sensible.
//   - Bootstrapped root. Every root move is sampled a fixed number of times
//     before selection turns greedy, so no move is discarded on noise.
//   - Heuristic rollouts. Uniformly random play from a Splendor position is
//     close to meaningless; sampling a few candidate moves and taking the best
//     gives a policy that is directed but still varied.

type mctsNode struct {
	key      uint32
	move     aiMove
	seat     int // seat that moved to create this node
	visits   int
	avail    int
	values   [maxPlayers]float64
	prior    float64
	children []*mctsNode
}

// moveKey packs a move into a comparable scalar so child lookup is an integer
// compare rather than a struct comparison.
func moveKey(m aiMove) uint32 {
	k := uint32(m.kind) | uint32(m.card)<<2 | uint32(m.tier)<<10
	for i := 0; i < nColors; i++ {
		k |= uint32(m.take[i]&3) << (12 + 2*i)
	}
	return k
}

func (n *mctsNode) child(key uint32) *mctsNode {
	for _, c := range n.children {
		if c.key == key {
			return c
		}
	}
	return nil
}

// nodeArena hands out nodes in blocks, keeping allocation out of the hot loop
// and giving the garbage collector one object to reclaim instead of thousands.
type nodeArena struct {
	block []mctsNode
	used  int
}

const arenaBlock = 4096

func (a *nodeArena) alloc() *mctsNode {
	if a.used >= len(a.block) {
		a.block = make([]mctsNode, arenaBlock)
		a.used = 0
	}
	n := &a.block[a.used]
	a.used++
	*n = mctsNode{}
	return n
}

// searchConfig is the tunable half of a difficulty profile.
type searchConfig struct {
	maxSimulations int
	timeBudget     time.Duration
	rolloutDepth   int
	explore        float64 // UCB1 constant
	progressive    float64 // progressive-bias weight
	bootstrap      int     // simulations guaranteed to every root move
	rolloutSample  int     // candidates sampled per rollout move
	rolloutRandom  float64 // chance of ignoring the heuristic entirely
}

type searcher struct {
	root    aiState
	weights evalWeights
	cfg     searchConfig
	rng     *rand.Rand
	arena   nodeArena
	viewer  int

	// Determinization inputs, fixed for the whole search.
	seen            []bool
	oppReserveTiers [maxPlayers][MaxReserveCap]uint8
	oppReserveN     [maxPlayers]uint8

	moves    moveList
	rollBuf  moveList
	simCount int

	// forceRoot pins the root move during the bootstrap phase, so every option
	// is sampled before selection is allowed to turn greedy.
	forceRoot int
}

// search runs IS-MCTS and returns the best move together with the number of
// simulations spent, which the caller logs.
func (s *searcher) search() (aiMove, int) {
	root := s.arena.alloc()
	root.seat = s.root.cur
	s.forceRoot = -1

	// Bootstrap: give every root move a guaranteed share of simulations before
	// selection becomes selective. Without it a strong move that opens with two
	// unlucky rollouts can be abandoned before it is ever fairly assessed, which
	// is exactly the failure mode of a short search.
	var rootMoves moveList
	s.root.generateMoves(&rootMoves)
	bootstrapSims := s.cfg.bootstrap * rootMoves.n

	// Cap it. With ~40 root moves an uncapped bootstrap can swallow a small
	// budget whole, leaving nothing for selective search and making a short
	// search strictly worse than no bootstrap at all.
	if cap := s.cfg.maxSimulations * 2 / 5; bootstrapSims > cap {
		bootstrapSims = cap
	}

	deadline := time.Now().Add(s.cfg.timeBudget)
	checkEvery := 64

	for s.simCount = 0; s.simCount < s.cfg.maxSimulations; s.simCount++ {
		if s.simCount%checkEvery == 0 && s.cfg.timeBudget > 0 && time.Now().After(deadline) {
			break
		}
		if s.simCount < bootstrapSims && rootMoves.n > 0 {
			s.forceRoot = s.simCount % rootMoves.n
		} else {
			s.forceRoot = -1
		}

		st := s.root.clone()
		st.determinize(s.rng, s.seen, s.oppReserveTiers, s.oppReserveN, s.viewer)
		s.simulate(root, &st, 0)
	}

	return s.bestRootMove(root), s.simCount
}

// bestRootMove picks the most-visited legal move, the robust choice: it is far
// less sensitive to a single lucky rollout than picking the highest mean.
func (s *searcher) bestRootMove(root *mctsNode) aiMove {
	st := s.root.clone()
	st.generateMoves(&s.moves)

	best, bestVisits, bestValue := aiMove{}, -1, math.Inf(-1)
	found := false

	for i := 0; i < s.moves.n; i++ {
		m := s.moves.moves[i]
		c := root.child(moveKey(m))
		if c == nil {
			continue
		}
		value := math.Inf(-1)
		if c.visits > 0 {
			value = c.values[s.root.cur] / float64(c.visits)
		}
		if c.visits > bestVisits || (c.visits == bestVisits && value > bestValue) {
			best, bestVisits, bestValue, found = m, c.visits, value, true
		}
	}

	if !found {
		// The search never ran, which only happens with a zero budget. Fall back
		// to the heuristic so the agent still plays sensibly.
		return s.greedyMove(&st)
	}
	return best
}

// greedyMove picks the highest-heuristic move with no lookahead at all.
func (s *searcher) greedyMove(st *aiState) aiMove {
	st.generateMoves(&s.moves)
	best, bestScore := aiMove{}, math.Inf(-1)
	for i := 0; i < s.moves.n; i++ {
		if v := st.moveHeuristic(s.moves.moves[i], &s.weights); v > bestScore {
			best, bestScore = s.moves.moves[i], v
		}
	}
	return best
}

// simulate performs one selection-expansion-rollout-backpropagation pass.
func (s *searcher) simulate(node *mctsNode, st *aiState, depth int) [maxPlayers]float64 {
	if st.ended || depth >= 40 {
		v := st.evaluate(&s.weights)
		node.visits++
		addValues(&node.values, v)
		return v
	}

	var moves moveList
	st.generateMoves(&moves)

	// Availability counting: a move present in this deal has been offered once
	// more, whether or not it is chosen.
	var untried [maxMoves]int
	untriedN := 0
	for i := 0; i < moves.n; i++ {
		if c := node.child(moveKey(moves.moves[i])); c != nil {
			c.avail++
		} else {
			untried[untriedN] = i
			untriedN++
		}
	}

	seat := st.cur
	var chosen aiMove
	var child *mctsNode

	// Bootstrap phase: the root move is dictated rather than selected.
	if depth == 0 && s.forceRoot >= 0 && s.forceRoot < moves.n {
		chosen = moves.moves[s.forceRoot]
		key := moveKey(chosen)
		if child = node.child(key); child == nil {
			child = s.arena.alloc()
			child.key = key
			child.move = chosen
			child.seat = seat
			child.avail = 1
			child.prior = st.moveHeuristic(chosen, &s.weights)
			node.children = append(node.children, child)

			st.apply(chosen)
			v := s.rollout(st, depth)
			child.visits++
			addValues(&child.values, v)
			node.visits++
			addValues(&node.values, v)
			return v
		}
		st.apply(chosen)
		v := s.simulate(child, st, depth+1)
		node.visits++
		addValues(&node.values, v)
		return v
	}

	if untriedN > 0 {
		// Expand. Among unexplored moves prefer the one the heuristic likes, so
		// the first look at a node is already informed.
		bestIdx, bestScore := untried[0], math.Inf(-1)
		for i := 0; i < untriedN; i++ {
			idx := untried[i]
			score := st.moveHeuristic(moves.moves[idx], &s.weights) + 0.15*s.rng.Float64()
			if score > bestScore {
				bestIdx, bestScore = idx, score
			}
		}
		chosen = moves.moves[bestIdx]

		child = s.arena.alloc()
		child.key = moveKey(chosen)
		child.move = chosen
		child.seat = seat
		child.avail = 1
		child.prior = st.moveHeuristic(chosen, &s.weights)
		node.children = append(node.children, child)

		st.apply(chosen)
		v := s.rollout(st, depth)
		child.visits++
		addValues(&child.values, v)
		node.visits++
		addValues(&node.values, v)
		return v
	}

	// Select. UCB1 over availability, plus a progressive bias that decays as
	// the child accumulates real statistics.
	bestScore := math.Inf(-1)
	for i := 0; i < moves.n; i++ {
		c := node.child(moveKey(moves.moves[i]))
		if c == nil || c.visits == 0 {
			continue
		}
		exploit := c.values[seat] / float64(c.visits)
		explore := s.cfg.explore * math.Sqrt(math.Log(float64(c.avail))/float64(c.visits))
		bias := s.cfg.progressive * c.prior / float64(c.visits+1)
		if score := exploit + explore + bias; score > bestScore {
			bestScore, chosen, child = score, moves.moves[i], c
		}
	}
	if child == nil {
		v := st.evaluate(&s.weights)
		node.visits++
		addValues(&node.values, v)
		return v
	}

	st.apply(chosen)
	v := s.simulate(child, st, depth+1)
	node.visits++
	addValues(&node.values, v)
	return v
}

func addValues(dst *[maxPlayers]float64, v [maxPlayers]float64) {
	for i := 0; i < maxPlayers; i++ {
		dst[i] += v[i]
	}
}

// rollout plays on with a cheap directed policy, then evaluates. The horizon is
// short by design: published work on Splendor planning agents found that the
// best configurations all converged on very short lookahead, because opponent
// choices and shuffling make longer plans noise. A good evaluation applied early
// beats a long random playout.
func (s *searcher) rollout(st *aiState, depth int) [maxPlayers]float64 {
	for ply := 0; ply < s.cfg.rolloutDepth && !st.ended; ply++ {
		st.generateMoves(&s.rollBuf)
		if s.rollBuf.n == 0 {
			break
		}
		st.apply(s.pickRolloutMove(st))
	}
	return st.evaluate(&s.weights)
}

// pickRolloutMove samples a few candidates and keeps the best. Uniformly random
// play evaluates positions no strong player would reach; a fully deterministic
// policy collapses the variance that makes sampling useful. Best-of-k sits
// between the two and costs no exponentials.
func (s *searcher) pickRolloutMove(st *aiState) aiMove {
	n := s.rollBuf.n
	if n == 1 {
		return s.rollBuf.moves[0]
	}
	if s.rng.Float64() < s.cfg.rolloutRandom {
		return s.rollBuf.moves[s.rng.Intn(n)]
	}

	samples := s.cfg.rolloutSample
	if samples > n {
		samples = n
	}
	best, bestScore := s.rollBuf.moves[s.rng.Intn(n)], math.Inf(-1)
	for i := 0; i < samples; i++ {
		m := s.rollBuf.moves[s.rng.Intn(n)]
		if v := st.moveHeuristic(m, &s.weights); v > bestScore {
			best, bestScore = m, v
		}
	}
	return best
}
