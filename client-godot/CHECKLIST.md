# Veynoria Godot client — screens checklist

Style: the "bronze frames, subtle gems, clear hierarchy" button sheet
(`ChatGPT Image Jun 5, 2026, 12_40_42 PM.png`). Dark navy/charcoal, aged gold,
small blue gems. Simple screens: one clear main action per screen, big text,
nothing that needs explaining twice. All text on art is fitted to its area
(shrink, then "…").

Legend: `[ ]` todo · `[~]` in progress · `[x]` done · **art** = waiting on ChatGPT ·
**server** = needs backend work

## 0. App shell
- [x] App router: splash → (first run: name + avatar → tutorial) → main menu → screens → game → results → menu
- [x] Screen transitions (fade + slight rise), Android/browser back = previous screen
- [x] Settings saved on the device (`user://settings.cfg`)

## 1. Opening logo (splash)
- [x] Dark background, the gem crest drops in, VEYNORIA gold letters shine across, "THE GREAT MUSTER" fades in
- [x] Tap to skip; goes to the menu (≈2.5 s)
- Art: `logo name.png` + crest `ChatGPT Image Jun 6 … 02_57_43 AM (1).png` (ChatGPT logos spell it "TEIE", not used)

## 2. Main menu
- [x] Castle background (`ChatGPT Image Jun 5, 2026, 11_57_14 PM.png`), slow cloud drift
- [x] Top: profile medallion + name + rating (tap → profile), settings gear
- [x] Crest + VEYNORIA + THE GREAT MUSTER
- [x] PLAY (big gold) · HOW TO PLAY · LEADERBOARD · MATCH HISTORY (dark bronze)
- [ ] (server) "Continue game" in place of PLAY when a match is still running (server `get_active_game`)
- [x] Bottom element strip (6 coins) as decoration
- Left out on purpose (not in our game): campaign, heroes, inventory, shop, quests, daily reward, guild

## 3. Choose play
- [x] Three big feature panels: **Play Online** (rated) · **Play vs Computer** · **Play with Friends**
- [x] Online: players 2 / 3 / 4 → Find match (plays the offline table with the ready check until the client is connected; searching screen comes with the server)
- [x] Computer: opponents 1 / 2 / 3 · difficulty Easy / Normal / Hard → Start
- [~] Friends: players 2 / 3 / 4 → pick friends → invite (needs friends list; placeholder until server is connected)
- [x] Each panel says the rules in one line: "90 s per turn · first to 15 Power"
- Turn time is fixed at 90 s on the server (`TURN_SECONDS`), so it is shown, not chosen. A time choice would be **server** work.

## 4. Settings
- [x] Default board view: Normal / Names / Board only
- [x] Brightness slider (whole game)
- [x] Music volume, sound volume, vibration on/off
- [x] Show move confirmations (Skip, short take, blind jail) on/off
- [x] 3D artifacts on/off (low-end phones)
- [x] Replay tutorial, How to play, About / version

## 5. How to play (rules, swipe pages)
- [x] 1 Goal: first to 15 Power, the round finishes
- [x] 2 Your turn: one action — take coins, hire, or send to jail
- [x] 3 Coins: 3 different, or 2 the same (pile of 4+); 10 coins is the limit
- [x] 4 Hiring: pay the cost; owned characters are permanent discounts
- [x] 5 Jail: hold up to 3, get 1 gold; blind jail from a deck
- [x] 6 Artifacts: visit you automatically when you meet them, +3 Power
- [x] 7 Timer & leaving: 90 s, 3 missed turns allowed, 4th = loss
- Pictures built from the real game pieces (coins, cards, artifacts), not separate art

## 6. Tutorial (first install, on the real board)
- [x] Guide character + speech panel, a glowing hand points at what to tap
- [x] Scripted board: take 3 coins → take 2 → hire → jail → artifact arrives → win
- [x] Board is locked except the highlighted thing; Skip tutorial button
- [x] Shown once on first run; replay from Settings

## 7. Leaderboard
- [x] Top 100 by rating; gold/silver/bronze medals for 1–3; your row pinned at the bottom
- [ ] (server) Provisional players are not listed
- [x] Offline sample data until the client is connected

## 8. Match history + replays
- [x] List: result (win/loss), Power, rating change, players, date, Online/Computer
- [x] Last 3 games open as **replays**: step through every move, see who did what (coins, hires, jails, artifacts), play/pause, speed
- [x] Local games record every move (newest 3 kept); replay screen with a filter per player
- [ ] **server**: record each match's move log; keep the last 3 per player; RPC `get_match_replay`

## 9. In-game
- [x] Player count 2–4 (bank 4/5/7, artifacts players+1), computer difficulty, your name and portrait
- [x] Profile screen: name, portrait, rating, games, wins
- [x] Prev / next arrows on the player-info dialog (cycle through all players)
- [x] Prev / next arrows on the artifact dialog (cycle through all artifacts)
- [x] Burger menu (top-left): Resume · How to play · Settings · Board view · Report player · **Leave game** (warning: rated loss, seat stays and is skipped)
- [ ] Absent players: "Away – 2 of 3 missed" badge on their panel, "removed" message
- [ ] 10 s turn warning (pulse + sound), reconnecting banner
- [x] Results screen (`results_scroll.png`): winner, standings, Power, rating change → Play again / Menu

## 10. Art asked from ChatGPT (→ `C:/projects/veynora gmae/assets/generated/ui/`)
- [x] **art** buttons, no text: gold (primary), dark bronze, blue, green, red
- [x] **art** icon medallion ring + ~20 gold icons
- [ ] **art** title plaque (screen headers), list row plate, rank medals
- [ ] **art** three feature panels: online, computer, friends
- [ ] **art** slider track + gem knob, toggle on/off, segment chip
- [ ] **art** tutorial guide bust, speech panel, pointing hand
- [ ] **art** victory / defeat banners

## 11. First start (added 17 Oct)
- [x] Name → clan (Humans, Merfolk, Elves, Dragonkin, Void Born) → portrait from the clan's characters, or your own photo
- [x] `play_fresh.cmd` / Settings › Start over: begin as a brand-new player
- [x] Win score 25 (server default too); friends and computer games can play to 15 / 20 / 25 / 30
- [ ] **server**: store an uploaded photo (only on the device for now; the server accepts preset avatars only)
