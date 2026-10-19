package main

import "math"

// ai_eval.go — position evaluation.
//
// The published Splendor planning agents scored a position by prestige points
// alone and still beat weak baselines, but their authors flagged that as the
// limit of the approach. Points are a lagging indicator: for most of the game
// the player who is ahead on points is not the player who is winning. This
// evaluation scores the things that produce points a few turns later.
//
// Everything is denominated in "point equivalents" so the weights can be read
// against each other: a term worth 1.0 is worth about one Power.

type evalWeights struct {
	// Realised score.
	point float64

	// Permanent discounts, indexed by how many of that colour are already held.
	// Concave on purpose: the first card of a colour changes what you can buy,
	// the sixth rarely does.
	discountValue [9]float64
	discountScale float64

	// Artifact (noble) proximity. Each is worth 3 Power, a fifth of the game.
	artifact      float64
	artifactDecay float64

	// Forward value of the cards actually within reach.
	target       float64
	targetSecond float64
	turnPenalty  float64

	// Coins are worth only what they buy.
	coinUseful  float64
	coinSurplus float64
	aether      float64
	hoard       float64

	reserve float64

	// Feature switches, used to make the easier opponents genuinely simpler
	// rather than merely noisier.
	seeArtifacts bool
	seeTargets   bool

	// Spread of the softmax that turns raw scores into per-seat values, in
	// point equivalents. Lower means more decisive.
	temperature float64
}

// defaultWeights is the full-strength evaluation.
var defaultWeights = evalWeights{
	point: 1.0,

	// Roughly: a first discount is worth a point, saturating near five.
	discountValue: [9]float64{0, 1.00, 1.85, 2.55, 3.10, 3.50, 3.80, 4.00, 4.10},
	discountScale: 1.0,

	artifact:      3.0,
	artifactDecay: 0.45,

	target:       1.15,
	targetSecond: 0.35,
	turnPenalty:  0.55,

	coinUseful:  0.16,
	coinSurplus: 0.03,
	aether:      0.30,
	hoard:       0.10,

	reserve: 0.25,

	seeArtifacts: true,
	seeTargets:   true,

	temperature: 2.6,
}

// coinsPerTurn is the average colour intake of a turn spent collecting. Three
// coins is the nominal take, but colours run dry and the hold limit bites, so
// the planning estimate is deliberately below 3.
const coinsPerTurn = 2.7

// estimateTurns approximates how many collecting turns a seat still needs
// before it can pay for a card. It is capped because beyond a few turns the
// estimate stops carrying information: the board will have changed.
func estimateTurns(p *aiPlayer, c *aiCard) float64 {
	deficit, total := p.netCost(c)
	if total <= 0 {
		return 0
	}
	maxSingle := 0
	for i := 0; i < nColors; i++ {
		if deficit[i] > maxSingle {
			maxSingle = deficit[i]
		}
	}

	byVolume := float64(total) / coinsPerTurn
	// A single deep colour requirement is the real constraint: a turn yields at
	// most two of one colour, and only when the supply allows Channel.
	byColour := float64(maxSingle) / 2.0

	turns := byVolume
	if byColour > turns {
		turns = byColour
	}
	if turns > 6 {
		turns = 6
	}
	return turns
}

// artifactGain is how much closer a card of this colour brings the seat to an
// artifact it has not yet claimed.
func (s *aiState) artifactGain(p *aiPlayer, colour int, w *evalWeights) float64 {
	if !w.seeArtifacts || s.artsN == 0 {
		return 0
	}
	best := 0.0
	for i := 0; i < s.artsN; i++ {
		req := aiArtifacts[s.arts[i]].req
		if req[colour] <= p.discount[colour] {
			continue // this artifact does not want any more of that colour
		}
		before := artifactDeficit(p, req)
		gain := w.artifact * (decay(before-1, w.artifactDecay) - decay(before, w.artifactDecay))
		if gain > best {
			best = gain
		}
	}
	return best
}

func artifactDeficit(p *aiPlayer, req Gems) int {
	d := 0
	for i := 0; i < nColors; i++ {
		if short := req[i] - p.discount[i]; short > 0 {
			d += short
		}
	}
	return d
}

// decay turns a shortfall in cards into a fraction of the reward, so an
// artifact two cards away is worth far more than one six cards away.
func decay(deficit int, rate float64) float64 {
	if deficit <= 0 {
		return 1
	}
	return 1.0 / (1.0 + rate*float64(deficit))
}

// cardGain is what acquiring a card is worth: its Power, the discount it adds,
// and the artifact progress it unlocks.
func (s *aiState) cardGain(p *aiPlayer, c *aiCard, w *evalWeights) float64 {
	gain := float64(c.power) * w.point

	have := p.discount[c.affinity]
	if have+1 < len(w.discountValue) {
		gain += (w.discountValue[have+1] - w.discountValue[have]) * w.discountScale
	}
	gain += s.artifactGain(p, c.affinity, w)
	return gain
}

