# veynoria . the great muster — Backend Specification (Nakama)
> Version 1.0 — Companion to GAME_DESIGN_DOCUMENT.md (rules/content) and DEVELOPMENT_DOC.md (app/screens/online rules)
> This document owns the **backend**: server stack, Nakama configuration, custom Go modules, the authoritative match, matchmaking, rating, anti-cheat, and the full endpoint/RPC list.
> Single operator, AI-assisted (Cursor), self-hosted on the operator's own Linux server.

--- 

## TABLE OF CONTENTS

1. [Stack & Topology](#1-stack--topology)
2. [What Nakama Provides vs. What We Build](#2-what-nakama-provides-vs-what-we-build)
3. [Accounts, Identity & Metadata](#3-accounts-identity--metadata)
4. [Friends](#4-friends)
5. [Matchmaking — Public](#5-matchmaking--public)
6. [Private Lobbies](#6-private-lobbies)
7. [Authoritative Match (Rules Engine)](#7-authoritative-match-rules-engine)
8. [Turn Timer & Abandonment](#8-turn-timer--abandonment)
9. [Reconnection & "Continue Last Game"](#9-reconnection--continue-last-game)
10. [Rating Engine](#10-rating-engine)
11. [Leaderboard](#11-leaderboard)
12. [Match History & AI Result Sync](#12-match-history--ai-result-sync)
13. [Anti-Cheat](#13-anti-cheat)
14. [Push Notifications](#14-push-notifications)
15. [Storage Layout (Collections)](#15-storage-layout-collections)
16. [Endpoint & RPC Reference](#16-endpoint--rpc-reference)
17. [Match Message Protocol (Op Codes)](#17-match-message-protocol-op-codes)
18. [Configuration & Environment](#18-configuration--environment)
19. [Admin Console Usage](#19-admin-console-usage)
20. [Open Items / Deferred](#20-open-items--deferred)

---

## 1. STACK & TOPOLOGY

| Layer | Choice |
|---|---|
| Game backend server | **Nakama** (self-hosted) |
| Custom runtime language | **Go** (Nakama Go runtime modules) |
| Database | **PostgreSQL** (Nakama's own DB — accessed via Nakama storage/leaderboard/account APIs, not raw SQL except for analytics queries) |
| Cache / realtime | **None separate** — Nakama handles presence and live match state internally. **No Redis.** |
| Hosting | Operator's own Linux server (Docker). |
| Client | Flutter (Dart), Nakama Dart client SDK. |

**Authority:** All online game logic is **server-authoritative** inside a Nakama authoritative match handler. Clients send intent messages; the server validates against the rules engine and is the only source of truth for state and results. AI games run on-device and are unrated; only their *result* is synced for analytics and is treated as untrusted.

---

## 2. WHAT NAKAMA PROVIDES VS. WHAT WE BUILD

### Used as built-ins (little/no custom code)
- Authentication (device ID + optional email).
- User accounts + profile metadata.
- Friends (request / accept / decline / block).
- Leaderboards (stores Elo rating as score).
- Matchmaker (public queue).
- Realtime sockets, presence, match join/leave events.
- Notifications + push (FCM/APNs).
- Admin console (user/leaderboard/storage inspection, manual queries).

### Built custom (Go modules)
1. **Authoritative match handler** — the Splendor rules engine (the bulk of custom work).
2. **Turn timer + abandonment loop** on the match tick.
3. **Weighted-Elo rating computation** + provisional period, submitted at match end.
4. **One-game-at-a-time enforcement** (`activeMatchId` gate).
5. **Public matchmaker config** (group strictly by player count) + **private direct-create** flow.
6. **Anti-cheat result logging** + report queue.
7. **AI-result submission RPC** (analytics, unrated, untrusted).
8. **Profile bootstrap** (generation + avatar onboarding write).

---

## 3. ACCOUNTS, IDENTITY & METADATA

**Auth:** phone-first hybrid.
- First launch → **device authentication** (Nakama `authenticateDevice`) creates the account, bound to a device ID. **One account per device** (anti-cheat lever — see §13).
- Optional **email link + verification** (Nakama email auth linked to the same account) → enables **cross-device login**. Without it, the account is device-bound.

**Onboarding (must complete before first game):**
1. `displayName` (Nakama username/display name).
2. `generation` — 1 of 5, **cosmetic only**, changeable later.
3. `avatarId` — preset avatar reference.

**Account metadata (Nakama account `metadata` JSON):**
```
{
  "generation": "merfolk",        // cosmetic identity, no gameplay effect
  "avatarId": "preset_07",
  "onboarded": true,
  "activeMatchId": null           // set on online match join; gates new games
}
```

> `generation` and `avatarId` never touch game logic, matchmaking, or balance.

---

## 4. FRIENDS

Fully Nakama built-in. No custom logic beyond surfacing it in the app.
- Send request, accept, decline, remove, (block — deferred).
- Friend's online/in-game state read from Nakama presence (drives "can I invite them?" and offline-push fallback).
- Used by Private Lobby invites (§6) and the in-game "Add Friend" action (DEVELOPMENT_DOC M-Player).

---

## 5. MATCHMAKING — PUBLIC

**Engine:** Nakama built-in matchmaker.

**Active matching rule (this version): player count only.**
- Users searching for the same chosen player count (2 / 3 / 4) are matched together. A 2-seeker only matches other 2-seekers, etc.
- Implemented as a matchmaker **query/property**: `playerCount` is the only active matching property. `minCount`/`maxCount` are set to the chosen player count so the match only forms at exactly that size.

**Designed for extensibility:** the search is built so future rules (turn time, win threshold) slot in as **additional matchmaker properties** without restructuring. They are present but inactive now.

**Search timeout:** client withdraws from the matchmaker after **60 seconds** with no match ("ignore"/cancel), then offers retry or Play vs AI.

**Gate:** before entering the matchmaker, the server checks `activeMatchId == null` (§9). A user already in an online game cannot queue.

**On match found:** Nakama creates/joins an authoritative match (§7); server stamps `activeMatchId` on every joined player. The match opens with a **ready check** (§7.2); a matched player who does not confirm is replaced by the next searcher of the same `playerCount` (via `start_public_search`'s `refillMatchId`) or, after 20 s, by a Normal bot.

---

## 6. PRIVATE LOBBIES

**Flow:** host creates an authoritative match directly (not via matchmaker) → receives a match ID → invites friends.
- Invites are Nakama **notifications** carrying the match ID; delivered in-app if online, via **push** if offline (§14).
- Only invited friends can join (server checks invite list on join). No strangers.
- Once every seat has joined, the ready check runs (§7.2); a friend who does not confirm in time is replaced by a Normal bot, never by a stranger.
- **Private games are unrated.** The match is flagged `rated=false`; no leaderboard submission occurs (§10).
- Same `activeMatchId` gate applies to host and joiners.

---

## 7. AUTHORITATIVE MATCH (RULES ENGINE)

This is the core custom module: a Nakama **authoritative match handler** in Go that implements the GDD ruleset exactly. It mirrors the GDD's `cost_calculator` and `game_validator` logic — **the server is the only place these run for online play.**

**Match lifecycle (Nakama handler callbacks):**
- `MatchInit` — build authoritative initial state per GDD §3.2: shuffle the three tier decks, reveal 12 characters + artifacts, set coin supply by player count, set `winThreshold` (25 by default; an unrated private or AI game may choose 15, 20, 25 or 30 at creation, rated games never change it), `rated` flag, seat order.
- `MatchJoinAttempt` — enforce: invite list (private), `activeMatchId` rules, capacity; during a public ready check, admit a searcher to an open refill seat (§7.2).
- `MatchJoin` — seat the player, set `activeMatchId`, broadcast state; start the ready check when the last seat fills.
- `MatchLoop` (tick) — drive the ready check (§7.2), then the turn timer and abandonment checks (§8); process queued player action messages.
- `MatchLeave` — during the ready check, remove the seat (§7.2); once the game runs, mark disconnected (seat persists — §9), do **not** free the seat.
- `MatchTerminate` — finalize.

**Per-turn server validation (one action only, per GDD §3.3):**
- **Harvest 3** (1–3 different element coins), **Channel 2** (2 same, requires 4+ in supply), **Hire** (pay cost after affinity discount; Aether substitution), **Jail** (reserve a character, max 3, gain 1 Aether if the player is below 10 coins). Server rejects illegal actions; never trusts client math.
- **Coin limit (max 10, Aether included) is a hard block — a deliberate house rule, not Splendor's.** Official Splendor lets a player go over 10 and return the excess at end of turn; Veynoria rejects any Harvest or Channel that would exceed 10 with `coin_limit` (`ValidateHarvest` / `ValidateChannel` in `rules.go`). Jail at 10 is legal and grants no Aether (`ReserveGrantsAether`). There is no return step: op 5 `RETURN_COINS`, the `AwaitReturnCoins` state, `AutoReturnCoins` and the timer's auto-return were removed on 15 October 2026.
- **No legal move.** The block makes it possible, rarely, for a player to have no legal action (10 coins, full jail, nothing affordable; `MatchState.HasLegalAction`). A bot passes at once; a human's turn passes on the clock with **no missed turn charged** (`passTurn`). If every player still in the game is in that position the board is frozen for good, so the match ends with reason `stalemate` and is scored normally. This is reachable: in a 2-player game two boxed-in players can hold all 20 colour coins between them.
- End-of-turn server check: **automatic artifact claim** (GDD §3.3).
- Win detection: when a player reaches `winThreshold`, enter final round; all players finish; server computes winner (GDD §3.7 tiebreakers).

**State authority:** the full game state lives in the match handler's state object. Clients receive state via match messages (§17) and render only.

**Hidden information (enforced, not conventional).** The authoritative state is never broadcast as-is. Every outbound state message is a per-viewer projection built in `runtime/match_view.go`:
- **Draw piles are never sent to anyone** — clients get per-tier counts. Sending the ordered decks would tell a modified client every future card and blind draw.
- **Reserved cards are sent only to their owner** — opponents see the count and the tier, never the card ID. This is a deliberate departure from Splendor, where reserving a face-up card is public; here the Jail action stays a bluff.
- **Rejections and sync replies are addressed to one player**, using the presence registry held on the match state.

**End of the final round.** Reaching the threshold starts the final round; it does not end the game. The match ends when play wraps back round to the seat that opened the game (`FirstSeat`, random for online matches since 15 October 2026), which is what gives every player the same number of turns. It is deliberately *not* keyed to the seat that triggered the threshold, because that player may concede before play returns to them. The AI search state (`aiState.first`) measures the round the same way.

**Concession and abandonment never win.** Standings rank every player still in the game above every player who conceded or was auto-lost, whatever their Power (`ComputeStandings` in `runtime/rules.go`).

### 7.1 AI opponent

The bot occupies an ordinary seat. On its turn the match loop asks the engine for a move, encodes it as the op code a client would send, and posts it through the same `processMessage` validation path. There is no second rules implementation and no way for a tampered client to fabricate an AI result.

**It plays with the information a player has.** The server knows the deck order and every reserve; `buildAIState` discards both before the search runs. Hidden cards are re-dealt per simulation (Information Set MCTS), so the bot plans against a distribution of possible decks rather than the real one. A bot that peeked would play moves no human could explain, which reads as cheating long before it reads as strength.

**Search.** Information Set MCTS with progressive bias from a hand-written evaluation, a bootstrapped root so no move is dismissed on noise, and short heuristic rollouts. Published work on Splendor planning agents found the strongest configurations all converged on very short lookahead, because opponent choices and shuffling make longer plans noise; the strength therefore lives in the evaluation, which scores engine value, artifact proximity and estimated turns-to-buy rather than only current Power.

**Measured:** roughly 60,000 simulations per second, about 20,000 within the 320 ms Hard budget on one core. Under the coin-limit hard block (re-measured 15 October 2026): Normal and Hard beat uniformly random play 32-0 over 32 games, Easy 27-5 (it was 32-0 under the old take-then-return rule: with no search, Easy sometimes fills its hand to 10 coins and 3 reserved cards and is left passing); Normal beats Easy 39-1, Hard beats Easy 40-0, Hard beats Normal 36-4.

| Level | Perception | Search | Errs |
|---|---|---|---|
| Easy | ignores artifacts and does not plan ahead | none, heuristic only | picks among its best 3 moves; 18% random |
| Normal | full | 45 ms IS-MCTS | picks among its best 2; 5% random |
| Hard | full | 320 ms IS-MCTS | never |

Budgets are env-tunable: `AI_HARD_THINK_MS`, `AI_NORMAL_THINK_MS`.

> The rules engine must be specified to the AI coder as an exact port of GDD §3–§7 and §12. A server-side cost/validation error is a cheating vector — this module needs the most careful review and test coverage.

### 7.2 Ready check (added 15 October 2026)

Code: `runtime/match_ready.go`; tests: `runtime/ready_check_test.go`.

**Phases.** `waiting` → `readyCheck` → `playing` → `finalRound` → `ended`. A matchmaker match enters `readyCheck` in `MatchInit` (its seats arrive filled, so the window also covers connecting; the old `LOBBY_WAIT_SECONDS` cancel no longer applies to it). A private match enters it in `MatchJoin` when the last invited player sits down. An AI match (`create_ai_match`) has no ready check (`MatchState.ReadyCheck = false`), starts when its human connects, and the human (seat 0) opens.

**Rules.**
- Every human seat must send op 8 `READY` within `READY_TIMEOUT_SECONDS` (120). Each seat carries its own deadline (`PlayerState.ReadyDeadlineMs`), because a replacement gets a fresh window. Bots are ready on arrival.
- Every change is broadcast as op 107 `READY_STATE` (plus a fresh `STATE_FULL`, which carries `players[].ready`, `players[].seatOpen` and `readyDeadlineMs`).
- Game actions in the phase are rejected with `game_not_running`. `READY` is never rejected: from a non-member, repeated, or outside the phase it is a no-op.
- A human not ready at their deadline, or who leaves (`MatchLeave`) or concedes (op 6 / `concede_match`) during the check, is **removed** (`removeSeat`): op 108 `REMOVED_FROM_MATCH` to them, kicked from the match, their `activeMatchId` released, notification `1002` as a backup, remembered in `MatchState.removed` so they cannot walk back in. They never played: no rating change, no history, no `Conceded` flag. A leave from a socket the player has already replaced (different session ID) is ignored.
- **Replacement.** Private match: a Normal bot at once (strangers never join). Public match: the seat is held open (`SeatOpen`) for `READY_REFILL_SECONDS` (20) for a searcher of the same `playerCount`; a searcher who takes it gets their own ready window; if nobody does, a Normal bot takes it (`seatBot`, reusing `newAIPlayer`).
- If no human seat is left, the match is cancelled with `endReason: lobbyTimeout` (unrated, no history).
- When every seat is ready, `startGame` draws the first seat from the match RNG unless `FirstSeat` is already set (AI match, or a `firstSeat` match param), sends op 109 `GAME_STARTED` with `firstSeat`, then begins the first turn.
- **Rating with bots.** A public match left with fewer than two humans starts unrated. With two or more it stays rated, and `applyRatingUpdates` rates the human seats against each other only (bots have no account and get no profile). The win/draw/loss counters still read the whole table's ranks.

**Determinism.** The match RNG is seeded once (`MatchState.Seed`, logged in `MatchInit`, overridable with the `seed` match param). The deal, bot names and the first seat all come from it, so the same seed and the same event sequence replay identically.

**Pulling from the queue: what Nakama allows.** The Go runtime (nakama-common v1.32) cannot add, list or take matchmaker tickets — there is no server-side `MatchmakerAdd`, and `RegisterMatchmakerMatched` only fires for complete groups. So the "next player waiting" is found cooperatively:
1. While a seat is open, the match label advertises it: `{"rated":…,"playerCount":N,"mode":"public","open":1}` (`open` excludes seats already claimed by an in-flight join).
2. `start_public_search` runs `MatchList` with `+label.mode:public +label.open:>=1 +label.playerCount:>=N +label.playerCount:<=N` and returns `refillMatchId` when one exists, alongside the usual matchmaker parameters.
3. Clients call it when they start searching and re-poll it every ~5 s while their ticket waits; on a `refillMatchId` they drop the ticket and join the match by ID.
4. `MatchJoinAttempt` re-checks `activeMatchId`, refuses removed players, and records a claim (`refillClaims`, 15 s TTL) so two searchers cannot take one seat; an open seat is not handed to a bot while a claim is in flight. A join that still finds no seat gets `REMOVED_FROM_MATCH` reason `seat_unavailable` and is kicked, and the client goes back to the matchmaker.

The cost: a waiting player is pulled within one poll interval, not instantly, and only by clients that implement the poll. A client that does not poll still matchmakes normally; the seat then falls back to a bot after 20 s.

---

## 8. TURN TIMER & ABANDONMENT

**Turn timer:** always on. **Fixed at 90 seconds (1m30s) per turn** in this version.
- The per-room **timer selector** (45s / 1m / 1m30s / 2m) is **disabled in matchmaking/room setup** for now; it is not a matching property and not user-selectable. Code is written to support configurable values later; current value is fixed 90s.
- Runs on the `MatchLoop` tick. A tick rate of **1 Hz** is sufficient to drive a 90s clock and abandonment checks.

**Abandonment rule (locked):**
- Counter = the player's **own** missed turns; **cumulative, never resets**.
- When a player's turn arrives and they fail to act within 90s (including while disconnected), the turn **auto-skips** and the counter increments — unless the player had no legal action at all (coin-limit house rule, §7), in which case it is a plain pass and is not counted.
- On the player's **4th turn after 3 missed**, they **automatically lose**.
- Opponents always wait out the full 90s on an absent player's turn.
- Both **concede** and **3-turn auto-loss** = a rated loss (§10).

---

## 9. RECONNECTION & "CONTINUE LAST GAME"

- A player who leaves **without conceding** keeps their seat. The match handler does **not** free the seat on `MatchLeave`; the seat persists for the **entire abandonment window** (until they return, hit 4th-turn auto-loss, or concede).
- **Exception — the ready check (§7.2).** Before the first turn nothing has been played, so leaving then costs the seat (unrated, lock released, seat replaced) instead of starting the abandonment clock.
- **Reconnect mid-turn:** if they rejoin while their 90s is still running, they play the remaining time. Missed-turn counter is **not** reset by reconnecting.
- **`activeMatchId`** (account metadata) is set on join, cleared only when the game **finalizes for that player** (win, loss, concede, or auto-loss).
- **One online game at a time:** while `activeMatchId != null`, the user cannot enter public matchmaking or join/create a private match. The client shows **"Continue Last Game"** (reads the same `activeMatchId`) and hides "new online game."

---

## 10. RATING ENGINE

**Rated:** public online games only. **Unrated:** private games, all AI games.

**System:** weighted Elo, computed **at match end** inside the match handler (or a match-end routine), then submitted to the leaderboard (§11).

**Provisional period:** first **~10 rated games** per account → **hidden from public leaderboard**, **high K-factor** for fast settling. Tracked via `gamesPlayed` / `provisional` in the user's rating storage record.

**Threshold weighting (built now, only 15 ships):**
- Standard threshold = 25 Power (env `WIN_THRESHOLD`). Unrated games may pick 15, 20, 25 or 30.
- For longer games (future 20/25/30), apply weight `w = 15 / threshold` to the match **K-factor** so a win-to-30 moves rating half as much as a win-to-15.
- This version: only threshold 15 is live; longer-threshold options shown disabled in setup.

**Loss handling:** concede and 3-turn auto-loss apply an identical rated loss.

**Ready-check removals and bot replacements (15 October 2026).** A player removed by the ready check gets no rating change. A public match in which bots replaced no-shows is rated only if at least two humans remain, and then only between the humans (bot seats are skipped by `applyRatingUpdates`).

---

## 11. LEADERBOARD

- Nakama built-in leaderboard stores the Elo **rating as the score**.
- Submission happens at rated-match end (§10).
- **Excludes provisional accounts** (first ~10 rated games hidden).
- Public-game rating only — private and AI never submit.

---

## 12. MATCH HISTORY & AI RESULT SYNC

**Online games:** the authoritative match writes a durable history record per player at finalize (result, power, rating delta, opponents, timestamp, `isAI=false`).

**AI games:** the bot plays from a real seat in an authoritative match (see §7.1), so the result is computed by the server and is as trustworthy as any online game. The record carries `isAI=true` and the difficulty, and is **unrated**.
- **Legacy path:** `submit_ai_result` remains for clients that ran the game on-device. Those results are client-reported and therefore **untrusted**: they never affect rating and exist only for history and analytics.

**Match History view filter:** Online / vs AI (DEVELOPMENT_DOC S11).

---

## 13. ANTI-CHEAT

**Foundation:** server-authoritative match (§7) — clients cannot fabricate online outcomes.

**Locked defenses:**
1. **Private games unrated** — primary anti-collusion guarantee.
2. **One account per device** — device-bound account creation; makes alt-account farming expensive.
3. **Provisional rating** — fresh accounts can't appear high quickly.
4. **Concede = auto-loss = rated loss** — removes rage-quit-to-protect-rating.
5. **Result logging** — every rated match logs both account IDs, result, timing.

**Detection (log now, manual review later — no auto-punishment at launch):**
- Abnormal head-to-head frequency in public (possible win-trading) → flag via admin-console SQL queries over the result log.
- **Report queue:** the in-game report action (DEVELOPMENT_DOC M-GameMenu) calls a custom **`report_player`** RPC → stored report record (match ID, reporter, reported, reason) reviewed in the admin console.

---

## 14. PUSH NOTIFICATIONS

- Nakama notifications + push via **FCM (Android)** and **APNs (iOS)**.
- Triggers: private-game invite (recipient offline), friend request (offline), and (future) turn/abandonment alerts.
- Code `1002` `removed_from_match` (non-persistent, in-app only): sent when the ready check removes a player, so a client that is not connected to the match still learns it (§7.2).
- Respect user notification preferences (DEVELOPMENT_DOC S13).

---

## 15. STORAGE LAYOUT (COLLECTIONS)

Nakama storage collections (JSON objects), in addition to account metadata (§3):

| Collection | Key | Owner | Contents |
|---|---|---|---|
| `rating` | `profile` | user | `{ rating, gamesPlayed, provisional, wins, losses }` |
| `history` | `<gameId>` | user | `{ gameId, isAI, result, power, ratingDelta, opponents, playedAt }` |
| `match_log` | `<gameId>` | system | `{ gameId, mode, rated, playerIds[], result, startedAt, endedAt }` (anti-cheat/analytics) |
| `reports` | `<reportId>` | system | `{ matchId, reporterId, reportedId, reason, createdAt }` |
| `private_invites` | `<matchId>` | host | `{ matchId, invitedIds[], status }` |

Leaderboard is a native Nakama leaderboard, not a storage collection.

---

## 16. ENDPOINT & RPC REFERENCE

### 16.1 Nakama built-in operations (client calls; no custom code)
| Operation | Purpose | Auth |
|---|---|---|
| `authenticateDevice` | Create/login by device ID | none → creates session |
| `linkEmail` / `authenticateEmail` | Optional email link for cross-device | session |
| `updateAccount` | Display name, avatar metadata | session |
| `addFriends` / `deleteFriends` / `listFriends` / `acceptFriends` | Friends management | session |
| `addMatchmaker` / `removeMatchmaker` | Public queue join/leave (player-count property) | session |
| `createMatch` (via RPC, see below) / `joinMatch` | Match join | session |
| `listLeaderboardRecords` | Leaderboard read | session |
| `listNotifications` | Invites / requests inbox | session |
| `writeStorageObjects` / `readStorageObjects` | History/profile reads where client-permitted | session |

### 16.2 Custom RPCs (Go modules — must build)
| RPC name | Direction | Payload (in → out) | Authority / Notes |
|---|---|---|---|
| `bootstrap_profile` | client → server | `{ displayName, generation, avatarId }` → `{ ok }` | Sets metadata, `onboarded=true`. Validates generation ∈ 5, avatarId ∈ presets. |
| `start_public_search` | client → server | `{ playerCount }` → `{ ticket }` | Gates on `activeMatchId==null`; configures matchmaker with player-count property; returns matchmaker ticket. Also returns `refillMatchId` when a public match of that size has a ready-check seat open (§7.2). |
| `create_private_match` | client → server | `{ playerCount, invitedFriendIds[] }` → `{ matchId }` | Gates on `activeMatchId==null`; creates authoritative match (`rated=false`); writes `private_invites`; sends invite notifications. |
| `join_private_match` | client → server | `{ matchId }` → `{ ok }` | Gates on `activeMatchId==null`; checks invite list. |
| `get_active_game` | client → server | `{}` → `{ matchId | null }` | Backs "Continue Last Game"; reads `activeMatchId`. |
| `concede_match` | client → server | `{ matchId }` → `{ ok }` | Marks concede = rated loss; triggers rating + finalize for that player; clears `activeMatchId`. |
| `create_ai_match` | client → server | `{ difficulty, aiCount }` → `{ matchId }` | Creates an unrated authoritative match with bot seats. Gates on `activeMatchId==null`. |
| `submit_ai_result` | client → server | `{ result, power, difficulty, finishedAt }` → `{ ok }` | Legacy on-device path. Stores an untrusted, unrated history record. |
| `report_player` | client → server | `{ matchId, reportedId, reason }` → `{ ok }` | Writes `reports` record for manual review. |
| `get_match_history` | client → server | `{ filter: online\|ai\|all, cursor }` → `{ entries[], cursor }` | Reads user `history` collection. |

### 16.3 Server-internal (no client call)
| Routine | Trigger | Purpose |
|---|---|---|
| `finalize_match` | match end (win/last-round/all-conceded) | Compute winner, weighted-Elo deltas, submit leaderboard (if rated), write `history` + `match_log`, clear `activeMatchId` for all. |
| `abandonment_check` | match tick (1 Hz) | Advance turn on 90s expiry; increment missed-turn counter; 4th-after-3 → auto-loss (rated loss). |

---

## 17. MATCH MESSAGE PROTOCOL (OP CODES)

Realtime match messages between client and authoritative match handler. Client sends **intent**; server validates and broadcasts **state**.

**Client → Server (actions, validated server-side):**
| Op | Name | Payload |
|---|---|---|
| 1 | `ACTION_HARVEST` | `{ elements: [e1,e2,e3] }` |
| 2 | `ACTION_CHANNEL` | `{ element }` |
| 3 | `ACTION_HIRE` | `{ characterId, source: board\|jail, aetherUse }` |
| 4 | `ACTION_JAIL` | `{ characterId | tierDrawTop }` |
| 5 | ~~`RETURN_COINS`~~ | removed 15 Oct 2026 (coin limit is a hard block); reserved, rejected as `unknown_action` |
| 6 | `CONCEDE` | `{}` |
| 7 | `SYNC_REQUEST` | `{}` (on reconnect, request full state) |
| 8 | `READY` | `{}` (ready check, §7.2; never rejected) |

**Server → Client (authoritative):**
| Op | Name | Payload |
|---|---|---|
| 100 | `STATE_FULL` | complete game state (sent on join/reconnect) |
| 101 | `STATE_DIFF` | changed fields since last |
| 102 | `TURN_CHANGE` | `{ activePlayer, turnDeadline }` |
| 103 | `ACTION_REJECTED` | `{ reason }` |
| 104 | `ARTIFACT_CLAIMED` | `{ player, artifactId }` |
| 105 | `PLAYER_ABANDONED` | `{ player, missedCount }` |
| 106 | `GAME_ENDED` | `{ winner, standings, ratingDeltas }` |
| 107 | `READY_STATE` | `{ seats: [{ seat, userId, displayName, ready, isAI, open, deadlineMs }], readyCount, seatCount, deadlineMs, serverNowMs, readySeconds }` |
| 108 | `REMOVED_FROM_MATCH` | `{ matchId, reason: ready_timeout\|left\|seat_unavailable, ratingChange: 0 }` (to the removed player only) |
| 109 | `GAME_STARTED` | `{ firstSeat, firstPlayer, seats, rated, serverNowMs }` |

---

## 18. CONFIGURATION & ENVIRONMENT

| Key | This version | Notes |
|---|---|---|
| `TURN_SECONDS` | `90` | Fixed; per-room selection disabled. |
| `TURN_GRACE_SECONDS` | `2` | Hidden latency allowance before a turn is called missed. Not shown in the UI. |
| `LOBBY_WAIT_SECONDS` | `90` | Waiting-phase deadline (private lobbies filling up). On expiry the match is cancelled, unrated, with no history. |
| `READY_TIMEOUT_SECONDS` | `120` | Ready-check window per human seat (§7.2). A seat not ready by then is removed (unrated) and replaced. |
| `READY_REFILL_SECONDS` | `20` | How long a public match holds a removed player's seat for a searcher before a Normal bot takes it. Private matches never hold seats. |
| `AI_HARD_THINK_MS` | `320` | Search budget for the Hard bot, per move, on one core. |
| `AI_NORMAL_THINK_MS` | `45` | Search budget for the Normal bot. Easy does not search. |
| `TURN_TIMER_SELECTABLE` | `false` | Enables the room-setup timer selector when `true` (future). |
| `WIN_THRESHOLD` | `15` | Only 15 live; weighting code present for 20/25/30. |
| `MATCH_TICK_HZ` | `5` | Bounds how long a player waits for an action to be acknowledged (200 ms worst case). 1 Hz drives the clock correctly but feels sluggish. |
| `MATCHMAKER_TIMEOUT_SECONDS` | `60` | Client-side withdraw. |
| `PROVISIONAL_GAMES` | `10` | Hidden from leaderboard until exceeded. |
| `ABANDON_MISS_LIMIT` | `3` | 4th turn after 3 misses → auto-loss. |
| `MAX_RESERVE` (jail) | `3` | Per GDD. |
| `COIN_HOLD_LIMIT` | `10` | Per GDD. Hard block: a take above it is rejected (`coin_limit`), never returned. |

Matchmaker active matching property: **`playerCount` only.** Designed so additional properties (turn time, threshold) can be enabled without restructuring.

---

## 19. ADMIN CONSOLE USAGE

Nakama's built-in console covers the operator's day-to-day needs:
- Inspect/search users, view rating and history storage.
- View/manage the leaderboard.
- Run SQL/analytics over `match_log` (head-to-head frequency, win-trading detection).
- Review the `reports` queue.
- Inspect live matches and presence.

No separate admin panel needs to be built for v1.

---

## 20. OPEN ITEMS / DEFERRED

1. Enable the turn-timer **selector** (set `TURN_TIMER_SELECTABLE=true`) and add it as a matchmaker property.
2. Enable longer **win thresholds** (20/25/30) — rating weighting already specified.
3. Automated anti-cheat actions (currently detect + manual review only).
4. Player **block/mute**.
5. Turn/abandonment **push alerts** (notification triggers defined; wiring deferred).
6. Display-name uniqueness/profanity policy.

---

*End of Backend Specification v1.0*
*Stack: Nakama (Go) + PostgreSQL, no Redis · Self-hosted Linux · Server-authoritative · Companion to GAME_DESIGN_DOCUMENT.md and DEVELOPMENT_DOC.md*
