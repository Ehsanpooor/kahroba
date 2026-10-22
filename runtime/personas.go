package main

import (
	"context"
	"fmt"
	"hash/fnv"
	"math/rand"
	"sort"
	"sync"
	"time"

	"github.com/heroiclabs/nakama-common/runtime"
)

// personas.go — the regular players of the public tables.
//
// A persona is a real Nakama account (made at module start, never logged in)
// with a Persian name, a portrait, a rating and a skill. When a public table
// has room and nobody else is searching, personas take the seats one by one,
// get ready like anyone else, think like a person (a quick move takes a few
// seconds, a hard decision up to most of the clock) and are rated like
// anyone else, so the leaderboard and the ratings stay one living pool.
//
// Inside the match a persona seat is an AI seat (IsAI) with Persona set: it
// plays through the same validated messages as every bot, but the view sent
// to clients shows it as a player.

type persona struct {
	Key        string // stable id: the custom auth id is "persona-" + Key
	Name       string
	Skill      AIDifficulty
	BaseRating int
	Avatar     string
	UserID     string // filled at start
}

// The names: about half in Persian script, half the Latin handles Iranian
// players use.
var personaNames = []string{
	"سارا", "محمدرضا", "نگار", "امیرحسین", "مهسا", "پویا", "الناز", "آرمان", "شقایق", "سینا",
	"فاطمه", "حمید", "زهرا", "کیان", "مریم", "بهراد", "نیلوفر", "رضا", "یاسمن", "مهدی",
	"پرستو", "عرفان", "هانیه", "میلاد", "ساناز", "علیرضا", "ترانه", "پارسا", "مینا", "حسین",
	"آیدا", "امید", "رها", "فرهاد", "نازنین", "بابک",
	"reza_kh", "Mahsa.R", "amir1375", "Negin_m", "hamed.gh", "SaraZ", "ali_77", "Parisa.k",
	"mohsen_t", "Shayan99", "Yasi_jj", "Kian.dev", "Behnaz_s", "arash.b", "MiladZ", "Nima1378",
	"zahra.e", "Pedram_x", "Elham.nz", "Sepehr7", "Tina_g", "Mehran.v", "Roya.m", "Farzad_k",
	"Hasti", "Omid.h", "Navid_r", "Ghazal.s", "kamyar", "Donya_a", "Siavash.f", "Mona_t",
	"Ehsan.j", "Setareh_m", "Hooman.p", "Atena",
}

// avatarUnlocks mirrors the client (Portraits.UNLOCKS): the portraits a
// player of a given rating has opened.
var avatarUnlocks = [][2]int{{0, 10}, {1100, 13}, {1200, 16}, {1400, 20}, {1600, 25}, {2000, 30}}

func openAvatars(rating int) int {
	n := 10
	for _, u := range avatarUnlocks {
		if rating >= u[0] {
			n = u[1]
		}
	}
	return n
}

var (
	personas     []*persona
	personaMu    sync.Mutex
	personaBusy  = map[string]string{} // userID -> matchID it is seated in
	personaReady bool
)

func hashOf(s string) uint32 {
	h := fnv.New32a()
	_, _ = h.Write([]byte(s))
	return h.Sum32()
}

// buildPersonas makes the roster (deterministic: the same names always get
// the same skill, rating and portrait).
func buildPersonas() []*persona {
	out := make([]*persona, 0, len(personaNames))
	for i, name := range personaNames {
		key := fmt.Sprintf("p%02d", i+1)
		r := rand.New(rand.NewSource(int64(hashOf(key + name))))
		var skill AIDifficulty
		var rating int
		switch roll := r.Intn(100); {
		case roll < 40:
			skill, rating = AINormal, 960+r.Intn(220)
		case roll < 80:
			skill, rating = AIHard, 1120+r.Intn(260)
		default:
			skill, rating = AIVeryHard, 1300+r.Intn(320)
		}
		avatar := fmt.Sprintf("A-%02d", 1+r.Intn(openAvatars(rating)))
		out = append(out, &persona{Key: key, Name: name, Skill: skill, BaseRating: rating, Avatar: avatar})
	}
	return out
}

// initPersonas creates (or finds) every persona's account, sets its name and
// portrait, and gives a new one its starting rating. Runs once at start.
func initPersonas(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule) {
	list := buildPersonas()
	made := 0
	for _, p := range list {
		uid, _, created, err := nk.AuthenticateCustom(ctx, "persona-"+p.Key+"-splendor", "", true)
		if err != nil {
			logger.Warn("persona %s: account failed: %v", p.Key, err)
			continue
		}
		p.UserID = uid
		meta := &accountMetadata{AvatarID: p.Avatar, Onboarded: true}
		if m, err := metadataMap(meta); err == nil {
			_ = nk.AccountUpdateId(ctx, uid, "", m, p.Name, "", "", "", "")
		}
		if created {
			made++
			prof := &ratingProfile{Rating: p.BaseRating, GamesPlayed: 20 + int(hashOf(p.Key)%140)}
			prof.Wins = prof.GamesPlayed * (35 + int(hashOf(p.Name)%30)) / 100
			prof.Losses = prof.GamesPlayed - prof.Wins
			if err := writeRatingProfile(ctx, nk, uid, prof); err != nil {
				logger.Warn("persona %s: rating failed: %v", p.Key, err)
			}
			writeLeaderboard(ctx, logger, nk, uid, p.Name, p.Avatar, prof.Rating)
		}
	}
	personaMu.Lock()
	personas = list
	personaReady = true
	personaMu.Unlock()
	logger.Info("personas ready: %d (%d new)", len(list), made)
}

