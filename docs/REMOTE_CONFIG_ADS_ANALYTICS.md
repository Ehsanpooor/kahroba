# Remote config, ad slots and analytics (0.9.4)

The contract between the game server (`runtime/`), the app (`client-godot/`)
and the private admin page (`deploy/admin/`). Ads are switched **off**: the
slots exist and are controlled from the server, no ad SDK is in the app yet.
Analytics are our own: events go to our server's database, nothing goes to a
third party.

## 1. Remote config

Stored by the server in Nakama storage, system-owned: collection `config`,
key `client`. When nothing is stored, the server answers the defaults below
(compiled into `runtime/remote_config.go`). The server keeps the current value
in memory (refreshed when the admin saves, and read once at start).

### RPC `get_client_config` (a signed-in player)

Payload `{}`. Answer (the defaults):

```json
{
  "ads": {
    "enabled": false,
    "minIntervalSec": 180,
    "adBreakMaxSec": 30,
    "slots": {
      "pregame_online": {"enabled": false},
      "pregame_ai":     {"enabled": false},
      "postgame":       {"enabled": false}
    }
  },
  "minVersion": "0.9.3",
  "latestVersion": "0.9.4",
  "updateUrl": "https://cafebazaar.ir/app/ir.aizood.splendor",
  "updateMessage": {"fa": "", "en": ""},
  "announcement": null,
  "ratePrompt": {"enabled": true, "afterWins": 2},
  "analytics": {"enabled": true, "flushSec": 30}
}
```

- `announcement`, when set: `{"id": "2026-11-01-a", "fa": "…", "en": "…"}`.
  The app shows it once per id, on the menu.
- A slot shows an ad only when `ads.enabled` and the slot's `enabled` are both
  true, and no ad was shown in the last `minIntervalSec` seconds.
- Versions compare as dotted numbers (`0.9.10` > `0.9.9`).

## 2. Ad slots

| slot | where | who decides |
|---|---|---|
| `pregame_online` | online and friends' games: after everyone pressed Ready, before play | the server (ad break, below) |
| `pregame_ai` | a game against the computer, before the table opens | the app |
| `postgame` | leaving the results screen | the app |

App side: autoload `Ads` (`scripts/ads.gd`), `await Ads.show(slot) -> bool`
(true when an ad was actually shown). With no ad SDK it returns `false` at
once. It records an `ad_slot` event either way.

### The online ad break

When every seat of a table is ready and the config has `ads.enabled` and
`slots.pregame_online.enabled`, the server does not start at once:

1. It sends **op 110 `AD_BREAK`** to the table: `{"deadlineMs": <unix ms>}`,
   now + `adBreakMaxSec`.
2. Each app shows its ad (`Ads.show("pregame_online")`), then sends
   **op 9 `AD_DONE`** (payload `{}`), also when no ad was shown.
3. The server starts the game when every human seat (not AI, not persona) has
   sent `AD_DONE`, or at the deadline. A seat that leaves meanwhile is treated
   as in the ready check.

With the slot off nothing changes: the game starts the moment all are ready.

## 3. Analytics

### RPC `track` (a signed-in player)

```json
{
  "device": {"appVersion": "0.9.4", "platform": "Android", "os": "14",
             "model": "SM-A546E", "locale": "fa", "sessionId": "…"},
  "events": [
    {"n": "game_end", "t": 1761120000000, "p": {"mode": "ai", "won": true}}
  ]
}
```

- At most 50 events a call; `n` matches `^[a-z][a-z0-9_]{1,39}$`; `p` is a JSON
  object of at most 2048 bytes; `t` is unix ms (the server keeps it if within
  the last 7 days, else uses its own time). Bad events are dropped, the rest
  kept; the answer is `{"accepted": N}`.
- The server stores each event in the Postgres table `analytics_events`
  (`at timestamptz, user_id uuid, name text, props jsonb, app_version text,
  platform text, device text`), created at module start if missing, with
  indexes on `(name, at)` and `(user_id, at)`.
- A player sends at most 2000 events a day; more are dropped.

### Events the app sends

| event | props |
|---|---|
| `app_open` | `first` (bool: the first open on this device) |
| `session_end` | `sec` (seconds in the app) |
| `screen` | `name` |
| `game_start` | `mode` (ai / online / friends / tutorial), `players`, `difficulty`, `win` |
| `game_end` | `mode`, `players`, `difficulty`, `won`, `place`, `points`, `rounds`, `sec`, `quit` (bool) |
| `search_start` / `search_found` / `search_cancel` | `players`, `sec` (waited) |
| `room_create` / `room_join` | `players` |
| `tutorial_start` / `tutorial_done` | |
| `email_linked` / `account_recovered` | |
| `ad_slot` | `slot`, `shown` (bool) |
| `update_prompt` | `forced` (bool), `accepted` (bool) |
| `rate_prompt` | `accepted` (bool) |
| `error` | `msg`, `file`, `line` (script errors, at most 20 a session, each message once) |
| `crash` | `log` (the end of the previous session's log, at most 4 KB; sent on the next start when the previous session did not close cleanly) |

### Events the server records itself

`online_match_start` (`players`, `humans`, `personas`, `rated`, `public`),
`online_match_end` (`reason`, `rounds`, `sec`), `table_filled` (`sec`:
first player seated → full, `humans`), `table_left_before_fill`.

## 4. The admin page

`https://splendor.aizood.ir/admin/`, behind nginx basic auth (user `admin`,
password made on the server at the first deploy, kept in `/opt/splendor/.env`
as `ADMIN_PASSWORD`). nginx forwards `/admin/api/<rpc>` to
`/v2/rpc/<rpc>?http_key=<NAKAMA_HTTP_KEY>&unwrap`, so the key never reaches
the browser. Admin RPCs refuse any call that comes with a player session.

- `admin_stats` `{"days": 30}` → totals (players, events, games), daily active
  players and new players per day, retention D1/D7/D30, games by mode, online
  searches (count, median and average wait, left before a table filled), ad
  slots (reached, shown), app versions, top devices, recent errors and crashes
  (message, count, last seen, version).
- `admin_get_config` → the config. `admin_set_config` (the whole config) →
  validated, stored, used at once.
