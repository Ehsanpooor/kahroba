package main

// ai_moves.go — legal move generation and application for the search.
//
// Move generation is the search's inner loop, so the list is written into a
// caller-owned fixed buffer and never allocates. Every move generated is legal
// on the server; in particular no Harvest or Channel ever takes the seat above
// the 10-coin hold limit, which the server rejects with coin_limit (house rule:
// there is no "take then return" in Veynoria).
//
// The generator also prunes legal-but-pointless moves, which is what keeps the
// branching factor near 40 instead of near 70: taking fewer than three coins is
// only searched when the hold limit or a thin supply makes it the best take
// available. (Reserving with a full hand is illegal, not merely pruned.)
//
// Pruning here rather than in the evaluation is deliberate: every move removed
// is search budget spent on moves that matter.

type aiMoveKind uint8

const (
	mvHarvest aiMoveKind = iota // take up to 3 coins of different colours
	mvChannel                   // take 2 of one colour
	mvHire                      // buy a card from the board or the reserve
	mvReserve                   // put a card in hand and take an Aether
)

type aiMove struct {
	kind aiMoveKind
	take Gems  // harvest and channel
	card uint8 // hire and board reserve; noCard for a blind draw
	tier uint8 // blind reserve only
}

const maxMoves = 80

type moveList struct {
	moves [maxMoves]aiMove
	n     int
}

func (l *moveList) reset() { l.n = 0 }

func (l *moveList) add(m aiMove) {
	if l.n < maxMoves {
		l.moves[l.n] = m
		l.n++
	}
}

// The ten combinations of three distinct colours out of five, precomputed so
// the generator never builds them at runtime.
var harvestTriples = [10][3]int{
	{0, 1, 2}, {0, 1, 3}, {0, 1, 4}, {0, 2, 3}, {0, 2, 4},
	{0, 3, 4}, {1, 2, 3}, {1, 2, 4}, {1, 3, 4}, {2, 3, 4},
}

var harvestPairs = [10][2]int{
	{0, 1}, {0, 2}, {0, 3}, {0, 4}, {1, 2},
	{1, 3}, {1, 4}, {2, 3}, {2, 4}, {3, 4},
}

// generateMoves fills out with every move worth considering for the seat on turn.
func (s *aiState) generateMoves(out *moveList) {
	out.reset()
	p := s.me()

	room := s.coinLimit - p.coins.total() // coins this seat may still take
	available := 0
	for i := 0; i < nColors; i++ {
		if s.supply[i] > 0 {
			available++
		}
	}

	// --- Action A: harvest ---
	//
	// A take is legal only if it keeps the seat at or under the hold limit, so a
	// seat at 10 coins cannot harvest at all, at 9 only one coin, at 8 up to two.
	if available >= 3 && room >= 3 {
		for _, t := range harvestTriples {
			if s.supply[t[0]] > 0 && s.supply[t[1]] > 0 && s.supply[t[2]] > 0 {
				var g Gems
				g[t[0]], g[t[1]], g[t[2]] = 1, 1, 1
				out.add(aiMove{kind: mvHarvest, take: g})
			}
		}
	}
	// Smaller takes matter when the table cannot offer three colours, or when
	// the hold limit leaves room for fewer than three.
	if available < 3 || room < 3 {
		if room >= 2 {
			for _, pr := range harvestPairs {
				if s.supply[pr[0]] > 0 && s.supply[pr[1]] > 0 {
					var g Gems
					g[pr[0]], g[pr[1]] = 1, 1
					out.add(aiMove{kind: mvHarvest, take: g})
				}
			}
		}
		if room >= 1 {
			for i := 0; i < nColors; i++ {
				if s.supply[i] > 0 {
					var g Gems
					g[i] = 1
					out.add(aiMove{kind: mvHarvest, take: g})
				}
			}
		}
	}

	// --- Action B: channel ---
	if room >= 2 {
		for i := 0; i < nColors; i++ {
			if s.supply[i] >= ChannelMinSupply {
				var g Gems
				g[i] = 2
				out.add(aiMove{kind: mvChannel, take: g})
			}
		}
	}

	// --- Action C: hire ---
	for t := 1; t <= 3; t++ {
		for i := 0; i < s.boardN[t]; i++ {
			card := s.board[t][i]
			if _, ok := p.payFor(&aiCards[card]); ok {
				out.add(aiMove{kind: mvHire, card: card})
			}
		}
	}
	for i := 0; i < int(p.reserveN); i++ {
		card := p.reserve[i]
		if _, ok := p.payFor(&aiCards[card]); ok {
			out.add(aiMove{kind: mvHire, card: card})
		}
	}

	// --- Action D: reserve ---
	// Legal even at the hold limit; it then simply comes without the Aether.
	if int(p.reserveN) < s.reserveMx {
		for t := 1; t <= 3; t++ {
			for i := 0; i < s.boardN[t]; i++ {
				out.add(aiMove{kind: mvReserve, card: s.board[t][i], tier: uint8(t)})
			}
			if s.deckN[t] > 0 {
				out.add(aiMove{kind: mvReserve, card: noCard, tier: uint8(t)})
			}
		}
	}

	// A seat with no legal move at all (10 coins, full reserve, nothing
	// affordable) passes, exactly as the server passes it (passTurn). Harvesting
	// nothing stands in for that pass and keeps the simulation well defined; the
	// live seat never submits it, because driveAISeat checks HasLegalAction first.
	if out.n == 0 {
		out.add(aiMove{kind: mvHarvest})
	}
}

