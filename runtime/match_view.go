package main

// match_view.go — the only path by which game state reaches a client.
//
// The authoritative MatchState holds information no player is entitled to see:
// the ordered draw piles, and the cards sitting in other players' reserves.
// Broadcasting the raw state would hand a modified client the entire future of
// the game, so every outbound state message is built here, per viewer.
//
// Hidden from everyone:
//   - draw pile contents and order (clients get counts only)
//
// Hidden from everyone but the owner:
//   - which cards are in a player's reserve (opponents get tier and count)
//
// Reserved cards are hidden even when taken face-up from the board. Splendor
// treats a board reservation as public, but this game does not: a reserve is
// private, which keeps the Jail action a genuine bluff and means the wire format
// never carries a reserved card ID to anyone but its owner.

// PlayerView is one player as seen by a particular viewer.
type PlayerView struct {
	UserID       string          `json:"userId"`
	DisplayName  string          `json:"displayName"`
	AvatarID     string          `json:"avatarId"`
	Seat         int             `json:"seat"`
	Coins        Cost            `json:"coins"`
	CoinTotal    int             `json:"coinTotal"`
	HiredCards   []CharacterCard `json:"hiredCards"`
	Affinity     Cost            `json:"affinity"`
	Power        int             `json:"power"`
	Artifacts    []string        `json:"artifacts"`
	Reserve      []ReserveSlot   `json:"reserve"` // CardID present only when IsSelf
	ReserveCount int             `json:"reserveCount"`
	MissedTurns  int             `json:"missedTurns"`
	Disconnected bool            `json:"disconnected"`
	Conceded     bool            `json:"conceded"`
	TurnsTaken   int             `json:"turnsTaken"`
	IsSelf       bool            `json:"isSelf"`
	IsAI         bool            `json:"isAI"`
	Rating       int             `json:"rating,omitempty"`
	AIDifficulty string          `json:"aiDifficulty,omitempty"`

	// Ready check. Ready is meaningful while phase is readyCheck; SeatOpen
	// marks a seat being held for a replacement (no user yet).
	Ready    bool `json:"ready"`
	SeatOpen bool `json:"seatOpen"`
}

// StateView is the payload of STATE_FULL (op 100).
type StateView struct {
	Phase       GamePhase    `json:"phase"`
	Players     []PlayerView `json:"players"`
	YourSeat    int          `json:"yourSeat"` // -1 for a spectator or unseated socket
	CurrentTurn int          `json:"currentTurn"`
	TurnNumber  int          `json:"turnNumber"`

	Tier1Visible []string `json:"tier1Visible"`
	Tier2Visible []string `json:"tier2Visible"`
	Tier3Visible []string `json:"tier3Visible"`
	Tier1Count   int      `json:"tier1Count"`
	Tier2Count   int      `json:"tier2Count"`
	Tier3Count   int      `json:"tier3Count"`

	Supply       Cost       `json:"supply"`
	AetherSupply int        `json:"aetherSupply"`
	Artifacts    []Artifact `json:"artifacts"`

	WinThreshold int  `json:"winThreshold"`
	Rated        bool `json:"rated"`

	// Clock. ServerNowMs lets the client render an accurate countdown without
	// trusting its own wall clock: remaining = turnDeadlineMs - serverNowMs.
	TurnDeadlineMs   int64 `json:"turnDeadlineMs"`
	TurnDeadlineUnix int64 `json:"turnDeadlineUnix"`
	LobbyDeadlineMs  int64 `json:"lobbyDeadlineMs,omitempty"`
	ServerNowMs      int64 `json:"serverNowMs"`
	TurnSeconds      int   `json:"turnSeconds"`

	ExpectedPlayerCount int       `json:"expectedPlayerCount"`
	WinnerIndex         int       `json:"winnerIndex"`
	EndReason           EndReason `json:"endReason,omitempty"`

	// ReadyDeadlineMs is the countdown of the ready check (the latest pending
	// seat deadline), present only while phase is readyCheck. FirstSeat is
	// the seat that opened the game, -1 until it starts.
	ReadyDeadlineMs int64 `json:"readyDeadlineMs,omitempty"`
	FirstSeat       int   `json:"firstSeat"`
}

