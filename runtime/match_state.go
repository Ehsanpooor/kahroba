package main

import (
	cryptorand "crypto/rand"
	"encoding/binary"
	"encoding/json"
	"math/rand"

	"github.com/heroiclabs/nakama-common/runtime"
)

// GamePhase tracks the match lifecycle.
type GamePhase string

const (
	PhaseWaiting GamePhase = "waiting"
	// PhaseReadyCheck runs between "every seat is filled" and the first turn
	// of an online match: each human seat must send READY (match_ready.go).
	PhaseReadyCheck GamePhase = "readyCheck"
	PhasePlaying    GamePhase = "playing"
	PhaseFinalRound GamePhase = "finalRound"
	PhaseEnded      GamePhase = "ended"
)

// EndReason explains why a match finished, so the client can show the right
// end screen and analytics can tell a real game from a dead lobby.
type EndReason string

const (
	EndReasonNone         EndReason = ""
	EndReasonThreshold    EndReason = "threshold"    // someone hit the Power threshold, final round played out
	EndReasonLastStanding EndReason = "lastStanding" // everyone else conceded or was auto-lost
	EndReasonAllLeft      EndReason = "allConceded"  // nobody left in the game
	EndReasonLobbyTimeout EndReason = "lobbyTimeout" // players never all connected, or no human passed the ready check; unrated, no history
	// Every player still in the game is boxed in by the coin-limit house rule
	// (10 coins, full reserve, nothing affordable), so no move can ever be made
	// again. Scored like any other finish: most Power, then fewest cards.
	EndReasonStalemate EndReason = "stalemate"
)

// ReserveSlot is one card in a player's reserve.
//
// CardID is populated only in the owner's own view. Opponents receive the slot
// with an empty CardID: reserved cards are hidden information in this game, so
// the wire format simply never carries the ID to anyone else (see match_view.go).
type ReserveSlot struct {
	CardID     string `json:"cardId,omitempty"`
	Tier       int    `json:"tier"`
	FromBoard  bool   `json:"fromBoard"` // true = taken face-up, false = blind draw
	ReservedAt int64  `json:"-"`
}

// PlayerState is the authoritative per-player state held server-side.
// It is never sent to clients as-is; every broadcast goes through match_view.go.
type PlayerState struct {
	UserID       string          `json:"userId"`
	DisplayName  string          `json:"displayName"`
	AvatarID     string          `json:"avatarId,omitempty"` // the portrait the player chose ("" for bots)
	Coins        Cost            `json:"coins"`
	HiredCards   []CharacterCard `json:"hiredCards"`
	Reserve      []ReserveSlot   `json:"reserve"`
	Artifacts    []string        `json:"artifacts"`
	MissedTurns  int             `json:"missedTurns"`
	Disconnected bool            `json:"disconnected"`
	Conceded     bool            `json:"conceded"`
	TurnsTaken   int             `json:"turnsTaken"`

	// A bot seat. It holds no Nakama account, so nothing writes rating,
	// history or an active-match lock against it.
	IsAI         bool   `json:"isAI"`
	AIDifficulty string `json:"aiDifficulty,omitempty"`

	// Persona: an AI seat played by one of the regulars of the public tables
	// (personas.go). It has a real account and rating, is rated like anyone
	// else, and the clients see it as a player. ReadyAtMs is when it presses
	// Ready in the ready check.
	Persona   bool  `json:"persona,omitempty"`
	ReadyAtMs int64 `json:"-"`

	// Rating shown at the table (read from the account when the seat is taken).
	Rating int `json:"rating,omitempty"`

	// Ready check (match_ready.go). Ready is true once the seat has answered;
	// a bot is ready from the moment it sits down. ReadyDeadlineMs is this
	// seat's own deadline, since a replacement gets a fresh window.
	Ready           bool  `json:"ready"`
	ReadyDeadlineMs int64 `json:"readyDeadlineMs,omitempty"`

	// SeatOpen marks a seat whose player the ready check removed and which a
	// public match is holding for a searcher until RefillDeadlineMs. An open
	// seat has no user and the game cannot start while one exists.
	SeatOpen         bool  `json:"seatOpen,omitempty"`
	RefillDeadlineMs int64 `json:"refillDeadlineMs,omitempty"`
}

// ReserveIDs returns the card IDs the player currently holds in reserve.
func (p *PlayerState) ReserveIDs() []string {
	ids := make([]string, 0, len(p.Reserve))
	for _, r := range p.Reserve {
		ids = append(ids, r.CardID)
	}
	return ids
}

