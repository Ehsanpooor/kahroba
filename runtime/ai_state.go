package main

import "math/rand"

// ai_state.go — the simulation state the AI reasons over.
//
// This is deliberately not MatchState. The search copies a position hundreds of
// thousands of times per move, so everything here is a fixed-size value type:
// no maps, no slices, no pointers, and therefore no allocation inside the hot
// loop. Copying a position is a memcpy.
//
// Element counts are [6]int arrays indexed by colour rather than map[Element]int.
// That single change is worth roughly an order of magnitude in simulation
// throughput, which converts directly into playing strength at a fixed time
// budget.

// Gem indices. The first five are the playable colours; Aether is the wildcard
// and is deliberately last so `for i := 0; i < nColors; i++` skips it.
const (
	gLight  = 0
	gWater  = 1
	gNature = 2
	gFire   = 3
	gShadow = 4
	gAether = 5

	nColors = 5
	nGems   = 6

	maxPlayers = 4
	boardWidth = 4  // face-up cards per tier
	maxDeck    = 40 // tier 1 is the largest deck
	maxArts    = 5  // players + 1, capped at 4 players
	noCard     = 0xFF
)

// Gems is a count per gem type.
type Gems [nGems]int

func (g Gems) total() int {
	n := 0
	for i := 0; i < nGems; i++ {
		n += g[i]
	}
	return n
}

func (g Gems) colourTotal() int {
	n := 0
	for i := 0; i < nColors; i++ {
		n += g[i]
	}
	return n
}

// elementIndex maps the wire element strings onto gem indices.
var elementIndex = map[Element]int{
	ELight:  gLight,
	EWater:  gWater,
	ENature: gNature,
	EFire:   gFire,
	EShadow: gShadow,
	EAether: gAether,
}

// indexElement is the reverse, for turning a chosen move back into a message.
var indexElement = [nGems]Element{ELight, EWater, ENature, EFire, EShadow, EAether}

// costToGems converts the authoritative Cost map into the array form.
func costToGems(c Cost) Gems {
	var g Gems
	for elem, n := range c {
		if i, ok := elementIndex[elem]; ok {
			g[i] = n
		}
	}
	return g
}

// ---------- static card tables ----------

type aiCard struct {
	id        string
	tier      uint8
	power     int
	affinity  int // gem index
	cost      Gems
	costTotal int
}

type aiArtifact struct {
	id  string
	req Gems
}

var (
	aiCards     []aiCard
	aiCardIndex map[string]uint8
	aiArtifacts []aiArtifact
	aiArtIndex  map[string]uint8

	// aiTierCards lists every card index belonging to a tier, used to build the
	// unseen pool when the search determinizes the hidden decks.
	aiTierCards [4][]uint8
)

func init() {
	aiCards = make([]aiCard, len(AllCards))
	aiCardIndex = make(map[string]uint8, len(AllCards))
	for i, c := range AllCards {
		cost := costToGems(c.HireCost)
		aiCards[i] = aiCard{
			id:        c.ID,
			tier:      uint8(c.Tier),
			power:     c.Power,
			affinity:  elementIndex[c.Affinity],
			cost:      cost,
			costTotal: cost.colourTotal(),
		}
		aiCardIndex[c.ID] = uint8(i)
		aiTierCards[c.Tier] = append(aiTierCards[c.Tier], uint8(i))
	}

	aiArtifacts = make([]aiArtifact, len(AllArtifacts))
	aiArtIndex = make(map[string]uint8, len(AllArtifacts))
	for i, a := range AllArtifacts {
		aiArtifacts[i] = aiArtifact{id: a.ID, req: costToGems(a.Requirement)}
		aiArtIndex[a.ID] = uint8(i)
	}
}

// ---------- position ----------

type aiPlayer struct {
	coins     Gems
	discount  Gems // one per hired card of that colour
	points    int
	cards     int
	artifacts int
	reserve   [MaxReserveCap]uint8
	reserveN  uint8
	conceded  bool
}

// MaxReserveCap is the compile-time reserve bound. MaxReserve is configurable
// at runtime but never exceeds this in any shipped configuration.
const MaxReserveCap = 3