// pickPersona chooses a free persona for a table whose players are rated
// around `near`, preferring a close rating, and marks it busy.
func pickPersona(near int, matchID string, rng *rand.Rand, avoid map[string]bool) *persona {
	personaMu.Lock()
	defer personaMu.Unlock()
	if !personaReady {
		return nil
	}
	type cand struct {
		p    *persona
		dist int
	}
	cands := make([]cand, 0, len(personas))
	for _, p := range personas {
		if p.UserID == "" {
			continue
		}
		if _, busy := personaBusy[p.UserID]; busy {
			continue
		}
		if avoid[p.Avatar] {
			continue // someone at the table already wears this face
		}
		d := p.BaseRating - near
		if d < 0 {
			d = -d
		}
		cands = append(cands, cand{p, d + rng.Intn(160)})
	}
	if len(cands) == 0 {
		return nil
	}
	sort.Slice(cands, func(i, j int) bool { return cands[i].dist < cands[j].dist })
	top := 6
	if len(cands) < top {
		top = len(cands)
	}
	p := cands[rng.Intn(top)].p
	personaBusy[p.UserID] = matchID
	return p
}

// releasePersonas frees every persona seated in a match that has ended.
func releasePersonas(ms *MatchState) {
	personaMu.Lock()
	defer personaMu.Unlock()
	for i := range ms.Players {
		if ms.Players[i].Persona {
			delete(personaBusy, ms.Players[i].UserID)
		}
	}
}

func releasePersona(userID string) {
	personaMu.Lock()
	delete(personaBusy, userID)
	personaMu.Unlock()
}

// newPersonaPlayer seats a persona: an AI seat that looks like a player.
func newPersonaPlayer(ctx context.Context, nk runtime.NakamaModule, p *persona) PlayerState {
	pl := newPlayerState(p.UserID, p.Name)
	pl.IsAI = true
	pl.Persona = true
	pl.AIDifficulty = string(p.Skill)
	pl.AvatarID = p.Avatar
	pl.Disconnected = false
	pl.Rating = p.BaseRating
	if nk != nil {
		if prof, err := readRatingProfile(ctx, nk, p.UserID); err == nil && prof != nil {
			pl.Rating = prof.Rating
		}
	}
	return pl
}

// ---------- the leaderboard ----------

// LeaderboardMinRating is the rating a player needs to be listed.
const LeaderboardMinRating = 1200

// writeLeaderboard lists a player at their rating, or takes them off the
// board when they are below the bar.
func writeLeaderboard(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule, userID, name, avatar string, rating int) {
	if rating < LeaderboardMinRating {
		_ = nk.LeaderboardRecordDelete(ctx, LeaderboardID, userID)
		return
	}
	if _, err := nk.LeaderboardRecordWrite(ctx, LeaderboardID, userID, name, int64(rating), 0,
		map[string]interface{}{"avatarId": avatar}, nil); err != nil {
		logger.Warn("leaderboard write failed for %s: %v", userID, err)
	}
}

// ---------- thinking like a person ----------

// humanThinkMs is how long a persona takes over a move: 7 to 35 seconds as a
// rule, now and then longer for a hard decision. Never close enough to the
// clock to time out.
func humanThinkMs(ms *MatchState, seat int, rng *rand.Rand) int64 {
	p := &ms.Players[seat]
	bonus := AffinityBonus(p.HiredCards)
	affordable, bestPts := 0, 0
	for _, id := range append(ms.AllVisibleCards(), p.ReserveIDs()...) {
		c := cardByID[id]
		if c == nil {
			continue
		}
		if CanAfford(p.Coins, CalculateActualCost(c.HireCost, bonus)) {
			affordable++
			if c.Power > bestPts {
				bestPts = c.Power
			}
		}
	}
	endgame := false
	for i := range ms.Players {
		if PlayerPower(ms.Players[i].HiredCards, len(ms.Players[i].Artifacts)) >= ms.WinThresholdVal-4 {
			endgame = true
		}
	}
	between := func(lo, hi float64) float64 { return lo + rng.Float64()*(hi-lo) }

	// Most moves take 7 to 35 seconds, nearer the low end when the move is
	// plain and nearer the top when there is a real choice. Now and then a
	// hard decision runs longer (up to about 80 s). Never under 7 s.
	var s float64
	switch {
	case p.TurnsTaken < 2:
		s = between(7, 16) // the opening: everyone takes gems
	case affordable > 0 && bestPts >= 3:
		s = between(7, 18) // a fine card is right there
	default:
		s = between(10, 26)
	}
	if affordable >= 2 {
		s += between(2, 9) // which one to buy?
	}
	if endgame {
		s += between(3, 10) // every point matters now
	}
	if TotalCoins(p.Coins) >= 8 {
		s += between(1, 5) // careful with the token limit
	}
	if s > 35 {
		s = between(28, 35)
	}
	// a long hesitation over a hard decision, more likely late in the game
	long := 4
	if endgame || affordable >= 2 {
		long = 12
	}
	if rng.Intn(100) < long {
		s = between(40, 80)
	}
	limit := float64(TurnSeconds) - 7
	if s > limit {
		s = limit - rng.Float64()*4
	}
	return int64(s*1000) * int64(PersonaTimePercent) / 100
}

// personaReadyDelay is how long a persona takes to press Ready.
func personaReadyDelay(rng *rand.Rand) time.Duration {
	return time.Duration(1500+rng.Intn(8500)) * time.Millisecond
}

// personaHidden is the difficulty the view shows: none for a persona.
func personaHidden(p *PlayerState) string {
	if p.Persona {
		return ""
	}
	return p.AIDifficulty
}
