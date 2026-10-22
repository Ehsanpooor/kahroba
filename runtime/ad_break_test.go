package main

import (
	"encoding/json"
	"testing"

	"github.com/heroiclabs/nakama-common/runtime"
)

// ad_break_test.go — the online ad break between the ready check and the
// first turn (match_ready.go, docs/REMOTE_CONFIG_ADS_ANALYTICS.md §2).

// withAdBreak turns the pregame_online slot on (or off) for one test.
func withAdBreak(t *testing.T, on bool, maxSec int) {
	t.Helper()
	c := defaultClientConfig()
	c.Ads.Enabled = on
	c.Ads.Slots.PregameOnline.Enabled = on
	c.Ads.AdBreakMaxSec = maxSec
	withClientConfig(t, c)
}

func adDone(userID string) runtime.MatchData { return message(userID, OpAdDone, struct{}{}) }

func decodeAdBreak(t *testing.T, disp *mockDispatcher) msgAdBreak {
	t.Helper()
	b, ok := disp.lastOfOp(OpAdBreak)
	if !ok {
		t.Fatal("no AD_BREAK was sent")
	}
	var m msgAdBreak
	if err := json.Unmarshal(b.data, &m); err != nil {
		t.Fatalf("AD_BREAK did not decode: %v", err)
	}
	return m
}

// With the slot off nothing changes: the last READY starts the game.
func TestAdBreak_OffStartsAtOnce(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	withAdBreak(t, false, 30)
	const now = int64(1_000_000)
	ms, disp, tc := newReadyMatch(t, now, 7, "", "u0", "u1")
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0"), ready("u1")})
	if ms.Phase != PhasePlaying {
		t.Fatalf("phase = %q, want playing", ms.Phase)
	}
	if disp.countOfOp(OpAdBreak) != 0 || ms.AdBreakUntilMs != 0 {
		t.Error("an ad break was held with the slot off")
	}

	// ads on but this slot off: still no break
	c := defaultClientConfig()
	c.Ads.Enabled = true
	c.Ads.Slots.Postgame.Enabled = true
	withClientConfig(t, c)
	ms, disp, tc = newReadyMatch(t, now, 7, "", "u0", "u1")
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0"), ready("u1")})
	if ms.Phase != PhasePlaying || disp.countOfOp(OpAdBreak) != 0 {
		t.Error("the pregame_online slot is off, yet the game did not start at once")
	}
}

// Everyone ready: AD_BREAK goes out, and the game starts once every human
// has answered AD_DONE.
func TestAdBreak_StartsWhenEveryoneIsDone(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	withAdBreak(t, true, 30)
	const now = int64(1_000_000)
	ms, disp, tc := newReadyMatch(t, now, 7, "", "u0", "u1", "u2")

	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0"), ready("u1"), ready("u2")})
	if ms.Phase != PhaseReadyCheck {
		t.Fatalf("phase = %q right after everyone was ready, want the ad break", ms.Phase)
	}
	if ab := decodeAdBreak(t, disp); ab.DeadlineMs != now+30_000 {
		t.Errorf("AD_BREAK deadline = %d, want %d", ab.DeadlineMs, now+30_000)
	}
	if b, _ := disp.lastOfOp(OpAdBreak); b.recipient != "" {
		t.Error("AD_BREAK should go to the whole table")
	}
	if disp.countOfOp(OpGameStarted) != 0 {
		t.Fatal("GAME_STARTED before the ad break ended")
	}

	ms = runLoop(ms, tc.at(now+5_000), []runtime.MatchData{adDone("u0"), adDone("u0"), adDone("stranger")})
	ms = runLoop(ms, tc.at(now+6_000), []runtime.MatchData{adDone("u1")})
	if ms.Phase != PhaseReadyCheck {
		t.Fatalf("phase = %q with one seat still watching, want the ad break", ms.Phase)
	}
	ms = runLoop(ms, tc.at(now+7_000), []runtime.MatchData{adDone("u2")})
	if ms.Phase != PhasePlaying {
		t.Fatalf("phase = %q after every AD_DONE, want playing", ms.Phase)
	}
	if disp.countOfOp(OpGameStarted) != 1 || disp.countOfOp(OpAdBreak) != 1 {
		t.Errorf("GAME_STARTED x%d, AD_BREAK x%d; want one each", disp.countOfOp(OpGameStarted), disp.countOfOp(OpAdBreak))
	}

	// a late AD_DONE in play is ignored, never rejected
	disp.reset()
	ms = runLoop(ms, tc.at(now+8_000), []runtime.MatchData{adDone("u1")})
	if disp.countOfOp(OpActionRejected) != 0 {
		t.Error("a late AD_DONE was rejected")
	}
}

// Nobody answers: the game starts at the deadline.
func TestAdBreak_StartsAtTheDeadline(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	withAdBreak(t, true, 20)
	const now = int64(1_000_000)
	ms, _, tc := newReadyMatch(t, now, 7, "", "u0", "u1")
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0"), ready("u1")})
	ms = runLoop(ms, tc.at(now+5_000), []runtime.MatchData{adDone("u0")})

	ms = runLoop(ms, tc.at(now+19_999), nil)
	if ms.Phase != PhaseReadyCheck {
		t.Fatalf("phase = %q before the deadline, want the ad break", ms.Phase)
	}
	ms = runLoop(ms, tc.at(now+20_000), nil)
	if ms.Phase != PhasePlaying {
		t.Fatalf("phase = %q at the deadline, want playing", ms.Phase)
	}
	if ms.SeatOf("u1") != 1 {
		t.Error("a player who never sent AD_DONE lost the seat; only READY is required")
	}
}