// scoreSeat is the raw evaluation of one seat's position, in point equivalents.
func (s *aiState) scoreSeat(seat int, w *evalWeights) float64 {
	p := &s.players[seat]
	if p.conceded {
		return -1000
	}

	score := float64(p.power()) * w.point

	// Engine: the permanent discounts already banked.
	for i := 0; i < nColors; i++ {
		d := p.discount[i]
		if d >= len(w.discountValue) {
			d = len(w.discountValue) - 1
		}
		score += w.discountValue[d] * w.discountScale
	}

	// Artifacts still on the table, weighted by how close they are.
	if w.seeArtifacts {
		bestArt, secondArt := 0.0, 0.0
		for i := 0; i < s.artsN; i++ {
			v := w.artifact * decay(artifactDeficit(p, aiArtifacts[s.arts[i]].req), w.artifactDecay)
			if v > bestArt {
				bestArt, secondArt = v, bestArt
			} else if v > secondArt {
				secondArt = v
			}
		}
		// Only one artifact can be claimed per turn and rivals compete for the
		// same tiles, so the second is discounted heavily rather than added whole.
		score += bestArt + 0.3*secondArt
	}

	// Forward value: the best cards actually within reach, discounted by how
	// long they take. This is what stops the agent hoarding coins it cannot spend.
	if w.seeTargets {
		best, second := 0.0, 0.0
		consider := func(card uint8) {
			c := &aiCards[card]
			v := s.cardGain(p, c, w) / (1.0 + w.turnPenalty*estimateTurns(p, c))
			if v > best {
				best, second = v, best
			} else if v > second {
				second = v
			}
		}
		for t := 1; t <= 3; t++ {
			for i := 0; i < s.boardN[t]; i++ {
				consider(s.board[t][i])
			}
		}
		for i := 0; i < int(p.reserveN); i++ {
			consider(p.reserve[i])
		}
		score += w.target*best + w.targetSecond*second
	}

	// Coins, valued by whether anything on the table wants them.
	demand := s.colourDemand(seat)
	for i := 0; i < nColors; i++ {
		useful := p.coins[i]
		if useful > demand[i] {
			useful = demand[i]
		}
		score += float64(useful) * w.coinUseful
		score += float64(p.coins[i]-useful) * w.coinSurplus
	}
	score += float64(p.coins[gAether]) * w.aether

	// Sitting on a full hand wastes turns; nudge towards spending.
	if over := p.coins.total() - (s.coinLimit - 2); over > 0 {
		score -= float64(over) * w.hoard
	}

	score += float64(p.reserveN) * w.reserve
	return score
}

// terminalValues assigns the result of a finished game, splitting a shared
// victory. It applies the same ranking as ComputeStandings: a player who
// conceded or was auto-lost finishes below everyone still in the game.
func (s *aiState) terminalValues() [maxPlayers]float64 {
	bestSeat := -1
	for i := 0; i < s.n; i++ {
		if s.players[i].conceded {
			continue
		}
		if bestSeat == -1 || betterSeat(&s.players[i], &s.players[bestSeat]) {
			bestSeat = i
		}
	}

	var out [maxPlayers]float64
	if bestSeat == -1 {
		share := 1.0 / float64(s.n)
		for i := 0; i < s.n; i++ {
			out[i] = share
		}
		return out
	}

	winners := 0
	for i := 0; i < s.n; i++ {
		if !s.players[i].conceded && !betterSeat(&s.players[bestSeat], &s.players[i]) {
			winners++
		}
	}
	for i := 0; i < s.n; i++ {
		if !s.players[i].conceded && !betterSeat(&s.players[bestSeat], &s.players[i]) {
			out[i] = 1.0 / float64(winners)
		}
	}
	return out
}

// betterSeat reports whether a outranks b: more Power, then fewer cards.
func betterSeat(a, b *aiPlayer) bool {
	if a.power() != b.power() {
		return a.power() > b.power()
	}
	return a.cards < b.cards
}

// evaluate converts a position into a value per seat, summing to 1. A softmax
// over the raw scores keeps the search sensitive to the size of a lead rather
// than only its sign, which matters in a race where second place is worthless.
func (s *aiState) evaluate(w *evalWeights) [maxPlayers]float64 {
	if s.ended {
		return s.terminalValues()
	}

	var raw [maxPlayers]float64
	best := math.Inf(-1)
	for i := 0; i < s.n; i++ {
		raw[i] = s.scoreSeat(i, w)
		if raw[i] > best {
			best = raw[i]
		}
	}

	var out [maxPlayers]float64
	sum := 0.0
	for i := 0; i < s.n; i++ {
		e := math.Exp((raw[i] - best) / w.temperature)
		out[i] = e
		sum += e
	}
	if sum <= 0 {
		share := 1.0 / float64(s.n)
		for i := 0; i < s.n; i++ {
			out[i] = share
		}
		return out
	}
	for i := 0; i < s.n; i++ {
		out[i] /= sum
	}
	return out
}

// moveHeuristic scores a move without simulating it. It drives move ordering,
// the search's progressive bias, and the rollout policy, so it has to be cheap:
// no cloning, no lookahead.
func (s *aiState) moveHeuristic(m aiMove, w *evalWeights) float64 {
	p := s.me()

	switch m.kind {
	case mvHire:
		c := &aiCards[m.card]
		// Buying is almost always the productive move; rank by what it gains.
		return 2.0 + s.cardGain(p, c, w)

	case mvReserve:
		if m.card == noCard {
			return 0.15 // a blind draw is mostly a way to take an Aether
		}
		c := &aiCards[m.card]
		// Worth most when the card is strong and nearly affordable, which is
		// also when an opponent is most likely to take it first.
		return 0.35 + 0.30*s.cardGain(p, c, w)/(1.0+estimateTurns(p, c))

	case mvChannel, mvHarvest:
		// Collecting is valued by how much of the take the player can actually
		// spend: coins nobody on this board wants are close to worthless.
		demand := s.colourDemand(s.cur)
		score := 0.0
		for i := 0; i < nColors; i++ {
			if m.take[i] == 0 {
				continue
			}
			want := demand[i] - p.coins[i]
			switch {
			case want >= 2:
				score += 1.0 * float64(m.take[i])
			case want >= 1:
				score += 0.7 * float64(m.take[i])
			default:
				score += 0.15 * float64(m.take[i])
			}
		}
		return score * 0.45
	}
	return 0.1
}