// apply plays a move and ends the turn. The state is left with `cur` on the
// next seat, or `ended` set.
func (s *aiState) apply(m aiMove) {
	p := s.me()

	// The empty harvest is the stand-in for a pass (see generateMoves). Only a
	// seat with no legal move is ever offered it, so a full round of passes
	// means the position is frozen: end it as the server does (stalemate).
	if m.kind == mvHarvest && m.take.total() == 0 {
		s.passes++
		if s.passes >= s.activeCount() {
			s.ended = true
			return
		}
		s.endTurn()
		return
	}
	s.passes = 0

	switch m.kind {
	case mvHarvest, mvChannel:
		for i := 0; i < nColors; i++ {
			if m.take[i] == 0 {
				continue
			}
			n := m.take[i]
			if n > s.supply[i] {
				n = s.supply[i]
			}
			p.coins[i] += n
			s.supply[i] -= n
		}

	case mvHire:
		c := &aiCards[m.card]
		if spend, ok := p.payFor(c); ok {
			for i := 0; i < nGems; i++ {
				p.coins[i] -= spend[i]
				s.supply[i] += spend[i]
			}
		}
		p.points += c.power
		p.cards++
		p.discount[c.affinity]++
		if !p.dropReserved(m.card) {
			if tier, slot, found := s.findOnBoard(m.card); found {
				s.takeFromBoard(tier, slot)
			}
		}

	case mvReserve:
		card := m.card
		if card == noCard {
			t := int(m.tier)
			if s.deckN[t] == 0 {
				break
			}
			card = s.decks[t][0]
			copy(s.decks[t][:s.deckN[t]-1], s.decks[t][1:s.deckN[t]])
			s.deckN[t]--
		} else if tier, slot, found := s.findOnBoard(card); found {
			s.takeFromBoard(tier, slot)
		}
		if int(p.reserveN) < MaxReserveCap {
			p.reserve[p.reserveN] = card
			p.reserveN++
		}
		// Mirrors ReserveGrantsAether: no Aether once the seat is at the limit.
		if s.supply[gAether] > 0 && p.coins.total() < s.coinLimit {
			p.coins[gAether]++
			s.supply[gAether]--
		}
	}

	s.endTurn()
}