// RemoveFromReserve drops a card from the reserve, reporting whether it was there.
func (p *PlayerState) RemoveFromReserve(cardID string) bool {
	for i, r := range p.Reserve {
		if r.CardID == cardID {
			p.Reserve = append(p.Reserve[:i], p.Reserve[i+1:]...)
			return true
		}
	}
	return false
}

// MatchState is the full authoritative game state. It lives only in the match
// handler's memory and in per-viewer projections.
type MatchState struct {
	Phase   GamePhase     `json:"phase"`
	Players []PlayerState `json:"players"`

	CurrentTurn int `json:"currentTurn"` // index into Players
	TurnNumber  int `json:"turnNumber"`  // 1-based count of turns started in the match

	Tier1Deck    []string `json:"-"` // draw piles never leave the server
	Tier2Deck    []string `json:"-"`
	Tier3Deck    []string `json:"-"`
	Tier1Visible []string `json:"tier1Visible"`
	Tier2Visible []string `json:"tier2Visible"`
	Tier3Visible []string `json:"tier3Visible"`

	Supply       Cost       `json:"supply"`
	AetherSupply int        `json:"aetherSupply"`
	Artifacts    []Artifact `json:"artifacts"`

	WinThresholdVal int  `json:"winThreshold"`
	Rated           bool `json:"rated"`

	WinnerIndex int       `json:"winnerIndex"` // -1 = shared, -2 = not ended
	EndReason   EndReason `json:"endReason,omitempty"`

	// Turn clock. Milliseconds are canonical; the seconds field stays for the
	// published client contract. Both are 0 before the first turn begins.
	TurnDeadlineMs   int64 `json:"turnDeadlineMs"`
	TurnDeadlineUnix int64 `json:"turnDeadlineUnix"`

	// LobbyDeadlineMs bounds the waiting phase so a player who never connects
	// cannot strand the rest of the table in an unfinishable match.
	LobbyDeadlineMs int64 `json:"lobbyDeadlineMs"`

	// AIThinkUntilMs is when the bot on turn is allowed to move. A bot that
	// answers instantly reads as a script rather than an opponent.
	AIThinkUntilMs int64 `json:"-"`

	StartedAtUnix       int64  `json:"startedAtUnix"`
	ExpectedPlayerCount int    `json:"expectedPlayerCount"`
	HostUserID          string `json:"hostUserId"`

	// ReadyCheck enables the pre-game ready check: on for matchmaker and
	// private matches, off for a single-player AI match, which has nobody to
	// wait for.
	ReadyCheck bool `json:"readyCheck"`

	// FirstSeat is the seat that opens the game, -1 until chosen. Online
	// matches draw it from the match RNG at start unless it is already set;
	// the final round is measured from it (see AdvanceTurn).
	FirstSeat int `json:"firstSeat"`

	// Seed is the match RNG's seed, logged at creation so a match can be
	// replayed: with the same seed and the same sequence of events the deal,
	// the bot names and the first seat all come out the same.
	Seed int64 `json:"seed"`

	// presences maps userID to the live socket presence, so the handler can
	// address one player instead of broadcasting private state to the table.
	presences map[string]runtime.Presence
	rng       *rand.Rand

	// removed holds users the ready check took out of this match, so they
	// cannot walk back in through a refill seat. refillClaims holds searchers
	// admitted by MatchJoinAttempt for an open seat but not yet joined, valued
	// by the claim time in ms, so two searchers cannot both take one seat.
	removed      map[string]bool
	refillClaims map[string]int64

	// nobleChoice is the noble the player on turn asked for with their move
	// ("artifactId" in the action payload), used when they qualify for
	// several at once. Cleared at the end of every turn; never serialised.
	nobleChoice string

	// lastLabel is the match label last published, so it is only re-sent
	// when it changes.
	lastLabel string

	// Public marks an online table that fills over time (public_tables.go);
	// botArrivals are the moments the remaining seats get a persona.
	Public      bool `json:"public,omitempty"`
	botArrivals []int64
}

// newSeed draws a per-match seed from the OS entropy source, falling back to
// the shared global source if that read ever fails.
func newSeed() int64 {
	var b [8]byte
	if _, err := cryptorand.Read(b[:]); err != nil {
		return rand.Int63()
	}
	return int64(binary.LittleEndian.Uint64(b[:]))
}