// Bots never hold the break up: one human and a bot start on that human's
// AD_DONE alone.
func TestAdBreak_BotsAreAlwaysDone(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	withAdBreak(t, true, 30)
	const now = int64(1_000_000)
	ms, _, tc := newReadyMatch(t, now, 9, "host", "host", "friend")
	seatBot(ms, 1) // the friend's seat goes to a bot
	ms = runLoop(ms, tc, []runtime.MatchData{ready("host")})
	if ms.Phase != PhaseReadyCheck || ms.AdBreakUntilMs == 0 {
		t.Fatalf("phase = %q, break %d; want the ad break", ms.Phase, ms.AdBreakUntilMs)
	}
	ms = runLoop(ms, tc.at(now+1_000), []runtime.MatchData{adDone("host")})
	if ms.Phase != PhasePlaying {
		t.Fatalf("phase = %q, want playing once the only human is done", ms.Phase)
	}
}

// A player who leaves during the break is removed as in the ready check; in a
// friends' room a bot takes the seat and the others are not held up.
func TestAdBreak_LeaverInAPrivateRoom(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	withAdBreak(t, true, 30)
	const now = int64(1_000_000)
	ms, disp, tc := newReadyMatch(t, now, 9, "host", "host", "friend1", "friend2")
	ms = runLoop(ms, tc, []runtime.MatchData{ready("host"), ready("friend1"), ready("friend2")})
	ms = runLoop(ms, tc.at(now+1_000), []runtime.MatchData{adDone("host")})

	ms = handleLeave(ms, tc.at(now+2_000), []runtime.Presence{presenceFor("friend2")})
	if ms.SeatOf("friend2") >= 0 || !ms.Players[2].IsAI {
		t.Fatal("the leaver kept the seat")
	}
	if rm := lastRemoved(t, disp, "friend2"); rm.Reason != RemovedLeft {
		t.Errorf("leaver told %q, want %q", rm.Reason, RemovedLeft)
	}
	if ms.Phase != PhaseReadyCheck {
		t.Fatalf("phase = %q, want the break to go on for friend1", ms.Phase)
	}
	ms = runLoop(ms, tc.at(now+3_000), []runtime.MatchData{adDone("friend1")})
	if ms.Phase != PhasePlaying {
		t.Fatalf("phase = %q, want playing", ms.Phase)
	}
	if disp.countOfOp(OpAdBreak) != 1 {
		t.Errorf("AD_BREAK x%d, want 1", disp.countOfOp(OpAdBreak))
	}
}

// In an online table the leaver's seat opens for a searcher. The table waits
// for it as in the ready check, and starts without a second break.
func TestAdBreak_LeaverInAPublicTable(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	withAdBreak(t, true, 30)
	const now = int64(1_000_000)
	ms, disp, tc := newReadyMatch(t, now, 5, "", "u0", "u1", "u2")
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0"), ready("u1"), ready("u2")})
	ms = runLoop(ms, tc.at(now+1_000), []runtime.MatchData{adDone("u0"), adDone("u1")})

	ms = handleLeave(ms, tc.at(now+2_000), []runtime.Presence{presenceFor("u2")})
	if !ms.Players[2].SeatOpen {
		t.Fatal("the leaver's seat should be held open")
	}
	ms = runLoop(ms, tc.at(now+10_000), nil) // everyone left is done, but a seat is open
	if ms.Phase != PhaseReadyCheck {
		t.Fatalf("phase = %q with an open seat, want the ready check", ms.Phase)
	}

	// a searcher takes the seat: nobody waits for their ad, only their READY
	if ok, why := claimRefillSeat(ms, "u3", now+11_000); !ok {
		t.Fatalf("refill refused: %s", why)
	}
	ms = handleJoin(ms, tc.at(now+12_000), []runtime.Presence{presenceFor("u3")})
	if ms.SeatOf("u3") != 2 || !ms.Players[2].AdDone {
		t.Fatalf("seat 2 = %+v, want u3 seated and not waited for", ms.Players[2])
	}
	if disp.countOfOp(OpAdBreak) != 1 {
		t.Error("the newcomer was sent an ad break")
	}
	ms = runLoop(ms, tc.at(now+13_000), []runtime.MatchData{ready("u3")})
	if ms.Phase != PhasePlaying {
		t.Fatalf("phase = %q, want playing", ms.Phase)
	}
	if disp.countOfOp(OpAdBreak) != 1 {
		t.Errorf("AD_BREAK x%d, want 1", disp.countOfOp(OpAdBreak))
	}
}

// A player who reconnects during the break is told about it again.
func TestAdBreak_ReconnectHearsItAgain(t *testing.T) {
	withTimings(t, 90, 0)
	withReadyTimings(t, 120, 20)
	withAdBreak(t, true, 30)
	const now = int64(1_000_000)
	ms, disp, tc := newReadyMatch(t, now, 5, "", "u0", "u1")
	ms = runLoop(ms, tc, []runtime.MatchData{ready("u0"), ready("u1")})
	disp.reset()

	ms = handleJoin(ms, tc.at(now+3_000), []runtime.Presence{presenceFor("u1")})
	b, ok := disp.lastOfOp(OpAdBreak)
	if !ok || b.recipient != "u1" {
		t.Fatalf("AD_BREAK to the reconnecting player: %+v, %v", b, ok)
	}
	if ms.Phase != PhaseReadyCheck {
		t.Errorf("phase = %q, want the break to go on", ms.Phase)
	}
}
