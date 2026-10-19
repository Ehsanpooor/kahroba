# Splendor client (Godot 4.7)

A Splendor-style gem-merchant game for the Iran market. **Persian is the main
language** (English in Settings); every number is shown with English digits.
Landscape, 3D table, no server yet.

## Run
- `play.cmd`: play against simulated opponents.
  - Your turn: tap gem piles (3 different, or 2 of one colour when the pile has 4+), Done / Undo;
    or tap a card to see it big with **Buy / Reserve**; tap a deck (I / II / III) to reserve blind;
    tap your reserved cards (in your tray) to buy them.
  - Tap an opponent's panel (or your own portrait) for their sheet, a noble for its details.
- `play.cmd demo`: watch a scripted sequence.
- Test flags after `--`: `--board --no-intro`, `--lang=en`, `--test=inspect|noble|sheet|results|confirm|buy`,
  `--shot=<file.png> --shot-at=<seconds>` (save a screenshot and quit; also works with `--screen=...`).

The renderer is **Compatibility** (WebGL2), so the same build runs on web, Android and iOS.

## The table (landscape, 1920 x 1080 design px)
Nobles hang from the top edge (hover / tap slides one down), opponents sit down the left, the
three levels (III on top) with their decks fill the middle, the gem piles stand in one column
beside the cards, and your tray runs along the bottom (bonus cards + tokens per colour, then your
reserved cards). Everything on the table is a simple 3D shape with art on it; panels and buttons
are drawn by one shader (`gui_box`), not pictures.

| file | what |
|---|---|
| `scripts/board.gd` | scene, layout, turn loop + rules, computer opponents, all table animations |
| `scripts/table_layout.gd` | design px -> screen -> table (the camera's tilt) |
| `scripts/table_hud.gd` | 2D layer: opponent panels, your score, turn pill + clock, buttons, dialogs |
| `scripts/sp_card.gd` | a development card: rounded slab, hover tilt, deal + flip, lift, reveal flight |
| `scripts/chip_stack.gd` | a pile of gem tokens (bank and yours) |
| `scripts/noble_tile.gd` / `deck_stack.gd` | nobles, face-down decks |
| `scripts/gems.gd` | gem colours, art paths, gem icon + cost pip |
| `scripts/lang.gd` | every text in Persian and English (`L.t("key")`) |

## Art
Generated art lands in `../art/generated/` (tokens, gems, cards, card_backs, nobles, table).
`python tools/prepare_splendor.py` resizes it into `assets/splendor/`. Every piece has a drawn
stand-in, so the table works before its picture exists. The art is original: never copy the
published Splendor art.

---

## Older notes (Veynoria, portrait)
# Veynoria client (Godot 4.7)

2.5D feel test of the game board. No game rules or backend yet.

## Run
- `play.cmd`: play against three simulated opponents (core Splendor rules, no server yet).
  - Your turn: tap bank coins (3 different, or 2 of one colour when the bank has 4+),
    or tap a card to see it big with **Buy / Reserve**, or tap a deck (I / II / III) to reserve blind.
  - Tap any player (top bar, their panel, or your own avatar) for their full sheet, including their Jail.
  - Drag or use the mouse wheel to scroll. The view follows the turn. The gold chevron shows every opponent.
- `play.cmd demo`: watch a scripted sequence.
- Or open the folder in the Godot editor and press F5.

The renderer is **Compatibility** (WebGL2), so the same build runs on web, Android and iOS.
The page fits the screen width and scrolls, so it works on any phone shape.

## Art pipeline
Raw art lives in `C:\projects\veynora gmae\assets` (art made for the game goes in its `generated\` folder).
`python tools/prepare_assets.py` turns it into `assets/`. It cuts out the portraits, records where each head sits,
resizes everything, and prefers `generated\` files over crops taken from the mockup.
Requirements are in `tools/requirements.txt`.

## Layout
`scripts/layout.gd` maps the iPhone mockup (872 × 2000) onto the tilted 3D table. Positions in
`scripts/board.gd` are therefore mockup pixels, and you can read them straight off the design.

| file | what |
|---|---|
| `scripts/board.gd` | scene, turn loop + rules, simulated opponents, scrolling, demo |
| `scripts/card.gd` | card: head-aligned portrait behind its bracket, big pips; inspect, flight, dissolve-in |
| `scripts/coin_spot.gd` | one 3D coin + count (bank and player) |
| `scripts/noble.gd` | floating noble objects |
| `scripts/hud.gd` | sticky top bar + turn ring, opponent panels (collapsed / expanded), banner, toasts, player sheet |
| `scripts/card_view.gd` | the card drawn in 2D, for the player sheet |
| `scripts/portrait_meta.gd` | generated: where each figure's head sits, for alignment |
| `shaders/` | table, art, pips, coins, fog, glow, panel, dim, post |