// newRNG returns a generator with a fresh random seed.
func newRNG() *rand.Rand { return rand.New(rand.NewSource(newSeed())) }

// NewMatchState builds and shuffles the initial game state (GDD v2 §5.2).
// playerCount drives the coin supply and artifact count; seats may be filled
// later, which is how the private-lobby path works.
func NewMatchState(playerUserIDs []string, playerNames []string, rated bool, playerCount int) *MatchState {
	return NewMatchStateSeeded(playerUserIDs, playerNames, rated, playerCount, newSeed())
}

// NewMatchStateSeeded is NewMatchState with a fixed RNG seed, for replays and
// tests. Everything random in a match is drawn from this one generator.
func NewMatchStateSeeded(playerUserIDs []string, playerNames []string, rated bool, playerCount int, seed int64) *MatchState {
	if playerCount <= 0 {
		playerCount = len(playerUserIDs)
	}

	ms := &MatchState{
		Phase:               PhaseWaiting,
		WinThresholdVal:     WinThreshold,
		Rated:               rated,
		WinnerIndex:         -2,
		ExpectedPlayerCount: playerCount,
		FirstSeat:           -1,
		Seed:                seed,
		presences:           make(map[string]runtime.Presence),
		rng:                 rand.New(rand.NewSource(seed)),
	}

	t1, t2, t3 := splitByTier(AllCards)
	ms.shuffleCards(t1)
	ms.shuffleCards(t2)
	ms.shuffleCards(t3)

	ms.Tier1Visible, ms.Tier1Deck = cardIDs(t1[:4]), cardIDs(t1[4:])
	ms.Tier2Visible, ms.Tier2Deck = cardIDs(t2[:4]), cardIDs(t2[4:])
	ms.Tier3Visible, ms.Tier3Deck = cardIDs(t3[:4]), cardIDs(t3[4:])

	ms.applyPlayerCount(playerCount)

	ms.Players = make([]PlayerState, len(playerUserIDs))
	for i, uid := range playerUserIDs {
		name := ""
		if i < len(playerNames) {
			name = playerNames[i]
		}
		ms.Players[i] = newPlayerState(uid, name)
	}

	return ms
}

func newPlayerState(userID, displayName string) PlayerState {
	return PlayerState{
		UserID:       userID,
		DisplayName:  displayName,
		Coins:        Cost{},
		HiredCards:   []CharacterCard{},
		Reserve:      []ReserveSlot{},
		Artifacts:    []string{},
		Disconnected: true, // cleared in MatchJoin once the socket actually arrives
	}
}

// GemsPerColor is the bank of each colour: Splendor's 4, 5 and 7 for 2 to 4
// players, and for the Iranian 5- and 6-player table (friends' rooms) 8 and 9.
func GemsPerColor(playerCount int) int {
	switch playerCount {
	case 2:
		return 4
	case 3:
		return 5
	case 5:
		return 8
	case 6:
		return 9
	}
	return 7
}

// GoldSupply is the gold in the bank: 5, and one more for each player past 4.
func GoldSupply(playerCount int) int {
	if playerCount > 4 {
		return 5 + playerCount - 4
	}
	return 5
}

// applyPlayerCount sets the coin supply and reveals players+1 artifacts.
// Safe to call again once the real player count is known (GDD v2 §5.2).
func (ms *MatchState) applyPlayerCount(playerCount int) {
	ms.Supply = Cost{}
	for _, e := range AllElements {
		ms.Supply[e] = GemsPerColor(playerCount)
	}
	ms.AetherSupply = GoldSupply(playerCount)

	arts := make([]Artifact, len(AllArtifacts))
	copy(arts, AllArtifacts)
	ms.shuffleArtifacts(arts)
	reveal := playerCount + 1
	if reveal > len(arts) {
		reveal = len(arts)
	}
	ms.Artifacts = arts[:reveal]
}

// Start moves the match to playing with FirstSeat on turn. Choosing that seat
// is the caller's job (see startGame); an unset FirstSeat opens at seat 0.
func (ms *MatchState) Start(nowMs int64) {
	ms.Phase = PhasePlaying
	ms.CurrentTurn = ms.firstSeat()
	ms.StartedAtUnix = nowMs / 1000
	ms.LobbyDeadlineMs = 0
}