// ViewFor projects the authoritative state for one viewer. Pass an empty
// viewerID for an observer, who then sees exactly what an opponent would.
func (ms *MatchState) ViewFor(viewerID string, nowMs int64) StateView {
	seat := ms.SeatOf(viewerID)

	players := make([]PlayerView, len(ms.Players))
	for i := range ms.Players {
		players[i] = ms.playerView(i, i == seat)
	}

	view := StateView{
		Phase:        ms.Phase,
		Players:      players,
		YourSeat:     seat,
		CurrentTurn:  ms.CurrentTurn,
		TurnNumber:   ms.TurnNumber,
		Tier1Visible: ms.Tier1Visible,
		Tier2Visible: ms.Tier2Visible,
		Tier3Visible: ms.Tier3Visible,
		Tier1Count:   ms.DeckCount(1),
		Tier2Count:   ms.DeckCount(2),
		Tier3Count:   ms.DeckCount(3),
		Supply:       ms.Supply,
		AetherSupply: ms.AetherSupply,
		Artifacts:    ms.Artifacts,
		WinThreshold: ms.WinThresholdVal,
		Rated:        ms.Rated,

		TurnDeadlineMs:   ms.TurnDeadlineMs,
		TurnDeadlineUnix: ms.TurnDeadlineUnix,
		LobbyDeadlineMs:  ms.LobbyDeadlineMs,
		ServerNowMs:      nowMs,
		TurnSeconds:      TurnSeconds,

		ExpectedPlayerCount: ms.ExpectedPlayerCount,
		WinnerIndex:         ms.WinnerIndex,
		EndReason:           ms.EndReason,
		FirstSeat:           -1,
	}
	if ms.Phase == PhaseReadyCheck {
		view.ReadyDeadlineMs = readyStateMessage(ms, nowMs).DeadlineMs
	}
	if ms.Phase == PhasePlaying || ms.Phase == PhaseFinalRound || (ms.Phase == PhaseEnded && ms.StartedAtUnix > 0) {
		view.FirstSeat = ms.firstSeat()
	}
	return view
}

func (ms *MatchState) playerView(seat int, isSelf bool) PlayerView {
	p := &ms.Players[seat]

	reserve := make([]ReserveSlot, len(p.Reserve))
	for i, slot := range p.Reserve {
		if isSelf {
			reserve[i] = ReserveSlot{CardID: slot.CardID, Tier: slot.Tier, FromBoard: slot.FromBoard}
			continue
		}
		// Opponent view: the tier is public (the card physically came off a
		// known deck) but the identity never is.
		reserve[i] = ReserveSlot{Tier: slot.Tier, FromBoard: slot.FromBoard}
	}

	return PlayerView{
		UserID:       p.UserID,
		DisplayName:  p.DisplayName,
		AvatarID:     p.AvatarID,
		Seat:         seat,
		Coins:        p.Coins,
		CoinTotal:    TotalCoins(p.Coins),
		HiredCards:   p.HiredCards,
		Affinity:     AffinityBonus(p.HiredCards),
		Power:        PlayerPower(p.HiredCards, len(p.Artifacts)),
		Artifacts:    p.Artifacts,
		Reserve:      reserve,
		ReserveCount: len(p.Reserve),
		MissedTurns:  p.MissedTurns,
		Disconnected: p.Disconnected,
		Conceded:     p.Conceded,
		TurnsTaken:   p.TurnsTaken,
		IsSelf:       isSelf,
		IsAI:         p.IsAI && !p.Persona,
		Rating:       p.Rating,
		AIDifficulty: personaHidden(p),
		Ready:        p.Ready && !p.SeatOpen,
		SeatOpen:     p.SeatOpen,
	}
}