type aiState struct {
	players [maxPlayers]aiPlayer
	n       int // seats in play
	cur     int // seat to move
	first   int // seat that opened the game; the final round ends on wrapping back to it

	board  [4][boardWidth]uint8 // [tier][slot]; index 0 unused
	boardN [4]int
	decks  [4][maxDeck]uint8
	deckN  [4]int

	supply Gems // index gAether holds the Aether pile

	arts  [maxArts]uint8
	artsN int

	threshold  int
	finalRound bool
	ended      bool

	// passes counts consecutive turns on which the seat had no legal move. Once
	// every seat still in the game has passed in a row, nobody can ever move
	// again and the game ends, mirroring the server's stalemate finish.
	passes int

	coinLimit int
	reserveMx int
}

// clone returns an independent copy. It is a plain value copy by construction.
func (s *aiState) clone() aiState { return *s }

// ---------- helpers ----------

func (s *aiState) me() *aiPlayer { return &s.players[s.cur] }

// activeCount counts seats still in the game.
func (s *aiState) activeCount() int {
	n := 0
	for i := 0; i < s.n; i++ {
		if !s.players[i].conceded {
			n++
		}
	}
	return n
}

// power is a seat's current score.
func (p *aiPlayer) power() int { return p.points + p.artifacts*ArtifactPower }

// payFor computes the coins a seat spends on a card, or reports that it cannot
// afford it. Own colours are spent before Aether, matching CoinsToSpend.
func (p *aiPlayer) payFor(c *aiCard) (Gems, bool) {
	var spend Gems
	aether := 0
	for i := 0; i < nColors; i++ {
		need := c.cost[i] - p.discount[i]
		if need <= 0 {
			continue
		}
		if have := p.coins[i]; have >= need {
			spend[i] = need
		} else {
			if have > 0 {
				spend[i] = have
			}
			aether += need - have
		}
	}
	if aether > p.coins[gAether] {
		return Gems{}, false
	}
	spend[gAether] = aether
	return spend, true
}

// netCost is what a seat would still have to find for a card, per colour, after
// discounts and the coins already in hand. It is the raw material for both the
// evaluation and the move ordering.
func (p *aiPlayer) netCost(c *aiCard) (deficit Gems, total int) {
	for i := 0; i < nColors; i++ {
		need := c.cost[i] - p.discount[i] - p.coins[i]
		if need > 0 {
			deficit[i] = need
			total += need
		}
	}
	// Aether in hand covers any colour, so it reduces the shortfall.
	if total > 0 && p.coins[gAether] > 0 {
		total -= p.coins[gAether]
		if total < 0 {
			total = 0
		}
	}
	return deficit, total
}

// ---------- board mutation ----------

// takeFromBoard removes a face-up card and refills its slot from the tier deck,
// keeping slot order stable exactly as the server does.
func (s *aiState) takeFromBoard(tier int, slot int) {
	if s.deckN[tier] > 0 {
		s.board[tier][slot] = s.decks[tier][0]
		copy(s.decks[tier][:s.deckN[tier]-1], s.decks[tier][1:s.deckN[tier]])
		s.deckN[tier]--
		return
	}
	// Deck exhausted: close the gap so the row shrinks.
	copy(s.board[tier][slot:s.boardN[tier]-1], s.board[tier][slot+1:s.boardN[tier]])
	s.boardN[tier]--
}

func (s *aiState) findOnBoard(card uint8) (tier, slot int, ok bool) {
	for t := 1; t <= 3; t++ {
		for i := 0; i < s.boardN[t]; i++ {
			if s.board[t][i] == card {
				return t, i, true
			}
		}
	}
	return 0, 0, false
}

func (p *aiPlayer) hasReserved(card uint8) bool {
	for i := 0; i < int(p.reserveN); i++ {
		if p.reserve[i] == card {
			return true
		}
	}
	return false
}

func (p *aiPlayer) dropReserved(card uint8) bool {
	for i := 0; i < int(p.reserveN); i++ {
		if p.reserve[i] != card {
			continue
		}
		for j := i; j < int(p.reserveN)-1; j++ {
			p.reserve[j] = p.reserve[j+1]
		}
		p.reserveN--
		return true
	}
	return false
}