// firstSeat returns the seat that opened (or will open) the game, treating an
// unset or out-of-range choice as seat 0.
func (ms *MatchState) firstSeat() int {
	if ms.FirstSeat < 0 || ms.FirstSeat >= len(ms.Players) {
		return 0
	}
	return ms.FirstSeat
}

// SeatOf returns the seat index for a user, or -1. An empty ID never matches,
// so an open seat (which has no user) is never mistaken for an observer.
func (ms *MatchState) SeatOf(userID string) int {
	if userID == "" {
		return -1
	}
	for i := range ms.Players {
		if ms.Players[i].UserID == userID {
			return i
		}
	}
	return -1
}

// ActivePlayerCount counts players who have neither conceded nor been auto-lost.
func (ms *MatchState) ActivePlayerCount() int {
	n := 0
	for i := range ms.Players {
		if !ms.Players[i].Conceded {
			n++
		}
	}
	return n
}

// SetTurnDeadline arms the turn clock. Both wire fields move together.
func (ms *MatchState) SetTurnDeadline(nowMs int64) {
	ms.TurnDeadlineMs = nowMs + int64(TurnSeconds)*1000
	ms.TurnDeadlineUnix = ms.TurnDeadlineMs / 1000
}

// ClearTurnDeadline disarms the clock, used once the match ends.
func (ms *MatchState) ClearTurnDeadline() {
	ms.TurnDeadlineMs, ms.TurnDeadlineUnix = 0, 0
}

// TurnExpired reports whether the active player is out of time. A short grace
// window absorbs network latency, so a player on a slow connection is not
// punished for an action that left their device before the deadline.
func (ms *MatchState) TurnExpired(nowMs int64) bool {
	if ms.TurnDeadlineMs == 0 {
		return false
	}
	return nowMs >= ms.TurnDeadlineMs+int64(TurnGraceSeconds)*1000
}

// AllVisibleCards returns every face-up card ID across the three tiers.
func (ms *MatchState) AllVisibleCards() []string {
	all := make([]string, 0, 12)
	all = append(all, ms.Tier1Visible...)
	all = append(all, ms.Tier2Visible...)
	all = append(all, ms.Tier3Visible...)
	return all
}

func (ms *MatchState) deckFor(tier int) *[]string {
	switch tier {
	case 1:
		return &ms.Tier1Deck
	case 2:
		return &ms.Tier2Deck
	case 3:
		return &ms.Tier3Deck
	}
	return nil
}

func (ms *MatchState) visibleFor(tier int) *[]string {
	switch tier {
	case 1:
		return &ms.Tier1Visible
	case 2:
		return &ms.Tier2Visible
	case 3:
		return &ms.Tier3Visible
	}
	return nil
}

// DeckCount reports how many cards remain face-down in a tier. This is the only
// deck information any client is allowed to see.
func (ms *MatchState) DeckCount(tier int) int {
	if d := ms.deckFor(tier); d != nil {
		return len(*d)
	}
	return 0
}

// TakeVisible removes a face-up card and refills the slot from its tier deck,
// preserving slot order so the board does not reshuffle itself under the player.
func (ms *MatchState) TakeVisible(cardID string) bool {
	card := cardByID[cardID]
	if card == nil {
		return false
	}
	visible, deck := ms.visibleFor(card.Tier), ms.deckFor(card.Tier)
	if visible == nil || deck == nil {
		return false
	}
	for i, id := range *visible {
		if id != cardID {
			continue
		}
		if len(*deck) > 0 {
			(*visible)[i] = (*deck)[0]
			*deck = (*deck)[1:]
		} else {
			*visible = append((*visible)[:i], (*visible)[i+1:]...)
		}
		return true
	}
	return false
}

// DrawBlindFromTier takes the top card of a tier deck, or "" when it is empty.
func (ms *MatchState) DrawBlindFromTier(tier int) string {
	deck := ms.deckFor(tier)
	if deck == nil || len(*deck) == 0 {
		return ""
	}
	id := (*deck)[0]
	*deck = (*deck)[1:]
	return id
}

