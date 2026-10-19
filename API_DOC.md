# Veynoria — Frontend API Contract

> Companion to `BACKEND_DOC.md` (architecture) and `GAME_DESIGN_DOCUMENT_v2.md` (rules).
> This document is the **wire contract** between the Flutter client and the Nakama backend.
> Every payload schema, op code, endpoint, error code, and storage key the client touches is listed here.
> Authority: when this file disagrees with the design docs, the source code in `runtime/` wins — this file is generated from it.

---

## TABLE OF CONTENTS

1. [Connection & Environment](#1-connection--environment)
2. [Authentication](#2-authentication)
3. [Account Metadata Schema](#3-account-metadata-schema)
4. [Custom RPCs](#4-custom-rpcs)
   - 4.1 [`bootstrap_profile`](#41-bootstrap_profile)
   - 4.2 [`get_active_game`](#42-get_active_game)
   - 4.3 [`start_public_search`](#43-start_public_search)
   - 4.4 [`create_private_match`](#44-create_private_match)
   - 4.5 [`join_private_match`](#45-join_private_match)
   - 4.6 [`concede_match`](#46-concede_match)
   - 4.7 [`submit_ai_result`](#47-submit_ai_result)
   - 4.8 [`report_player`](#48-report_player)
   - 4.9 [`get_match_history`](#49-get_match_history)
5. [Built-in Nakama Operations the Client Uses](#5-built-in-nakama-operations-the-client-uses)
6. [Realtime Match Protocol (WebSocket)](#6-realtime-match-protocol-websocket)
   - 6.1 [Client → Server Op Codes](#61-client--server-op-codes)
   - 6.2 [Server → Client Op Codes](#62-server--client-op-codes)
   - 6.3 [Full State Schema (`STATE_FULL`)](#63-full-state-schema-state_full)
   - 6.4 [Ready check](#64-ready-check-added-15-october-2026)
7. [Storage Collections (Client-Visible)](#7-storage-collections-client-visible)
8. [Notifications](#8-notifications)
9. [Error Codes](#9-error-codes)
10. [Frontend Flow Recipes](#10-frontend-flow-recipes)
11. [Constants & Config](#11-constants--config)

---

## 1. CONNECTION & ENVIRONMENT

| Item | Value (dev/local) | Notes |
|---|---|---|
| HTTP base | `http://localhost:7350` | All REST endpoints (`/v2/...`) |
| WebSocket base | `ws://localhost:7349` | Realtime socket (`/ws?token=...`) |
| Admin console | `http://localhost:7351` | Operator-only |
| Server key | `defaultkey` | Used for **device authenticate** (Basic auth) only |
| Session token | JWT returned by `authenticate*` | Used as `Authorization: Bearer <token>` on every subsequent call |
| Session TTL | 7200 s (2 h) | Configurable via Nakama startup flag |
| Match `module` | `veynoria_match` | The authoritative match handler |
| Leaderboard ID | `veynoria_elo` | Single leaderboard |

For production, replace `localhost` with the operator's hostname. **The server key must not be embedded in shipping clients** — only used for authentication and protected by HTTPS in production.

---

## 2. AUTHENTICATION

### 2.1 Device authenticate (first launch)

Used on first launch and every cold start to obtain a session.

```
POST /v2/account/authenticate/device?create=true&username=<displayName>
Authorization: Basic base64("defaultkey:")
Content-Type: application/json

{ "id": "<persistent-device-uuid>", "username": "<displayName>" }
```

**Response**

```json
{ "token": "<JWT>", "refresh_token": "<JWT>", "created": true }
```

The JWT carries `uid` (Nakama user ID) in its payload. After authenticate, the client SHOULD call `get_active_game` and read account metadata to decide whether to route to onboarding, lobby, or "Continue Last Game."

### 2.2 Link email (optional, enables cross-device)

```
POST /v2/account/link/email
Authorization: Bearer <token>
{ "email": "...", "password": "..." }
```

### 2.3 Authenticate by email (cross-device login)

```
POST /v2/account/authenticate/email?create=false
Authorization: Basic <server-key:>
{ "email": "...", "password": "..." }
```

---

## 3. ACCOUNT METADATA SCHEMA

Stored in the Nakama account's `metadata` JSON. Read on every login.

```json
{
  "generation": "merfolk",
  "avatarId": "preset_07",
  "onboarded": true,
  "activeMatchId": null
}
```

| Field | Type | Notes |
|---|---|---|
| `generation` | string | The player's clan, one of the five peoples: `human`, `merfolk`, `elf`, `dragonkin`, `voidborn`. **Cosmetic only.** (Changed 17 October 2026; the old list was `merfolk`, `stoneborn`, `sylvani`, `ashwalker`, `veyrnborn`.) |
| `avatarId` | string | One of: `preset_01` .. `preset_10`. |
| `onboarded` | bool | `false` → client must run onboarding (`bootstrap_profile`) before showing the lobby. |
| `activeMatchId` | string \| null | If non-null, the user is in a live online match. Show "Continue Last Game" and block "New Online Game." Cleared server-side when the match finalizes for that player. |

`displayName` is stored on the Nakama account itself (not in metadata) — read via `GET /v2/account`.

---

## 4. CUSTOM RPCs

All custom RPCs use this transport:

```
POST /v2/rpc/<rpcName>
Authorization: Bearer <session-token>
Content-Type: application/json

"<JSON-payload-as-string>"   ← body is the request JSON, quoted as a JSON string
```

**Response wrapper**

```json
{ "payload": "<JSON-response-as-string>" }
```

The client must `JSON.stringify` the request, send it as the HTTP body, then `JSON.parse` `response.payload`. The Nakama Dart SDK's `client.rpc(...)` does this transparently.

All RPCs require an authenticated session. Calls without one return Nakama error code `16` (Unauthenticated).

---

### 4.0 `get_catalog`

The static game data: all 90 cards, all 10 artifacts, and every rule constant.
**Call this first, before anything else.**

```
POST /v2/rpc/get_catalog
{ "knownVersion": "9e9dd460f2578ccd" }   // optional
```

Response (about 14 KB):

```jsonc
{
  "version": "9e9dd460f2578ccd",        // digest of the card + artifact data
  "cards": [
    { "id": "D-01", "name": "Kael the Ember Ward", "tier": 1, "power": 0,
      "affinity": "fire",
      "hireCost": { "light": 2, "water": 1, "nature": 1, "shadow": 1 },
      "costTotal": 5 }
  ],
  "artifacts": [
    { "id": "A-01", "name": "...", "power": 3,
      "requirement": { "fire": 4, "nature": 4 } }
  ],
  "config": {
    "winThreshold": 25, "winThresholdOptions": [15, 20, 25, 30], "maxReserve": 3, "coinHoldLimit": 10,
    "turnSeconds": 90, "abandonMissLimit": 3, "channelMinSupply": 4,
    "artifactPower": 3, "maxHarvest": 3, "boardWidth": 4,
    "matchmakerTimeoutSeconds": 60, "provisionalGames": 10,
    "readyTimeoutSeconds": 120, "readyRefillSeconds": 20,
    "supplyPerColour": { "2": 4, "3": 5, "4": 7 },
    "artifactsShown":  { "2": 3, "3": 4, "4": 5 },
    "elements": ["light","water","nature","fire","shadow"],
    "wildcardElement": "aether",
    "tiers": [1,2,3],
    "difficulties": ["easy","normal","hard"],
    "generations": ["dragonkin","elf","human","merfolk","voidborn"],
    "avatars": ["preset_01", "..."],
    "rejectionCodes": ["not_your_turn", "..."]
  }
}
```

Passing a `knownVersion` that still matches returns `{ "version": "...",
"unchanged": true }` and no payload, so the client keeps its cache.

**Why this exists.** The match protocol names a card by ID only: the board
arrives as `["H-01","M-04",...]`. Resolving those against a table compiled into
the app is how the two halves drift apart, and this project has already shipped
a card table with 49 costs that existed nowhere in the source deck. The server
owns the numbers; the client caches them against `version`.

The `config` block means no rule constant needs to be a literal in the app. A
server-side change to the turn length or the hold limit reaches the UI without
an app release.

Requires no session state and never changes mid-match.

---

### 4.1 `bootstrap_profile`

Completes onboarding. Must be called once before the user can enter any game.

**Request**

```json
{
  "displayName": "Aeris",
  "generation": "merfolk",
  "avatarId": "preset_07"
}
```

**Response**

```json
{ "ok": true }
```

**Errors**

| Reason | Code | Message |
|---|---|---|
| Missing displayName | `3` | `displayName is required` |
| Bad generation | `3` | `invalid generation` |
| Bad avatarId | `3` | `invalid avatarId` |
| Account update failed | `13` | `failed to update account` |

**Side effects:** sets `metadata.generation`, `metadata.avatarId`, `metadata.onboarded = true`. Sets the account `username`/`display_name` to `displayName`.

---

### 4.2 `get_active_game`

Drives the "Continue Last Game" entry point. Call on app start and after every screen that may have ended a match.

**Request**

```json
{}
```

**Response**

```json
{ "matchId": "<uuid>" }
```

or

```json
{ "matchId": null }
```

If `matchId` is non-null, the client should call `socket.joinMatch(matchId)` and route into the game screen. If null, show the normal lobby.

---

### 4.3 `start_public_search`

Gate + parameter builder for public matchmaking. The server validates that the user is not already in a match and returns the matchmaker query the client must pass to its socket `matchmaker_add`.

**Request**

```json
{ "playerCount": 2 }
```

Allowed `playerCount`: `2`, `3`, or `4`.

**Response**

```json
{
  "minCount": 2,
  "maxCount": 2,
  "query": "+numericProperties.playerCount:>=2 +numericProperties.playerCount:<=2",
  "stringProperties": {},
  "numericProperties": { "playerCount": 2 },
  "timeoutSeconds": 60,
  "refillMatchId": "<matchId>"     // optional, see "Refill seats" below
}
```

The client then sends, over the realtime socket:

```json
{
  "cid": "<correlation-id>",
  "matchmaker_add": {
    "min_count": 2,
    "max_count": 2,
    "query": "...",
    "numeric_properties": { "playerCount": 2 },
    "string_properties": {}
  }
}
```

The client must withdraw from the matchmaker after `timeoutSeconds` if no match has formed.

**Errors**

| Reason | Code |
|---|---|
| Bad `playerCount` | `3` |
| User already in a match | `9` (FailedPrecondition) |

**Match-found flow:** The socket eventually receives `matchmaker_matched` carrying `match_id` and a per-player `token`. The client then sends `match_join` with that token. The server has already stamped `activeMatchId` on all matched players. The match opens with a **ready check** (§6.4): send op 8 `READY` as soon as the player confirms.

**Refill seats (added 15 October 2026).** When a matched player fails the ready check, a public match holds their seat open for `readyRefillSeconds` (20 s) for someone searching the same `playerCount`. Nakama's matchmaker cannot be pulled from server-side, so searchers find these seats through this RPC:

- If the response carries `refillMatchId`, join that match directly (`socket.joinMatch(refillMatchId)`, no token) instead of adding a matchmaker ticket. You get your own fresh ready window.
- While a matchmaker ticket is waiting, call `start_public_search` again every ~5 s. If a `refillMatchId` comes back, remove the ticket (`socket.removeMatchmaker(ticket)`) and join that match.
- If the join is refused (`match is full`, `match already started`, `removed from this match`), or the match answers with `REMOVED_FROM_MATCH` reason `seat_unavailable`, someone else got the seat: carry on with the matchmaker using the parameters in the same response, which are always present.
- Joining a refill seat stamps `activeMatchId` once you are seated.

---

### 4.4 `create_private_match`

Host a private (unrated) match and notify invited friends.

**Request**

```json
{
  "playerCount": 3,
  "invitedFriendIds": ["<userId>", "<userId>"],
  "winThreshold": 20          // optional: 15 | 20 | 25 | 30, default 25
}
```

`invitedFriendIds.length` MUST equal `playerCount - 1`.

**Response**

```json
{ "matchId": "<uuid>" }
```

**Side effects**

- Creates an authoritative match with `rated=false`.
- Writes a `private_invites` storage record (system-owned, server-only).
- Sends a persistent in-app notification (`code=1001`, subject `private_match_invite`) to each invited friend; falls back to push if offline (FCM/APNs).
- Stamps `metadata.activeMatchId = <matchId>` on the host.

After this RPC, the host must call `socket.joinMatch(matchId)` to physically connect.

**Errors**

| Reason | Code |
|---|---|
| Bad `playerCount` | `3` |
| Wrong invitedFriendIds length | `3` |
| User already in a match | `9` |
| Storage / notification failure | `13` |

---

### 4.5 `join_private_match`

Validate that the caller is on the invite list. Returns OK so the client can proceed to a standard socket `match_join`.

**Request**

```json
{ "matchId": "<uuid>" }
```

**Response**

```json
{ "ok": true }
```

**Errors**

| Reason | Code |
|---|---|
| Missing `matchId` | `3` |
| User already in a match | `9` |
| Invite record not found | `5` (NotFound) |
| Match no longer open | `9` |
| Not invited | `7` (PermissionDenied) |

**Note:** `activeMatchId` is stamped server-side in `MatchJoin`, not in this RPC, so a user who validates but never connects is not marked active.

---

### 4.6 `concede_match`

Voluntarily forfeit the current match. Treated as a **rated loss** in public games.

**Request**

```json
{ "matchId": "<uuid>" }
```

**Response**

```json
{ "ok": true }
```

The RPC signals the live match — the actual finalize happens inside the match handler. The client should expect a subsequent `OpGameEnded (106)` over the socket and an eventual clearing of `activeMatchId`.

**Errors**

| Reason | Code |
|---|---|
| Missing `matchId` | `3` |
| Signal failed | `13` |

---

### 4.7 `submit_ai_result`

Records the outcome of an **on-device** AI game. Unrated, untrusted, analytics only.

**Request**

```json
{
  "result": "win",
  "power": 17,
  "difficulty": "normal",
  "finishedAt": "2026-06-05T12:00:00Z"
}
```

| Field | Type | Notes |
|---|---|---|
| `result` | string | `win` \| `loss` |
| `power` | int | Final Power total. Schema-only — not validated. |
| `difficulty` | string | `easy` \| `normal` \| `hard`, case-insensitive. Stored on the history record; defaults to `normal` when omitted. |
| `finishedAt` | RFC3339 string | Optional. If empty, server time is used. **Untrusted.** |

**Response**

```json
{ "ok": true }
```

Stored as a `history` record with `isAI=true`, `ratingDelta=0`, empty `opponents`, and the reported `difficulty`.

`result` must be `win` or `loss`; `power` must not be negative. `finishedAt` is accepted only when it is within roughly a day of server time, otherwise server time is recorded instead, so a wrong device clock cannot scatter a player's history.

---

### 4.8 `report_player`

Writes a system-owned report for manual admin review.

**Request**

```json
{
  "matchId": "<uuid>",
  "reportedId": "<userId>",
  "reason": "free-form text"
}
```

All three fields are required; all are stored verbatim.

**Response**

```json
{ "ok": true }
```

---

### 4.9 `get_match_history`

Lists the caller's match history. Pages of up to 100 entries.

**Request**

```json
{ "filter": "online", "cursor": "" }
```

| Field | Type | Notes |
|---|---|---|
| `filter` | string | `all` (default) \| `online` \| `ai`. Filter is applied client-page-side after the storage read. |
| `cursor` | string | Pass back the previous response's `cursor`. Empty for first page. |

`filter` defaults to `"all"` if the field or whole body is omitted.

**Response**

```json
{
  "entries": [
    {
      "gameId": "<uuid>",
      "isAI": false,
      "result": "win",
      "power": 17,
      "ratingDelta": 12,
      "opponents": ["<userId>", ...],
      "playedAt": "2026-06-05T11:55:00Z"
    }
  ],
  "cursor": "<opaque-string>"
}
```

`cursor` is empty when there are no more pages. Because filtering happens after the page read, a page may contain fewer entries than 100 even when `cursor` is non-empty — keep paging.

---

### 4.10 `create_ai_match`

Starts a game against the built-in engine.

```
POST /v2/rpc/create_ai_match
{ "difficulty": "hard", "aiCount": 1 }
```

| Field | Type | Notes |
|---|---|---|
| `difficulty` | string | `easy` \| `normal` \| `hard`. Anything else is treated as `normal`. |
| `aiCount` | int | 1-3 bots. Defaults to 1, giving a 2-player game. |
| `playerName` | string | Optional display-name override for the human seat. |
| `winThreshold` | int | Optional Power target: 15, 20, 25 or 30. Defaults to 25. Anything else is rejected with code `3`. |

Response: `{ "matchId": "...", "difficulty": "hard", "seats": 2 }`

Then join it exactly like any other match: `socket.joinMatch(matchId)`. **The bot
is a real seat in an authoritative match, not client-side code.** Everything that
applies to a human game applies here: the same op codes, the same turn clock, the
same `STATE_FULL` projection. The human always takes seat 0 and moves first.

| Error | Code |
|---|---|
| Already in a match | `9` |
| `aiCount` out of range | `3` |

AI matches are **never rated**, and the `activeMatchId` gate applies, so a player
must finish or concede before starting anything else. History records for these
games carry `isAI: true` and the `difficulty`.

> `submit_ai_result` (§4.7) predates this and remains for older clients that ran
> the game on-device. New clients should use `create_ai_match` instead: a result
> the server computed cannot be forged, and the bot is much stronger than one
> that has to fit in the app.

---

## 5. BUILT-IN NAKAMA OPERATIONS THE CLIENT USES

These are out-of-the-box Nakama features. Use the Dart SDK directly (`client.*` or `socket.*`).

| Purpose | Operation | Notes |
|---|---|---|
| Update profile (display name, avatar metadata) | `updateAccount` | The `metadata` field merges client-side — overwrite the whole object. |
| Read account (incl. metadata) | `getAccount` | Returns `user.metadata` as a JSON **string** — parse it. |
| Friends — list | `listFriends` | Returns friends + their online presence. |
| Friends — request / accept / delete | `addFriends`, `acceptFriends`, `deleteFriends` | Standard. |
| Public matchmaker | `socket.addMatchmaker(...)` | Use params from `start_public_search`. |
| Withdraw from matchmaker | `socket.removeMatchmaker(ticket)` | Must be called at 60 s timeout. |
| Join match | `socket.joinMatch(matchId)` or `socket.joinMatchWithToken(token)` | Use token for matchmaker-found matches, ID for private joins. |
| Leave match | `socket.leaveMatch(matchId)` | Marks player disconnected; does NOT free the seat (§9 of BACKEND_DOC). |
| Send match action | `socket.sendMatchData(matchId, opCode, data)` | `data` is UTF-8 JSON bytes; op codes in §6. |
| Read leaderboard | `listLeaderboardRecords("veynoria_elo", ...)` | Provisional players are not on it. |
| Inbox / invites | `listNotifications` + `notifications` socket event | Private-match invite arrives here with `code: 1001`, content `{ "matchId": "<uuid>" }`. |
| Reads of own storage (history, rating) | `readStorageObjects` | History is owner-readable; rating is public-readable. |

---

## 6. REALTIME MATCH PROTOCOL (WEBSOCKET)

After `socket.joinMatch(...)`, the client and the authoritative match exchange typed binary-over-JSON messages via op codes. **All payloads are JSON-encoded UTF-8.**

> **Revised 15 October 2026 — ready check and random first player.** Every online
> match (public and private, not `create_ai_match`) now passes through a new phase,
> `readyCheck`, once all its seats are filled. Each human must send the new op 8
> `READY` within `READY_TIMEOUT_SECONDS` (120 s). The server broadcasts the new op
> 107 `READY_STATE` on every change, removes a seat that is not ready in time (op
> 108 `REMOVED_FROM_MATCH` to that player, no rating change), replaces it (a player
> from the search queue in public matches, otherwise a Normal bot), and starts the
> game with a **random first player**, announced by the new op 109 `GAME_STARTED`
> (`firstSeat`). Seat 0 no longer always opens: read `currentTurn` / `firstSeat`.
> Game actions during the ready check are rejected with `game_not_running`. See §6.4.

> **Revised 15 October 2026 — coin-limit house rule.** The 10-coin limit is now a
> hard block, a deliberate departure from official Splendor (which lets a player go
> over 10 and then return coins). A Harvest or Channel that would take you above 10
> coins (Aether included) is rejected with the new code `coin_limit`; Jail at 10 is
> legal but grants no Aether. The return step is gone entirely: op 5 `RETURN_COINS`
> is **removed** (the number stays reserved and is answered with `unknown_action`),
> the codes `must_return_coins`, `return_count_mismatch` and `return_coins_not_held`
> are no longer sent, and `awaitReturnCoins` / `awaitReturnSeat` are no longer in
> `STATE_FULL`. A new `GAME_ENDED.reason`, `stalemate`, covers the rare position in
> which nobody still in the game has a legal move.

> **Revised 5 September 2026.** `STATE_FULL` is now projected per viewer rather than
> broadcast as the raw server state. Two things you may have coded against are gone,
> deliberately: the draw piles (`tier1Deck`, `tier2Deck`, `tier3Deck`) and other
> players' reserved card IDs. See §6.3.

### 6.1 Client → Server Op Codes

| Op | Name | Payload | Notes |
|---|---|---|---|
| 1 | `ACTION_HARVEST` | `{ "elements": ["light","water","nature"] }` | 1 to 3 coins of **different** elements, never Aether. Rejected with `coin_limit` if it would take you above 10 coins (Aether included): at 8 coins you may take at most 2, at 9 at most 1, at 10 none. Taking fewer than 3 to land exactly on 10 is legal. |
| 2 | `ACTION_CHANNEL` | `{ "element": "fire" }` | 2 coins of one element. Requires supply ≥ 4 of it, and at most 8 coins in hand (otherwise `coin_limit`). |
| 3 | `ACTION_HIRE` | `{ "characterId": "H-08", "fromReserve": false, "aetherUse": 0 }` | `fromReserve` and `aetherUse` are **hints for your own UI only**. The server determines the real source and computes the Aether spend itself; sending wrong values changes nothing. |
| 4 | `ACTION_JAIL` | `{ "characterId": "M-04" }` OR `{ "characterId": "", "tier": 2 }` | First form reserves a face-up card; second blind-draws the top of `tier` (1/2/3). Grants 1 Aether if the supply has one **and** you hold fewer than 10 coins; reserving at 10 coins is legal and simply grants no Aether. Max 3 reserved. |
| 5 | ~~`RETURN_COINS`~~ | — | **Removed 15 October 2026** with the coin-limit house rule: nobody can ever be over the limit, so there is nothing to return. The number is reserved and never reused; sending it gets `unknown_action`. |
| 6 | `CONCEDE` | `{}` | Equivalent to the `concede_match` RPC. A concession is always a loss, whatever your Power. |
| 7 | `SYNC_REQUEST` | `{}` | Request a fresh full state; use on reconnect. Answered privately to the caller. |
| 8 | `READY` | `{}` | Confirms your seat during the ready check (§6.4). Never rejected: a repeat, a `READY` outside the ready check, or one from a socket without a seat is silently ignored. Bots are ready automatically. |

**Element string values:** `light`, `water`, `nature`, `fire`, `shadow`, `aether`.

`Cost` maps: an object with element-string keys and integer values; only nonzero entries are included.

### 6.2 Server → Client Op Codes

| Op | Name | Payload | When |
|---|---|---|---|
| 100 | `STATE_FULL` | Per-viewer state (see §6.3) | On join, on reconnect, and after every state change. Addressed to one player at a time. |
| 101 | `STATE_DIFF` | *(reserved — not emitted)* | Future optimisation. |
| 102 | `TURN_CHANGE` | see below | At the start of every turn. |
| 103 | `ACTION_REJECTED` | `{ "code": "not_your_turn", "reason": "it is not your turn" }` | Sent **only to the player whose action failed**. Switch on `code`; `reason` is for logs, not for display. |
| 104 | `ARTIFACT_CLAIMED` | `{ "player": "<userId>", "playerIndex": 1, "artifactId": "A-03" }` | A player's affinities met an artifact requirement. |
| 105 | `PLAYER_ABANDONED` | `{ "player": "<userId>", "playerIndex": 2, "missedCount": 2, "autoLost": false }` | Each time a turn auto-skips. `missedCount` is cumulative and never resets. `autoLost` is true on the miss that costs the player the match. Not sent when the player had no legal move at all: that expiry is a plain pass and is not counted. |
| 106 | `GAME_ENDED` | see below | The match reached a terminal state. |
| 107 | `READY_STATE` | see §6.4 | To the whole table, whenever the ready check changes: a seat readies, a seat is removed, opened, refilled or taken by a bot, a player reconnects, or the check begins. |
| 108 | `REMOVED_FROM_MATCH` | `{ "matchId": "...", "reason": "ready_timeout", "ratingChange": 0 }` | **Only to the removed player**, immediately before the server kicks their socket from the match. `reason`: `ready_timeout` (no `READY` in time), `left` (left or conceded during the ready check), `seat_unavailable` (a refill seat was gone by the time the join landed). Return the player to the menu (or, for `seat_unavailable`, back to searching). Nothing was rated and their `activeMatchId` is already cleared. |
| 109 | `GAME_STARTED` | see §6.4 | Once, when the ready check passes (and when an AI match starts), just before the first `STATE_FULL` and `TURN_CHANGE` of the game. Carries `firstSeat` for the "who starts" animation. |

**102 `TURN_CHANGE`**

```jsonc
{
  "activePlayer": "<userId>",
  "playerIndex":  1,
  "turnNumber":   14,             // turns started so far in this match
  "turnDeadline": 1788012345,     // Unix seconds — kept for compatibility
  "deadlineMs":   1788012345678,  // canonical, milliseconds
  "serverNowMs":  1788012255678,  // server clock at send time
  "turnSeconds":  90
}
```

Render the countdown as `deadlineMs - serverNowMs`, then tick locally. Do **not**
compare `deadlineMs` against the device clock: phones are routinely minutes out,
and the difference of the two server values is immune to that.

The server allows a small grace window past the deadline (`TURN_GRACE_SECONDS`,
2s by default) before charging a missed turn, so an action sent just as the timer
hits zero still counts. Never show the grace in the UI.

**103 `ACTION_REJECTED` codes**

`not_your_turn`, `bad_payload`, `unknown_action`,
`harvest_count`, `harvest_duplicate`, `harvest_aether`, `supply_empty`,
`channel_aether`, `channel_supply_low`, `unknown_card`, `card_not_accessible`,
`cannot_afford`, `reserve_full`, `card_not_visible`, `bad_tier`, `deck_empty`,
`coin_limit`, `game_not_running`.

`coin_limit` (new, 15 October 2026): the Harvest or Channel would leave you holding
more than 10 coins, Aether included. Nothing changed; it is still your turn. This
is a deliberate house rule, not Splendor's: there is no "take, then return".
A malformed take (duplicate colour, Aether, empty supply) reports its own code
first; `coin_limit` is checked last.

Removed on 15 October 2026 and never sent any more: `must_return_coins`,
`return_count_mismatch`, `return_coins_not_held`.

`game_not_running`: the match is not in play. Since 15 October 2026 this is also
the answer to any game action (ops 1–4) sent during the ready check. Nothing
changed; wait for `GAME_STARTED`. `READY`, `SYNC_REQUEST` and `CONCEDE` are not
game actions and are never answered with it.

**106 `GAME_ENDED`**

```jsonc
{
  "winnerIndex":  0,              // -1 = shared victory, or a cancelled lobby
  "winnerUserId": "<userId>",
  "reason":       "threshold",    // threshold | lastStanding | allConceded | lobbyTimeout | stalemate
  "standings": [
    { "index": 0, "userId": "...", "displayName": "...", "power": 17,
      "hiredCount": 8, "conceded": false, "rank": 1 }
  ],
  "ratingDeltas": { "<userId>": 12 }   // empty for unrated and cancelled matches
}
```

`standings` is pre-sorted, best first. A player who conceded or was auto-lost is
ranked below every player still in the game regardless of Power, so render the
order as given rather than re-sorting on `power`. Equal `rank` values mean a tie.

`reason` of `stalemate` is a normal, rated finish: every player still in the game
was left without a legal move (10 coins, 3 reserved cards, nothing affordable — only
possible because of the coin-limit house rule), so the board was scored as it
stood. Show the ordinary results screen.

`reason` of `lobbyTimeout` means the match was cancelled before it began: a
private lobby never filled, or no human was left after the ready check. Nothing
was rated and no history was written. Send the player back to the lobby rather
than to a results screen.

> The current build does not emit `STATE_DIFF`. Every change goes out as a fresh
> `STATE_FULL`, so replace local state wholesale on each op 100.

### 6.3 Per-Viewer State Schema (`STATE_FULL`)

Each player receives a projection built for them. Two categories of information
are withheld, and no client-side flag can reveal them, because they are never
serialised into that player's message.

**Never sent to anyone**

- The draw piles. You get `tier1Count`, `tier2Count`, `tier3Count` instead, which
  is what you need to render a deck stack and grey out an empty tier.

**Sent only to the owner**

- Reserved card identities. In your own `players[]` entry, `reserve[].cardId` is
  populated. In every other entry it is absent, and you get only `tier` and
  `reserveCount`. Render opponents' reserves as face-down backs of that tier.

```jsonc
{
  "phase":        "playing",        // waiting | readyCheck | playing | finalRound | ended
  "yourSeat":     0,                // -1 if this socket is not seated
  "currentTurn":  0,                // seat index on turn
  "turnNumber":   14,

  "players": [
    {
      "userId": "...", "displayName": "...", "seat": 0, "isSelf": true,
      "coins":      { "light": 2, "aether": 1 },
      "coinTotal":  3,
      "hiredCards": [ /* full card objects */ ],
      "affinity":   { "light": 3, "fire": 1 },   // per-element discount, precomputed
      "power":      9,
      "artifacts":  ["A-03"],
      "reserve": [
        { "cardId": "H-12", "tier": 2, "fromBoard": true }   // cardId only when isSelf
      ],
      "reserveCount": 1,
      "missedTurns":  0,
      "disconnected": false,
      "conceded":     false,
      "turnsTaken":   7,
      "isAI":         false,
      "aiDifficulty": "",
      "ready":        true,     // meaningful while phase == "readyCheck"; bots are always ready
      "seatOpen":     false     // true = seat held for a replacement; userId and displayName are ""
    }
  ],

  "tier1Visible": ["H-01","M-04","E-02","V-07"],   // 4 face-up per tier
  "tier2Visible": ["..."],
  "tier3Visible": ["..."],
  "tier1Count":   32,                              // cards left face-down
  "tier2Count":   21,
  "tier3Count":   14,

  "supply":       { "light": 4, "water": 3, "nature": 5, "fire": 2, "shadow": 4 },
  "aetherSupply": 3,
  "artifacts":    [ { "id": "A-01", "name": "...", "requirement": { "fire": 4, "nature": 4 } } ],

  "winThreshold": 25,
  "rated":        true,

  "turnDeadlineMs":   1788012345678,
  "turnDeadlineUnix": 1788012345,
  "lobbyDeadlineMs":  0,        // present while phase == "waiting"
  "serverNowMs":      1788012255678,
  "turnSeconds":      90,

  "expectedPlayerCount": 2,
  "winnerIndex":         -2,    // -2 = still running, -1 = shared victory
  "endReason":           "",    // set once phase == "ended"
  "readyDeadlineMs":     0,     // present while phase == "readyCheck": the countdown (§6.4)
  "firstSeat":           1      // seat that opened the game; -1 before it starts
}
```

**Affinity is precomputed.** `players[].affinity` is the per-element discount the
server will apply. To show whether a card is affordable, subtract it from the
card cost, floor each component at zero, and cover any shortfall with Aether.
Never recompute the discount from `hiredCards` and never send a computed price.

**Start.** While `phase == "waiting"` render a lobby (private matches only; a
matchmaker match is full from the start). Once every seat is filled an online
match moves to `"readyCheck"` (§6.4); when every seat is ready the server sends
`GAME_STARTED`, then a fresh state with `phase: "playing"`, then `TURN_CHANGE`.
An AI match skips the ready check and starts once its human connects. If a
private lobby does not fill before `lobbyDeadlineMs` the match is cancelled with
`endReason: "lobbyTimeout"`.

**Reconnect.** On rejoin you receive `STATE_FULL` immediately. Rebuild the
countdown from `turnDeadlineMs - serverNowMs` (or `readyDeadlineMs - serverNowMs`
during the ready check). `missedTurns` does not reset.

### 6.4 Ready check (added 15 October 2026)

**When.** As soon as every seat of an online match is filled: at creation for a
matchmaker match (the window therefore also covers connecting), and when the last
invited friend joins a private match. AI matches (`create_ai_match`) have no
ready check.

**What the client does.** Show a ready screen with every seat, a countdown, and a
"Ready" button that sends op 8 `READY` with `{}`. Every human seat must confirm
within `READY_TIMEOUT_SECONDS` (120 s, `config.readyTimeoutSeconds`). Bots are
ready from the start. Game actions in this phase get `game_not_running`.

**107 `READY_STATE`**

```jsonc
{
  "seats": [
    { "seat": 0, "userId": "<userId>", "displayName": "Ash", "ready": true,
      "isAI": false, "open": false, "deadlineMs": 0 },
    { "seat": 1, "userId": "", "displayName": "", "ready": false,
      "isAI": false, "open": true,  "deadlineMs": 1788012365678 },  // held for a replacement
    { "seat": 2, "userId": "ai:2", "displayName": "Coldforge", "ready": true,
      "isAI": true,  "open": false, "deadlineMs": 0 }
  ],
  "readyCount":   2,
  "seatCount":    3,
  "deadlineMs":   1788012365678,  // the countdown to show: latest pending seat deadline
  "serverNowMs":  1788012345678,
  "readySeconds": 120
}
```

Each seat's `deadlineMs` is its own: the ready deadline for an unready human, the
refill deadline for an open seat, `0` once ready. A replacement human gets a fresh
120 s window, so seats can differ. As with the turn clock, render
`deadlineMs - serverNowMs` and tick locally; never compare against the device
clock. The same data is in `STATE_FULL` (`players[].ready`, `players[].seatOpen`,
`readyDeadlineMs`), so a reconnecting client can rebuild the screen from either.

**Timeouts and replacement.** A human seat that is not ready at its deadline, or
whose player leaves the match or concedes during the check, is removed:

1. That player gets `REMOVED_FROM_MATCH` (op 108) and is kicked from the match.
   No rating change, no history, `activeMatchId` cleared. If their socket was not
   in the match they get notification `1002` instead (§8).
2. **Public match:** the seat is held open (`open: true`) for
   `READY_REFILL_SECONDS` (20 s) for someone searching the same `playerCount`
   (see `start_public_search`, "Refill seats"). A searcher who takes it gets their
   own 120 s ready window. If nobody takes it, a **Normal** bot does.
3. **Private match:** the seat goes straight to a Normal bot. Strangers are never
   admitted.
4. If no human is left, the match is cancelled: `GAME_ENDED` with
   `reason: "lobbyTimeout"`.

A public match that ends up with fewer than two humans is played **unrated**
(`GAME_STARTED.rated` / `STATE_FULL.rated` say so). With two or more humans it
stays rated, and bots are left out of the rating calculation.

**109 `GAME_STARTED`**

```jsonc
{
  "firstSeat":   1,                       // seat index that moves first
  "firstPlayer": "<userId>",              // the user on that seat
  "seats":       ["<userId>", "<userId>", "ai:2"],  // userId per seat, in seat order
  "rated":       true,
  "serverNowMs": 1788012345678
}
```

The first player is drawn at random by the server (from the match's seeded RNG,
so replays reproduce it). Play then proceeds in seat order from `firstSeat`,
wrapping round, and the final round ends when play comes back round to
`firstSeat`: everyone still gets the same number of turns. Use `GAME_STARTED` to
play a "who starts" animation; the first `TURN_CHANGE` arrives right after it and
its turn clock is already running, so keep the animation short (≤ 2 s) or overlay
it on the board. `STATE_FULL.firstSeat` carries the same value for reconnects.

---

---

## 7. STORAGE COLLECTIONS (CLIENT-VISIBLE)

| Collection | Key | Owner | Permission | Client use |
|---|---|---|---|---|
| `rating` | `profile` | the user | `PUBLIC_READ` / server-only write | Read own + any opponent profile: `{ rating, gamesPlayed, provisional, wins, losses }`. |
| `history` | `<gameId>` | the user | `OWNER_READ` / server-only write | Prefer `get_match_history` RPC; direct read is allowed for own records. |

Other collections (`match_log`, `reports`, `private_invites`) are system-owned with `NO_READ` from clients.

`ratingProfile`:

```json
{ "rating": 1042, "gamesPlayed": 3, "provisional": true, "wins": 2, "losses": 1 }
```

The client must respect `provisional`: if true, do not surface the rating on a public leaderboard view, but you may show it on the user's own profile.

---

## 8. NOTIFICATIONS

| Code | Subject | Persistent | Sent when | Content |
|---|---|---|---|---|
| 1001 | `private_match_invite` | yes | Host creates a private match | `{ "matchId": "<uuid>" }` |
| 1002 | `removed_from_match` | no | The ready check removed you from a match (§6.4). Mirrors op 108 for a player whose socket was not in the match. | `{ "matchId": "<uuid>", "reason": "ready_timeout" \| "left" }` |

The client should listen to the `notifications` socket event for live arrivals and call `listNotifications` on app open for the inbox. Tapping an invite calls `join_private_match` followed by `socket.joinMatch`.

Future codes (defined in BACKEND_DOC §14, not wired yet): friend-request offline alert, turn-timer warning.

---

## 9. ERROR CODES

Custom RPCs use Nakama gRPC status codes:

| Code | Name | Meaning in this app |
|---|---|---|
| 3 | InvalidArgument | Payload schema invalid or out-of-range field. |
| 5 | NotFound | Invite record / resource missing. |
| 7 | PermissionDenied | Caller is not on the invite list. |
| 9 | FailedPrecondition | `activeMatchId != null`, match already started, etc. |
| 13 | Internal | Storage / Nakama call failed. |
| 16 | Unauthenticated | No session. |

The `message` field is human-readable English; the client should map by **code**, not by message text.

---

## 10. FRONTEND FLOW RECIPES

End-to-end sequences the Flutter client must implement. Screen IDs reference DEVELOPMENT_DOC.

### 10.1 Cold start

1. `authenticateDevice` with stored device ID (or generate one).
2. `getAccount` → parse `user.metadata`.
3. If `onboarded == false` → S2 Onboarding.
4. Else call `get_active_game`:
   - if `matchId != null` → S10 Game (joinMatch on socket).
   - else → S3 Home.

### 10.2 Onboarding

1. Collect `displayName`, `generation`, `avatarId`.
2. `rpc bootstrap_profile`.
3. On `{ ok: true }` → S3 Home.

### 10.3 Public match

1. User picks player count (2/3/4) on S4 Lobby.
2. `rpc start_public_search` → params. If the response has `refillMatchId`, skip to step 5 with `socket.joinMatch(refillMatchId)`.
3. Open socket if not already open. `socket.addMatchmaker(params)`.
4. Wait for `matchmaker_matched` event → grab `token` + `match_id`. Meanwhile call `start_public_search` every ~5 s; if it returns `refillMatchId`, `socket.removeMatchmaker(ticket)` and join that match instead.
5. `socket.joinMatch(token)`.
6. Receive `STATE_FULL (100)` with `phase: "readyCheck"` and `READY_STATE (107)` → show the ready screen with its countdown. Player taps Ready → send op 8 `READY`.
7. `GAME_STARTED (109)` → "who starts" animation from `firstSeat` → `STATE_FULL` + `TURN_CHANGE (102)` → game begins.
8. On `REMOVED_FROM_MATCH (108)`: back to the menu (`ready_timeout` / `left`) or back to searching (`seat_unavailable`).
9. On 60 s of no `matchmaker_matched`, `socket.removeMatchmaker(ticket)` and prompt user.

### 10.4 Private match — host

1. S5 Friends → pick friends → S6 Private Lobby.
2. `rpc create_private_match` with `playerCount` and `invitedFriendIds`.
3. Use returned `matchId` to `socket.joinMatch(matchId)`.
4. Wait for joinees to connect (state's `players` array grows).
5. When full, the ready check begins (§6.4): same ready screen as a public match. A friend who does not confirm in time is replaced by a Normal bot; strangers never join a private match.

### 10.5 Private match — guest

1. Receive notification code `1001` with `matchId`.
2. Tap → `rpc join_private_match` → on ok, `socket.joinMatch(matchId)`.

### 10.6 During a turn

1. On `TURN_CHANGE (102)`, if `activePlayer == self`, start a local countdown to `turnDeadline`.
2. User picks one action → send op 1/2/3/4 with payload.
3. If server replies with `ACTION_REJECTED (103)` → show toast and let user retry.
   Grey out takes that would exceed 10 coins up front so `coin_limit` is rare.
4. Wait for new `STATE_FULL` + `TURN_CHANGE`. There is no coin-return step.
5. If the player has no legal move at all (10 coins, 3 reserved, nothing
   affordable), say so: the turn passes when the clock runs out and is **not**
   counted as a missed turn.

### 10.7 Reconnect

1. App resumes / network returns.
2. `getAccount` → check `activeMatchId`.
3. If non-null → `socket.joinMatch(matchId)`.
4. Receive `STATE_FULL` → render. Optionally send op 7 (`SYNC_REQUEST`) to be sure.

### 10.8 Game end

1. Receive `GAME_ENDED (106)`.
2. Show S12 End Screen with winner + standings + own rating delta (read from history shortly after).
3. Server clears `activeMatchId` automatically; next `get_active_game` returns null.

### 10.9 AI game

1. `rpc create_ai_match { difficulty, aiCount }` -> `matchId`.
2. `socket.joinMatch(matchId)` and play exactly as in an online game. There is
   no ready check: the match starts as soon as you connect, you (seat 0) always
   move first, and `GAME_STARTED` arrives with `firstSeat: 0`.
3. The bot's turns arrive as ordinary `TURN_CHANGE` and `STATE_FULL` messages.
   It pauses between 0.5 s and 1.8 s before moving, so no artificial delay is
   needed in the UI; render its turn the way you render any opponent's.
4. Label bot seats from `players[].isAI` and `players[].aiDifficulty`.
5. Concede with op 6 or `concede_match` to leave, the same as any match.

---

## 11. CONSTANTS & CONFIG

**Everything below now comes from `get_catalog` (§4.0). Fetch it once and cache it; do not hardcode any of these.**

Server-driven values that the client must treat as authoritative:

| Constant | Source | Default |
|---|---|---|
| Public matchmaker timeout | `start_public_search.timeoutSeconds` | 60 s |
| Turn deadline | `STATE_FULL.turnDeadlineMs` and `TURN_CHANGE.deadlineMs` | 90 s windows |
| Server clock | `STATE_FULL.serverNowMs` / `TURN_CHANGE.serverNowMs` | use with the deadline; never the device clock |
| Turn length | `STATE_FULL.turnSeconds` | 90 |
| Win threshold | `STATE_FULL.winThreshold` | 25 for rated games; a private or AI game may be created with 15, 20, 25 or 30 (`winThreshold` on `create_private_match` / `create_ai_match`) |
| Max reserve | `players[].reserve` length cap | 3 |
| Max coins | `config.coinHoldLimit` | 10 — hard block, never exceeded (house rule) |
| Abandon miss limit | rules only | 3 misses → 4th turn auto-loss |
| Ready-check window | `config.readyTimeoutSeconds`, `READY_STATE.readySeconds`; server env `READY_TIMEOUT_SECONDS` | 120 s per human seat |
| Refill window | `config.readyRefillSeconds`; server env `READY_REFILL_SECONDS` | 20 s a public seat is held for a searcher before a bot takes it |
| Ready countdown | `READY_STATE.deadlineMs` / `STATE_FULL.readyDeadlineMs` with `serverNowMs` | never the device clock |

Client-only constants:

| Constant | Notes |
|---|---|
| Element strings | `light`, `water`, `nature`, `fire`, `shadow`, `aether` |
| Tier numbers | 1, 2, 3 |
| Card IDs | `H-01..H-18`, `M-01..M-18`, `E-01..E-18`, `D-01..D-18`, `V-01..V-18` — resolve through `get_catalog`, never a local table |
| Artifact IDs | `A-01..A-10` — likewise |
| Generations | from `config.generations` |
| Avatars | from `config.avatars` |

---

*End of API contract.*
*Source of truth: `runtime/` Go source. Regenerate this file when RPC signatures or op-code payloads change.*