// ---------- turn sequencing ----------

// claimArtifact awards at most one artifact per turn, mirroring CheckArtifacts.
func (s *aiState) claimArtifact(seat int) {
	p := &s.players[seat]
	for i := 0; i < s.artsN; i++ {
		req := aiArtifacts[s.arts[i]].req
		ok := true
		for c := 0; c < nColors; c++ {
			if p.discount[c] < req[c] {
				ok = false
				break
			}
		}
		if !ok {
			continue
		}
		p.artifacts++
		for j := i; j < s.artsN-1; j++ {
			s.arts[j] = s.arts[j+1]
		}
		s.artsN--
		return
	}
}

// endTurn runs the end-of-turn checks and passes play on, mirroring the server:
// claim an artifact, start the final round on reaching the threshold, then
// advance and detect the end of the round. There is no discard step: the move
// generator never produces a take that crosses the hold limit, exactly as the
// server rejects one (coin_limit house rule).
func (s *aiState) endTurn() {
	seat := s.cur
	s.claimArtifact(seat)

	p := &s.players[seat]

	if !s.finalRound && p.power() >= s.threshold {
		s.finalRound = true
	}

	if s.activeCount() == 0 {
		s.ended = true
		return
	}

	// Positions count from the opening seat, as MatchState.AdvanceTurn does.
	first := s.first
	if first < 0 || first >= s.n {
		first = 0
	}
	rel := (s.cur - first + s.n) % s.n
	wrapped := false
	for i := 1; i <= s.n; i++ {
		raw := rel + i
		next := (first + raw) % s.n
		if !s.players[next].conceded {
			wrapped = raw >= s.n
			s.cur = next
			break
		}
	}
	if s.finalRound && wrapped {
		s.ended = true
	}
}

// colourDemand scores how badly a seat wants each colour, based on what the
// cards it can realistically reach still cost it.
func (s *aiState) colourDemand(seat int) Gems {
	p := &s.players[seat]
	var demand Gems

	consider := func(card uint8) {
		c := &aiCards[card]
		deficit, _ := p.netCost(c)
		for i := 0; i < nColors; i++ {
			demand[i] += deficit[i]
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
	return demand
}

// ---------- determinization ----------

// determinize deals the cards this seat cannot see. Everything not face-up, not
// hired by somebody, and not in the searching player's own reserve is unseen;
// those cards are shuffled and dealt back into the decks and into opponents'
// reserve slots, respecting the tier each slot is known to hold.
//
// Re-dealing per simulation is what makes this Information Set MCTS rather than
// a search that cheats by reading the deck.
func (s *aiState) determinize(rng *rand.Rand, seen []bool, oppReserveTiers [maxPlayers][MaxReserveCap]uint8, oppReserveN [maxPlayers]uint8, viewer int) {
	var pool [4][]uint8
	for t := 1; t <= 3; t++ {
		pool[t] = pool[t][:0]
		for _, idx := range aiTierCards[t] {
			if !seen[idx] {
				pool[t] = append(pool[t], idx)
			}
		}
		rng.Shuffle(len(pool[t]), func(i, j int) { pool[t][i], pool[t][j] = pool[t][j], pool[t][i] })
	}

	// Opponents' hidden reserves are drawn first: the tier is public, the card is not.
	for seat := 0; seat < s.n; seat++ {
		if seat == viewer {
			continue
		}
		p := &s.players[seat]
		p.reserveN = 0
		for i := 0; i < int(oppReserveN[seat]); i++ {
			t := int(oppReserveTiers[seat][i])
			if t < 1 || t > 3 || len(pool[t]) == 0 {
				continue
			}
			p.reserve[p.reserveN] = pool[t][len(pool[t])-1]
			pool[t] = pool[t][:len(pool[t])-1]
			p.reserveN++
		}
	}

	// Whatever is left forms the draw piles.
	for t := 1; t <= 3; t++ {
		n := len(pool[t])
		if n > maxDeck {
			n = maxDeck
		}
		copy(s.decks[t][:n], pool[t][:n])
		s.deckN[t] = n
	}
}
