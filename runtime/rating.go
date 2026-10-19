package main

import (
	"context"
	"encoding/json"
	"math"

	"github.com/heroiclabs/nakama-common/runtime"
)

const (
	RatingCollection   = "rating"
	RatingKey          = "profile"
	LeaderboardID      = "splendor_elo"
	DefaultRating      = 1000
	MinRating          = 100
	KFactorProvisional = 40.0
	KFactorStandard    = 20.0
)

type ratingProfile struct {
	Rating      int  `json:"rating"`
	GamesPlayed int  `json:"gamesPlayed"`
	Provisional bool `json:"provisional"`
	Wins        int  `json:"wins"`
	Losses      int  `json:"losses"`
	Draws       int  `json:"draws"`
}

func readRatingProfile(ctx context.Context, nk runtime.NakamaModule, userID string) (*ratingProfile, error) {
	objects, err := nk.StorageRead(ctx, []*runtime.StorageRead{
		{Collection: RatingCollection, Key: RatingKey, UserID: userID},
	})
	if err != nil {
		return nil, err
	}
	if len(objects) == 0 {
		return &ratingProfile{Rating: DefaultRating, Provisional: true}, nil
	}
	var p ratingProfile
	if err := json.Unmarshal([]byte(objects[0].GetValue()), &p); err != nil {
		return nil, err
	}
	return &p, nil
}

func writeRatingProfile(ctx context.Context, nk runtime.NakamaModule, userID string, p *ratingProfile) error {
	b, err := json.Marshal(p)
	if err != nil {
		return err
	}
	_, err = nk.StorageWrite(ctx, []*runtime.StorageWrite{
		{
			Collection:      RatingCollection,
			Key:             RatingKey,
			UserID:          userID,
			Value:           string(b),
			PermissionRead:  runtime.STORAGE_PERMISSION_PUBLIC_READ,
			PermissionWrite: runtime.STORAGE_PERMISSION_NO_WRITE,
		},
	})
	return err
}

func kFactor(p *ratingProfile) float64 {
	if p.Provisional {
		return KFactorProvisional
	}
	return KFactorStandard
}

// expectedScore is the standard Elo expectation for one player against one
// opponent.
func expectedScore(myRating, oppRating int) float64 {
	return 1.0 / (1.0 + math.Pow(10, float64(oppRating-myRating)/400.0))
}

// computeEloChange returns the rating delta for a single head-to-head result.
// k is the effective K-factor, already threshold-weighted.
func computeEloChange(myRating, oppRating int, won bool, k float64) int {
	actual := 0.0
	if won {
		actual = 1.0
	}
	return int(math.Round(k * (actual - expectedScore(myRating, oppRating))))
}

// applyRatingUpdates computes and persists Elo changes for a finished rated
// match, returning each player's delta for the history record.
//
// Scoring is pairwise on finishing position: every player is compared with
// every other, scoring 1 for finishing above them, 0.5 for level and 0 for
// below, and the results are averaged. Comparing only against the winner made
// the pool leak rating in 3 and 4 player games, because two losers each lost
// points to the other with nobody gaining them.
func applyRatingUpdates(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule, ms *MatchState, standings []Standing) map[string]int {
	// Only human seats are rated. A bot that replaced a no-show in the ready
	// check holds no account and no rating, so it is left out of the pairwise
	// comparison: the humans are rated on how they finished against each other.
	seats := make([]int, 0, len(ms.Players))
	for i := range ms.Players {
		if !ms.Players[i].IsAI && !ms.Players[i].SeatOpen && ms.Players[i].UserID != "" {
			seats = append(seats, i)
		}
	}
	n := len(seats)
	if n < 2 {
		return map[string]int{}
	}

	// Finishing position by seat, so the pairwise loop can read it directly.
	total := len(ms.Players)
	rankBySeat := make([]int, total)
	for i := range rankBySeat {
		rankBySeat[i] = total // a seat missing from standings finishes last
	}
	for _, s := range standings {
		if s.Index >= 0 && s.Index < total {
			rankBySeat[s.Index] = s.Rank
		}
	}

	profiles := make(map[int]*ratingProfile, n)
	for _, i := range seats {
		prof, err := readRatingProfile(ctx, nk, ms.Players[i].UserID)
		if err != nil {
			logger.Warn("applyRatingUpdates: read profile failed for %s: %v", ms.Players[i].UserID, err)
			prof = &ratingProfile{Rating: DefaultRating, Provisional: true}
		}
		profiles[i] = prof
	}

	// Threshold weighting: a race to 30 moves rating half as far as a race to
	// 15, since the longer game is a weaker signal per unit of time invested.
	weight := 1.0
	if ms.WinThresholdVal > 0 {
		weight = float64(WinThreshold) / float64(ms.WinThresholdVal)
	}

	deltas := make(map[int]int, n)
	for _, i := range seats {
		k := kFactor(profiles[i]) * weight
		sum := 0.0
		for _, j := range seats {
			if i == j {
				continue
			}
			actual := 0.0
			switch {
			case rankBySeat[i] < rankBySeat[j]:
				actual = 1.0
			case rankBySeat[i] == rankBySeat[j]:
				actual = 0.5
			}
			sum += k * (actual - expectedScore(profiles[i].Rating, profiles[j].Rating))
		}
		deltas[i] = int(math.Round(sum / float64(n-1)))
	}

	for _, i := range seats {
		pl := ms.Players[i]
		prof := profiles[i]

		prof.Rating += deltas[i]
		if prof.Rating < MinRating {
			prof.Rating = MinRating
		}
		prof.GamesPlayed++

		// The win/draw/loss record reads the whole table, bots included.
		switch {
		case sharedRank(rankBySeat, i):
			prof.Draws++
		case rankBySeat[i] == 1:
			prof.Wins++
		default:
			prof.Losses++
		}
		prof.Provisional = prof.GamesPlayed < ProvisionalGames

		if err := writeRatingProfile(ctx, nk, pl.UserID, prof); err != nil {
			logger.Warn("applyRatingUpdates: write profile failed for %s: %v", pl.UserID, err)
		}

		// Provisional accounts stay off the public board until they settle.
		if !prof.Provisional {
			if _, err := nk.LeaderboardRecordWrite(ctx, LeaderboardID, pl.UserID, pl.DisplayName, int64(prof.Rating), 0, map[string]interface{}{"avatarId": pl.AvatarID}, nil); err != nil {
				logger.Warn("applyRatingUpdates: leaderboard write failed for %s: %v", pl.UserID, err)
			}
		}
	}

	result := make(map[string]int, n)
	for _, i := range seats {
		result[ms.Players[i].UserID] = deltas[i]
	}
	return result
}

// sharedRank reports whether seat i finished level with anyone else.
func sharedRank(rankBySeat []int, i int) bool {
	for j := range rankBySeat {
		if j != i && rankBySeat[j] == rankBySeat[i] {
			return true
		}
	}
	return false
}
