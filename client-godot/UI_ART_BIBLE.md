# UI art bible — "The Merchant's Cabinet"

Hi ChatGPT. The host wants a **world-class, premium mobile game UI** for everything outside the board (menus, settings, lists, every dialog) and for the in-game buttons and dialogs. **Every UI element must be painted for its own exact shape and use.** No reusing a button plate as a square, no stretching, no flat boxes, no glow effects. The host's button set is the style anchor: `C:\projects\splendor version\new gen\splendor_buttons_transparent_75_assets\`.

### 1. Art direction (applies to every asset)
- **Concept:** the cabinet of a rich Renaissance gem merchant. Every surface is a precious material, every frame is gilded brass, and every state is shown by a cut gem.
- **Material hierarchy (always the same meaning):**
  - **Gilded brass**: structure (frames, rims, filigree). Warm gold `#E7C477` with deep `#8A5A1C` shadows, crisp bevels, small engraved scrollwork. Never shiny chrome.
  - **Onyx leather** `#141414`: neutral surfaces and secondary buttons.
  - **Emerald leather** `#0F3D25`: the main action and "on" states.
  - **Ivory marble** `#EFE6D2` with faint gold veins: reading surfaces and selected states.
  - **Sapphire** `#1B3F9E` for information and titles; **ruby** `#9E1420` for cancel, close and danger.
  - **Cut gems** (faceted, small, set in gold claws): accents and markers only. Don't scatter them everywhere.
- **Light:** one warm key light from the top-left on everything; consistent bevel direction. Soft contact shadows under raised parts, painted *inside* the asset's own bounds.
- **Finish:** painterly-realistic, crisp at phone size, rich but calm. Detail lives in the frames; centres stay plain where text or content goes.
- **Never:** text, letters, numbers, outer glows or bloom halos, neon, chrome, emoji style, cartoon outlines.

### 2. Format rules
Transparent PNG (except backgrounds). **Exact sizes below.** Leave **12 px of fully transparent padding** around every piece. Save to `C:\projects\splendor version\art\generated\ui3\<name>.png`, never overwrite (`_v2` for a redo), and report after each group.
**9-slice pieces:** the corners hold all the ornament, the edges between corners repeat evenly (plain rim only, nothing unique), and the centre is plain. I state the corner size for each.

### 3. Assets

**A. Dialog system (most important)**
1. `dialog_body.png`, 1024×1024, **9-slice with 140 px corners**. An onyx-leather panel inside a gilded rim (about 26 px), each corner a filigree cluster with one small cut gem. The edges are a plain repeating rim, the centre plain onyx leather with a subtle vignette.
2. `dialog_header.png`, 1400×260. A crest that sits across the top edge of a dialog. In the centre, an **empty** sapphire-enamel title plaque, about 760×120, with gold borders. A large faceted ruby above it in a gold claw setting. Gilded scrollwork wings fade out symmetrically to both sides, transparent beyond.
3. `dialog_footer.png`, 1000×120. A low, symmetrical gilded scroll band with one small emerald in the middle.
4. `btn_close.png`, 200×200. A round ruby cabochon in a gold rim, with **no ✕** (I draw the ✕).

**B. Buttons that must not stretch** (each painted at its final shape)
5. `btn_round_onyx.png` and `btn_round_emerald.png`, 220×220. A round button: a gold rim around a domed onyx or green-leather centre. The centre is plain for an icon.
6. `btn_square_onyx.png`, 220×220. A rounded-square onyx-leather button with gold corners, for arrows and small icon actions.
7. `btn_arrow_left.png` and `btn_arrow_right.png`, 220×220. **Complete** round gold-framed onyx buttons with an engraved gold chevron already painted in. These are the "previous" and "next" buttons.
8. `btn_back.png`, 220×220. A round onyx button with a painted gold back arrow (for the top-left of every screen).

**C. Choice controls**
9. `tab_on.png` and `tab_off.png`, 520×150, **9-slice with 90 px corners left and right**. *On*: ivory marble with two small emerald studs at the ends. *Off*: onyx leather with small gold studs.
10. `toggle_on.png` and `toggle_off.png`, 360×170. A complete pill switch with a gold frame. *On*: the green-leather track with an emerald knob on the right. *Off*: the onyx track with an ivory-marble knob on the left.
11. `slider_track.png`, 1000×90, **9-slice with 60 px ends**: an onyx groove in a gold frame. `slider_fill.png` is the same with the groove filled with green enamel. `slider_knob.png`, 170×170: a cut emerald in a gold claw setting.
12. `input_field.png`, 1200×170, **9-slice with 80 px ends**: an ivory-marble text field in a thin gold frame, with an inner shadow at the top.

**D. Lists, titles, badges**
13. `row_onyx.png` and `row_ivory.png`, 1800×190, **9-slice with 120 px ends**: a list row plate with a gold rim, small gems only in the end caps, and a plain middle.
14. `title_ribbon.png`, 1500×230. A screen-title banner: a sapphire-velvet ribbon with gold trim and folded ends, plain in the middle for the title.
15. `medal_1.png`, `medal_2.png` and `medal_3.png`, 240×240: round gold, silver and bronze medallions, each set with a gem, with laurel. No numbers.
16. `badge_win.png` and `badge_loss.png`, 300×150: a small emerald (win) or ruby (loss) enamel plaque in gold. Plain, for a word.
17. `avatar_frame.png`, 400×400: a round gilded portrait frame with filigree. The centre circle is fully transparent (about 76% of the width).
18. `page_dot_on.png` and `page_dot_off.png`, 64×64: a tiny emerald and a tiny onyx gem in gold settings.

**E. Illustrated tiles** (with content, not transparent inside)
19. `mode_online.png`, `mode_computer.png` and `mode_friends.png`, 600×760 portrait tiles inside a gilded frame. The upper 60% is a painting:
   - online: a merchants' exchange hall full of traders at night with lanterns, a globe;
   - computer: a brass clockwork automaton merchant at a gem table;
   - friends: two merchants toasting over a candle-lit table.
   The **lower 40% is plain onyx leather** (the title goes there).
20. `logo_emblem.png`, 900×700: the game's emblem, a gilded crest holding five large cut gems (diamond, sapphire, emerald, ruby, onyx) fanned in an arc, with laurel. No letters; the name is set below it in type.

**F. Icons**, 256×256 each, engraved gold with a dark edge, consistent weight, centred, transparent:
`icon_settings` (gear), `icon_book`, `icon_trophy`, `icon_scroll`, `icon_person`, `icon_door`, `icon_music`, `icon_sound`, `icon_vibrate`, `icon_globe`, `icon_home`, `icon_friends`, `icon_knight` (chess knight), `icon_exchange` (a globe with gem points), `icon_menu`, `icon_replay`, `icon_crown`, `icon_gem`.

**G. Backgrounds** (not transparent):
21. `menu_bg.png`, 2400×1080: a dim, warm gem merchant's hall at evening (a long table with gems, scales and ledgers, a window to a canal city). The **left 45% is darker and calm**, for the menu.
22. `screen_bg.png`, 2400×1080: dark green leather with gold tooling around the edges and a soft centre. Calm.

**Order:** A, B, C, D, F, E, G. Groups A and B unblock the most screens. Thank you!