// AdvanceTurn passes play to the next player still in the game and reports
// whether that ends the match.
//
// The final round is over when play wraps back round to the seat that opened
// the game (FirstSeat, drawn at random for online matches), which is what
// "everyone has had the same number of turns" means. Deriving it from the wrap
// rather than from the seat that triggered the threshold is what makes it
// correct when the trigger player later concedes, and stops earlier seats
// collecting a free extra turn.
func (ms *MatchState) AdvanceTurn() bool {
	total := len(ms.Players)
	if total == 0 {
		return true
	}
	if ms.ActivePlayerCount() == 0 {
		return true
	}

	// Count positions from the opening seat, so "wrapped" means play has come
	// back round to it.
	first := ms.firstSeat()
	rel := (ms.CurrentTurn - first + total) % total
	wrapped := false
	for i := 1; i <= total; i++ {
		raw := rel + i
		next := (first + raw) % total
		if !ms.Players[next].Conceded {
			wrapped = raw >= total
			ms.CurrentTurn = next
			break
		}
	}

	if ms.Phase == PhaseFinalRound && wrapped {
		return true
	}
	return false
}

// CheckWinTrigger reports whether a seat has reached the Power threshold.
func (ms *MatchState) CheckWinTrigger(seat int) bool {
	p := &ms.Players[seat]
	return PlayerPower(p.HiredCards, len(p.Artifacts)) >= ms.WinThresholdVal
}

// HasLegalAction reports whether a seat can make any legal move at all.
//
// Under the coin-limit house rule a player sitting on 10 coins with a full
// reserve and nothing affordable has no legal action: Harvest and Channel are
// blocked by coin_limit, Jail by reserve_full, Hire by cannot_afford. The turn
// clock then passes such a player without charging a missed turn, and a bot
// passes at once (see passTurn).
func (ms *MatchState) HasLegalAction(seat int) bool {
	if seat < 0 || seat >= len(ms.Players) {
		return false
	}
	p := &ms.Players[seat]

	// Harvest (and Channel, which needs strictly more): one coin of room and
	// any colour left in the supply.
	if CoinRoom(p.Coins) > 0 {
		for _, e := range AllElements {
			if ms.Supply[e] > 0 {
				return true
			}
		}
	}

	// Hire: any face-up or reserved card the player can pay for.
	bonus := AffinityBonus(p.HiredCards)
	visible := ms.AllVisibleCards()
	for _, id := range append(visible, p.ReserveIDs()...) {
		if c := cardByID[id]; c != nil && CanAfford(p.Coins, CalculateActualCost(c.HireCost, bonus)) {
			return true
		}
	}

	// Jail: room in the reserve and a card to take, face-up or blind.
	if len(p.Reserve) < MaxReserve {
		if len(visible) > 0 || ms.DeckCount(1)+ms.DeckCount(2)+ms.DeckCount(3) > 0 {
			return true
		}
	}
	return false
}

// NobodyCanAct reports whether every player still in the game is without a
// legal action. Nothing can change the position after that, so the match must
// end rather than pass turns forever.
func (ms *MatchState) NobodyCanAct() bool {
	for i := range ms.Players {
		if !ms.Players[i].Conceded && ms.HasLegalAction(i) {
			return false
		}
	}
	return true
}

// ---------- presence registry ----------

func (ms *MatchState) trackPresence(p runtime.Presence) {
	if ms.presences == nil {
		ms.presences = make(map[string]runtime.Presence)
	}
	ms.presences[p.GetUserId()] = p
}

func (ms *MatchState) dropPresence(userID string) {
	delete(ms.presences, userID)
}

func (ms *MatchState) presenceOf(userID string) (runtime.Presence, bool) {
	p, ok := ms.presences[userID]
	return p, ok
}

// ---------- helpers ----------

func (ms *MatchState) shuffleCards(cards []CharacterCard) {
	ms.rng.Shuffle(len(cards), func(i, j int) { cards[i], cards[j] = cards[j], cards[i] })
}

func (ms *MatchState) shuffleArtifacts(arts []Artifact) {
	ms.rng.Shuffle(len(arts), func(i, j int) { arts[i], arts[j] = arts[j], arts[i] })
}

func splitByTier(cards []CharacterCard) (t1, t2, t3 []CharacterCard) {
	for _, c := range cards {
		switch c.Tier {
		case 1:
			t1 = append(t1, c)
		case 2:
			t2 = append(t2, c)
		case 3:
			t3 = append(t3, c)
		}
	}
	return
}

func cardIDs(cards []CharacterCard) []string {
	ids := make([]string, len(cards))
	for i, c := range cards {
		ids[i] = c.ID
	}
	return ids
}

// ToJSON is used for logs and tests only. Never send it to a client: use
// match_view.go, which strips the draw piles and opponents' reserved cards.
func (ms *MatchState) ToJSON() ([]byte, error) { return json.Marshal(ms) }
