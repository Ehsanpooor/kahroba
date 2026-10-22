extends Node3D
## The Splendor table, landscape, in 3D: nobles hang from the top edge,
## opponents sit down the left, the three levels of development cards (with
## their decks) fill the middle, the gem tokens stand in one column beside
## the cards, and your own area is the tray along the bottom.
##
## Rules (as the server, runtime/rules.go): take 3 different gems, or 2 of
## one colour when the pile has 4+, never going above 10 tokens; or buy a
## card (bonuses count as gems for ever); or reserve one (max 3, +1 gold when
## you have room). Nobles visit whoever has their bonuses (+3). Reaching the
## target prestige (15 by default) starts the final round.
##
## Test flags (after `--`): --demo (scripted run), --no-intro,
## --shot=<file.png> [--shot-at=<seconds>] save a screenshot and quit.

const MAX_COINS := 10
const RESERVE_MAX := 3
const WIN_DEFAULT := 15  # a game against the computer
const WIN_ONLINE := 18  # rated online games (the server's WIN_THRESHOLD)
const TIER_OF_ROW := [1, 2, 3]  # level I on top

# --- layout: measured on the host's design (new gen/Frame 45.png, PNG px),
# converted with K to table design px ---
const K := 1080.0 / 1221.0
const BOARD := Rect2(807.0 * K, 84.0 * K, 1518.0 * K, 786.0 * K)  # "board with hole"
const SLOT := Vector2(255.0 * K, 187.0 * K)  # a carved stone card place
const COLS_X := [1176.5 * K, 1479.0 * K, 1785.0 * K, 2082.0 * K]
const ROWS_Y := [270.0 * K, 480.0 * K, 696.0 * K]  # level I, II, III
const CARD_K := 258.0 * K / 280.0  # a card (82 x 60) covering its carved place
const HOLE := Vector2(67.0 * K, 192.0 * K)  # the deck holes
const DECK_X := 944.5 * K
const DECK_ROWS := [265.0 * K, 480.5 * K, 696.0 * K]
const CARD_AREA_X := 1629.5 * K
const NOBLE_Y := -6.0  # tile centre: only its lower part shows, above the board's top border
const NOBLE_STEP := 196.0
## The token piles, top to bottom as the design: white, black, blue, red, green, gold.
const BANK_ORDER := ["white", "black", "blue", "red", "green", "gold"]
const BANK_X := 2422.0 * K
const BANK_Y0 := 188.0 * K
const BANK_STEP := 120.0 * K
const BANK_R := 46.5 * K
const BANK_LEAN := 14.0  # degrees the piles lean back, so their sides show as in Frame 45
const STAGE_Y := 912.5 * K
## Tokens being taken line up beside the piles, top to bottom.
const STAGE_X := 2318.0 * K  # between the board and the piles
const STAGE_TOP := 250.0 * K
const STAGE_STEP := 205.0 * K
const STAGE_R := 50.0  # bigger than the tokens in the piles: they are what you are taking
const FAN_Y := 483.0 * K  # your reserved cards, fanned out over the middle
const CAM_TILT := 30.0  # the board seen from a little in front: its thickness and pits show
const BOARD_T := 40.0  # the marble board's thickness (design px)
const PIT_FLOOR := 3.0  # how high the floor of a deck hole sits above the table
## The deck holes on the board picture (fractions of board.png).
const HOLES_UV := [Vector4(0.0686, 0.1088, 0.0441, 0.2438), Vector4(0.0686, 0.3827, 0.0441, 0.2438),
		Vector4(0.0686, 0.6566, 0.0441, 0.2438)]
const CAM_FOV := 32.0
const CAM_DIST := 40.0

## The tutorial listens to what happens and may limit what can be tapped.
signal tut_event(kind: String, data: Variant)
var tut_gate := Callable()
const TUT_CARD := "V-05"  # Shade (black, level I): green 2 + red 1, affordable after the two coin turns
const TUT_INDEX := 0  # level I row, first place

# --- game state (survives a rebuild) ---
var bank_counts := {"white": 7, "blue": 7, "green": 7, "red": 7, "black": 7, "gold": 5}
var me := _new_player("", "M-04", 1000)
var opps: Array = []
var board_cards: Array = []  # 12 card dicts ({} = empty), index = row * 4 + col (row 0 = level III)
var decks := {1: [], 2: [], 3: []}
var noble_data: Array = []
var noble_owner: Array = []
var final_round := false
var mode := "ai"
var win_points := WIN_DEFAULT
var difficulty := "normal"
var moves: Array = []
var round_no := 0
var first_seat := 0
var turn := -1
var picks: Array = []
var game_over := false
var intro_running := false

# --- scene ---
var cam: Camera3D
var layout: TLayout
var U := 0.02
var ZS := 1.0  # flat things are stretched this much along the table, so the tilted camera shows them at design size
var world_root: Node3D
var hud: TableHud
var pointer_light: OmniLight3D
var dim: MeshInstance3D
var cards: Array[SCard] = []
var nobles: Array[NobleTile] = []
var deck_nodes := {}
var bank := {}
var fan: Array[SCard] = []  # your reserved cards while they are fanned out
var staged: Array = []  # tokens over the middle: {col, node, landed, x}
var inspecting: SCard = null
var _inspect_reserve := -1
var _busy := 0
## Bumped whenever the table is built again (a reconnect, a language change):
## an animation started on the old table no longer counts in _busy, so one
## cut short by the rebuild cannot leave the board busy for good.
var _gen := 0
var _dim_alpha := 0.0
var _lobby_node: Lobby
var _overlay_screen: Control

# --- input ---
var pointer := Vector2(-9999, -9999)
var pointer_inside := false
var press_pos := Vector2.ZERO
var press_target: Variant = null
var demo := false
var resumed := false  # a saved game was put back on the table
var net: NetGame = null  # an online game: the server runs it (net_game.gd)
var match_id := ""  # the server match of an online game
var _net_down := false  # an online game lost the server: paused until it is back
var _down_at := 0.0
var _rebuild_pending := false
var paused := false  ## a game against the computer is paused (pause_game)
var _paused_at := 0.0
var _started_at := 0.0  ## when play began (ticks, s): game_end's "sec"


func _ready() -> void:
	randomize()
	var args := OS.get_cmdline_user_args()
	demo = args.has("--demo")
	_apply_game_config()
	if Prefs.game.get("net", false) and not demo:
		match_id = String(Prefs.game.get("match_id", ""))
		net = NetGame.new()
		net.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(net)
		net.attach(self)
		if not await net.first_state():
			_to_menu()
			return
		net.apply_full()
		Prefs.game.erase("resume")
		if Prefs.game.get("joined_room", false):  # a friend's room, joined with its code
			Prefs.game.erase("joined_room")
			Analytics.event("room_join", {"players": int(net.state.get("expectedPlayerCount", net.n))})
	var saved := SavedGame.read() if Prefs.game.get("resume", false) else {}
	Prefs.game.erase("resume")  # Play again starts a new game
	if not saved.is_empty() and not demo:
		_resume(saved)
	_setup_world()
	Sfx.music(true, "game")
	if not resumed and net == null:
		_setup_cards()
	if mode in ["online", "friends"]:
		Net.in_game = true
		Net.changed.connect(_on_net_changed)
	var post_layer := CanvasLayer.new()
	post_layer.layer = 1
	add_child(post_layer)
	var post := ColorRect.new()
	post.set_anchors_preset(Control.PRESET_FULL_RECT)
	post.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pm := ShaderMaterial.new()
	pm.shader = preload("res://shaders/post.gdshader")
	pm.set_shader_parameter("vignette", 0.45)
	post.material = pm
	post_layer.add_child(post)
	var hud_layer := CanvasLayer.new()
	hud_layer.layer = 2
	add_child(hud_layer)
	hud = TableHud.new()
	hud_layer.add_child(hud)
	hud.buy_pressed.connect(_on_buy_pressed)
	hud.reserve_pressed.connect(_on_reserve_pressed)
	hud.close_inspect.connect(close_inspect)
	hud.skip_pressed.connect(skip_turn)
	hud.undo_pressed.connect(undo_pick)
	hud.done_pressed.connect(done_picking)
	hud.time_up.connect(_on_time_up)
	hud.menu_pressed.connect(open_menu)
	await get_tree().process_frame
	_build()
	get_viewport().size_changed.connect(_on_resized)
	_shot_if_asked()
	if net:
		await net.run_intro()
		if net.is_ended():
			return
		if not args.has("--no-intro"):
			await _opening()
		_track_start()
		net.start()
		if args.has("--autoplay"):
			_autoplay()
		return
	if args.has("--no-intro"):
		await get_tree().create_timer(0.3).timeout
	else:
		await _opening()
	_track_start()
	_pause_if_asked(args)
	if resumed:
		hud.toast(L.t("rejoined") if SavedGame.is_online({"mode": mode}) else L.t("continued"))
		start_turn(turn, true)
		return
	var table_game := mode in ["online", "friends"]
	first_seat = randi() % (opps.size() + 1) if table_game and not demo else 0
	if not args.has("--no-intro") and table_game:
		await _lobby().choose_starter([me] + opps, first_seat)
	start_turn(first_seat)
	if args.has("--autoplay") and not demo:  # test: your moves play themselves (videos, checks)
		_autoplay()
	if mode == "tutorial":
		var tut := Tutorial.new()
		add_child(tut)
		tut.start(self)
	if demo:
		_run_demo()
	for a in args:
		if a.begins_with("--test="):
			_run_test(a.get_slice("=", 1))


## --shot=<file> [--shot-at=<s>[,<s>...]]: save what is on screen, then quit
## (checks). Several times: one file each, <file>_<s>.png.
func _shot_if_asked() -> void:
	var path := ""
	var times := PackedStringArray(["6"])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			path = a.get_slice("=", 1)
		elif a.begins_with("--shot-at="):
			times = a.get_slice("=", 1).split(",")
	if path == "":
		return
	var t0 := Time.get_ticks_msec() / 1000.0
	for t in times:
		var wait := float(t) - (Time.get_ticks_msec() / 1000.0 - t0)
		if wait > 0.0:
			await get_tree().create_timer(wait).timeout
		await RenderingServer.frame_post_draw
		var out := path if times.size() == 1 else path.get_basename() + "_" + t + ".png"
		get_viewport().get_texture().get_image().save_png(out)
	get_tree().quit()


# ------------------------------------------------------------------ setup

func _apply_game_config() -> void:
	var g: Dictionary = Prefs.game
	mode = String(g.get("mode", "ai"))
	difficulty = String(g.get("difficulty", "normal"))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--difficulty="):  # test: the computer's level
			difficulty = a.get_slice("=", 1)
	win_points = int(g.get("win_points", WIN_DEFAULT))
	if mode == "online":
		win_points = WIN_ONLINE
	elif not (win_points in [15, 18, 21, 25, 30]):
		win_points = WIN_DEFAULT
	var n := clampi(int(g.get("players", 4)), 2, 4)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--players="):  # test: a bigger table (friends' rooms seat up to 6)
			n = clampi(int(a.get_slice("=", 1)), 2, 6)
	if mode == "tutorial":  # against Cosimo the guide, no clock
		difficulty = "easy"
		n = 2
		win_points = 15
	if demo:
		mode = "ai"
		n = 4
	if OS.get_cmdline_user_args().has("--online"):  # test: an online table
		mode = "online"
	var mine_portrait := String(Prefs.get_v("portrait"))
	me = _new_player(Prefs.display_name(), mine_portrait, int(Prefs.get_v("rating")))
	# the computer players: merchants drawn at random, never in your own face
	var pool: Array = Portraits.BOTS.filter(func(b): return b != Portraits.resolve(mine_portrait))
	pool.shuffle()
	var styles: Array = AIBrain.STYLES.keys()  # each opponent its own way of playing
	styles.shuffle()
	opps = []
	for k in n - 1:
		var bot: String = pool[k]
		var face: String = bot if Portraits.available() else Portraits.BOT_FALLBACK[k % 4]
		if face == mine_portrait:
			face = Portraits.BOT_FALLBACK[3]
		var p := _new_player(L.t("bot_" + bot), face, [1080, 1150, 990][k % 3])
		p["bot"] = bot
		p["style"] = styles[k % styles.size()]
		opps.append(p)
	if mode == "tutorial":
		opps = [_new_player(L.t("guide_name"), Portraits.guide(), 1200)]
	# Splendor's bank: 4 of each colour for 2 players, 5 for 3, 7 for 4; gold 5.
	# The Iranian 5- and 6-player table: 8 and 9, and a gold more per player.
	var per: int = {2: 4, 3: 5, 4: 7, 5: 8, 6: 9}[n]
	for c in Gems.COLORS:
		bank_counts[c] = per
	bank_counts["gold"] = 5 + maxi(n - 4, 0)
	Prefs.changed.connect(_on_pref_changed)


func _on_pref_changed(key: String) -> void:
	if key == "lang":
		for q in opps:
			if q.has("bot"):
				q["name"] = L.t("bot_" + String(q["bot"]))
			elif mode == "tutorial":
				q["name"] = L.t("guide_name")
		me["name"] = Prefs.display_name()
		_build()


static func _new_player(n: String, portrait: String, rating: int) -> Dictionary:
	return {
		"name": n, "portrait": portrait, "rating": rating, "prestige": 0, "nobles": 0,
		"cards": {"white": 0, "blue": 0, "green": 0, "red": 0, "black": 0},
		"coins": {"white": 0, "blue": 0, "green": 0, "red": 0, "black": 0, "gold": 0},
		"reserved": [],
	}


func _setup_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.03, 0.025)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.55, 0.62)
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.glow_enabled = not Perf.mobile  # glow is a full-screen blur: desktop only
	env.glow_intensity = 0.45
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.15
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# a warm key light from the upper left; cards, tiles and tokens cast real shadows
	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.9, 0.76)
	sun.light_energy = 1.05
	sun.rotation_degrees = Vector3(-58, -145, 0)
	sun.shadow_enabled = true
	sun.shadow_opacity = 0.62
	sun.shadow_blur = 1.6
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 90.0
	add_child(sun)

	pointer_light = OmniLight3D.new()
	pointer_light.light_color = Color(1.0, 0.84, 0.6)
	pointer_light.light_energy = 1.4
	add_child(pointer_light)

	cam = Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	# flat (orthographic): every 3D piece shows its height straight up the screen,
	# the same at the edges as in the middle, as in the host's design
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.0 * CAM_DIST * tan(deg_to_rad(CAM_FOV) * 0.5)
	cam.fov = CAM_FOV
	cam.near = 1.0
	cam.far = 300.0
	var tilt := deg_to_rad(CAM_TILT)
	cam.position = Vector3(0, cos(tilt) * CAM_DIST, sin(tilt) * CAM_DIST)
	add_child(cam)
	cam.look_at(Vector3.ZERO, Vector3.UP if CAM_TILT > 0.5 else Vector3.FORWARD)
	ZS = 1.0 / cos(tilt)
	cam.current = true


## Shuffle the deck by level, deal 4 face up per level, reveal players + 1 nobles.
func _setup_cards() -> void:
	for d in GameData.CARDS.values():
		(decks[int(d["tier"])] as Array).append((d as Dictionary).duplicate(true))
	for t in decks:
		(decks[t] as Array).shuffle()
	board_cards.resize(12)
	for r in 3:
		for c in 4:
			board_cards[r * 4 + c] = (decks[TIER_OF_ROW[r]] as Array).pop_back()
	if mode == "tutorial":
		_place_card(TUT_CARD, TUT_INDEX)
	var all: Array = GameData.ARTIFACTS.duplicate(true)
	all.shuffle()
	for a in all.slice(0, opps.size() + 2):
		var nd: Dictionary = a
		nd["id"] = "N-" + String(nd["id"]).substr(2)  # A-03 -> N-03 (one noble per requirement set)
		noble_data.append(nd)
		noble_owner.append("")


## A saved game back on the table: its state, your name and face as they
## are now, the computer players' names in today's language.
func _resume(d: Dictionary) -> void:
	SavedGame.restore(self, d)
	resumed = true
	me["name"] = Prefs.display_name()
	me["portrait"] = String(Prefs.get_v("portrait"))
	for q in opps:
		if (q as Dictionary).has("bot"):
			q["name"] = L.t("bot_" + String(q["bot"]))


# ------------------------------------------------------------------ the connection (online games)

## The server stopped (or started again) answering during an online game:
## the table waits under a "reconnecting" dialog; your seat is kept.
func _on_net_changed(online: bool) -> void:
	if game_over:
		return
	if not online and not _net_down:
		_net_down = true
		_down_at = Time.get_ticks_msec() / 1000.0
		if inspecting:
			close_inspect()
		hud.connection_lost(func():
			_net_down = false
			_to_menu())  # the game stays saved: Rejoin from the menu
		get_tree().paused = true
	elif online and _net_down and (net == null or Api.socket_ready()):
		_net_down = false
		get_tree().paused = false
		hud.turn_started += Time.get_ticks_msec() / 1000.0 - _down_at  # the clock waited too
		hud.close_modal()
		hud.toast(L.t("reconnected"))


func _exit_tree() -> void:
	if mode in ["online", "friends"]:
		Net.in_game = false


## Put a given card face up at board index `idx` (the tutorial).
func _place_card(id: String, idx: int) -> void:
	if board_cards[idx]["id"] == id:
		return
	var tier := int(GameData.CARDS[id]["tier"])
	var deck: Array = decks[tier]
	for k in deck.size():
		if deck[k]["id"] == id:
			var tmp: Dictionary = board_cards[idx]
			board_cards[idx] = deck[k]
			deck[k] = tmp
			return
	for k in board_cards.size():
		if board_cards[k]["id"] == id:
			var tmp2: Dictionary = board_cards[idx]
			board_cards[idx] = board_cards[k]
			board_cards[k] = tmp2
			return


# ------------------------------------------------------------------ build

func _on_resized() -> void:
	if _rebuild_pending:
		return
	_rebuild_pending = true
	await get_tree().create_timer(0.15).timeout
	_rebuild_pending = false
	if _busy == 0 and staged.is_empty():
		_build()


func _build() -> void:
	_gen += 1
	_busy = 0
	staged.clear()  # tokens held up over the old table, and the pick they make up
	picks.clear()
	if world_root:
		world_root.free()
	inspecting = null
	cards.clear()
	nobles.clear()
	bank.clear()
	deck_nodes.clear()
	fan.clear()
	world_root = Node3D.new()
	add_child(world_root)
	var vp := get_viewport().get_visible_rect().size
	layout = TLayout.new(cam, vp)
	U = layout.unit(Vector2(layout.mid(CARD_AREA_X), 540))
	RenderingServer.global_shader_parameter_set("px_unit", U)
	RenderingServer.global_shader_parameter_set("light_center", layout.world(Vector2(layout.mid(CARD_AREA_X), 450)))
	pointer_light.omni_range = 420.0 * U
	_build_table()
	_build_nobles()
	_build_decks()
	_build_cards()
	_build_bank()
	dim = MeshInstance3D.new()
	dim.mesh = Meshes.quad(4000.0, 4000.0)
	var dm := ShaderMaterial.new()
	dm.shader = preload("res://shaders/dim3d.gdshader")
	dm.render_priority = 15
	dim.material_override = dm
	world_root.add_child(dim)
	dim.position = layout.world(Vector2(layout.size.x * 0.5, 540)) + Vector3(0, 140.0 * U, 0)
	dim.scale = Vector3.ONE * U
	dim.visible = false
	_dim_alpha = 0.0
	hud.round_no = maxi(round_no, 1)
	hud.build(layout, me, opps, win_points)
	if turn >= 0:
		hud.set_turn(turn, mode != "tutorial")
	_update_bar()
	_refresh_glows()


func _place(node: Node3D, m: Vector2, k := 1.0, lift_px := 0.0) -> Node3D:
	world_root.add_child(node)
	node.position = layout.world(m, lift_px * layout.unit(m))
	node.scale = Vector3(1.0, 1.0, ZS) * layout.unit(m) * k
	return node


func _build_table() -> void:
	var table := MeshInstance3D.new()
	table.mesh = Meshes.quad(1000.0, 1000.0)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/table2.gdshader")
	var t := _hud_tex("table")
	mat.set_shader_parameter("has_tex", 1.0 if t else 0.0)
	if t:
		mat.set_shader_parameter("tex", t)
		mat.set_shader_parameter("tex_size", t.get_size())
		mat.set_shader_parameter("dim", 1.0)
	mat.set_shader_parameter("vp_size", layout.vp)
	table.material_override = mat
	world_root.add_child(table)
	table.position = layout.world(Vector2(layout.size.x * 0.5, 540)) + Vector3(0, -0.02, 0)
	# the marble board with its deck holes, and a carved place for every card
	_build_board3d()
	var slot := _hud_tex("slot")
	for i in 12:
		var c := _card_pos(i)
		_flat(slot, Rect2(c - SLOT * 0.5, SLOT), BOARD_T + 0.3)


static func _hud_tex(name: String) -> Texture2D:
	var p := "res://assets/splendor/hud/%s.png" % name
	return Tex.get_tex(p) if ResourceLoader.exists(p) else null


## A flat picture lying on the table over a design-px rect, lit like the rest.
func _flat(tex: Texture2D, r: Rect2, lift_px: float) -> MeshInstance3D:
	var a := layout.world(r.position, lift_px * U)
	var b := layout.world(r.end, lift_px * U)
	var mi := MeshInstance3D.new()
	mi.mesh = Meshes.quad(absf(b.x - a.x), absf(b.z - a.z))
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mi.material_override = m
	world_root.add_child(mi)
	mi.position = (a + b) * 0.5
	return mi


func _noble_x(i: int) -> float:
	return layout.mid(CARD_AREA_X) + (i - (noble_data.size() - 1) * 0.5) * NOBLE_STEP


func _build_nobles() -> void:
	for i in noble_data.size():
		var n := NobleTile.new()
		_place(n, Vector2(_noble_x(i), NOBLE_Y), 1.0, BOARD_T + 4.0)
		n.setup(noble_data[i])
		n.visible = noble_owner[i] == ""
		nobles.append(n)


## Each level's deck lies inside its hole in the board.
func _build_decks() -> void:
	for r in 3:
		var t: int = TIER_OF_ROW[r]
		var dn := DeckStack.new()
		world_root.add_child(dn)
		var rim := layout.world(Vector2(layout.mid(DECK_X), DECK_ROWS[r]), BOARD_T * U)
		dn.position = Vector3(rim.x, rim.y + 0.3 * U, rim.z)  # standing in the hole, as the design
		var u := layout.unit(Vector2(layout.mid(DECK_X), DECK_ROWS[r]))
		dn.scale = Vector3(u, u, u * ZS)
		dn.setup(t, (decks[t] as Array).size(), HOLE)
		deck_nodes[t] = dn


## The marble board as a real slab: the painted top (cut open at the deck
## holes), gilded sides all round, and a pit under every hole.
func _build_board3d() -> void:
	var r := Rect2(Vector2(layout.mid(BOARD.position.x), BOARD.position.y), BOARD.size)
	var h := BOARD_T * U
	var a := layout.world(r.position, h)
	var b := layout.world(r.end, h)
	var w := absf(b.x - a.x)
	var d := absf(b.z - a.z)
	var c := (a + b) * 0.5
	var top := MeshInstance3D.new()
	top.mesh = Meshes.quad(w, d)
	var tm := ShaderMaterial.new()
	tm.shader = preload("res://shaders/board_top.gdshader")
	tm.set_shader_parameter("tex", _hud_tex("board"))
	tm.set_shader_parameter("holes", HOLES_UV)
	top.material_override = tm
	top.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world_root.add_child(top)
	top.position = c
	# the sides: the board's outline, a little inside the painted ornaments
	var side := MeshInstance3D.new()
	side.mesh = Meshes.rounded_slab(w * 0.985, d * 0.975, 18.0 * U, h, 4)
	var none := ShaderMaterial.new()
	none.shader = _discard_shader()
	var gilt := StandardMaterial3D.new()
	gilt.albedo_color = Color(0.72, 0.5, 0.2)
	gilt.metallic = 0.7
	gilt.roughness = 0.35
	gilt.emission_enabled = true
	gilt.emission = Color(0.3, 0.2, 0.07)
	side.set_surface_override_material(0, none)
	side.set_surface_override_material(1, none)
	side.set_surface_override_material(2, gilt)
	side.position = Vector3(c.x, 0.0, c.z)
	side.free()  # the host did not want the board's thick edge showing
	# a pit under every hole: dark leather walls and floor
	var wall := StandardMaterial3D.new()
	wall.albedo_color = Color(0.09, 0.2, 0.13)
	wall.roughness = 0.85
	wall.cull_mode = BaseMaterial3D.CULL_DISABLED
	var floor_ := StandardMaterial3D.new()
	floor_.albedo_color = Color(0.03, 0.08, 0.05)
	floor_.roughness = 0.9
	for k in 3:
		var huv: Vector4 = HOLES_UV[k]
		var hc := Vector3(a.x + (huv.x + huv.z * 0.5) * w, PIT_FLOOR * U, a.z + (huv.y + huv.w * 0.5) * d)
		var pit := MeshInstance3D.new()
		pit.mesh = Meshes.rounded_slab(huv.z * w, huv.w * d, 6.0 * U, h - PIT_FLOOR * U, 3)
		pit.set_surface_override_material(0, none)
		pit.set_surface_override_material(1, floor_)
		pit.set_surface_override_material(2, wall)
		pit.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		world_root.add_child(pit)
		pit.position = hc


static var _discard: Shader


static func _discard_shader() -> Shader:
	if _discard == null:
		_discard = Shader.new()
		_discard.code = "shader_type spatial;\nvoid fragment() { discard; }\n"
	return _discard


func _build_cards() -> void:
	for i in 12:
		var c := SCard.new()
		_place_card_node(c, _card_pos(i), CARD_K, BOARD_T)
		var d: Dictionary = board_cards[i] if board_cards[i] else {}
		if d.is_empty():
			c.visible = false
		else:
			c.set_data(d)
		cards.append(c)


## A card is scaled evenly; its own squash layer does the table stretch.
func _place_card_node(c: SCard, m: Vector2, k: float, lift_px: float) -> void:
	_place(c, m, k, lift_px)
	c.scale = Vector3.ONE * layout.unit(m) * k
	c.cam_tilt = deg_to_rad(CAM_TILT)


func _card_pos(i: int) -> Vector2:
	return Vector2(layout.mid(COLS_X[i % 4]), ROWS_Y[i / 4])


func _build_bank() -> void:
	for k in BANK_ORDER.size():
		var col: String = BANK_ORDER[k]
		var sp := ChipStack.new()
		_place(sp, Vector2(layout.right(BANK_X), BANK_Y0 + k * BANK_STEP))
		sp.setup(col, bank_counts[col], BANK_R, Vector2.INF)
		sp.lean(BANK_LEAN)
		sp.plain_count(Vector2(BANK_R * 1.75, 0.0), 54.0 * K, Color(0, 0, 0, 0.78))
		bank[col] = sp


# ------------------------------------------------------------------ opening

func _lobby() -> Lobby:
	if _lobby_node == null or not is_instance_valid(_lobby_node):
		var layer := CanvasLayer.new()
		layer.layer = 5
		add_child(layer)
		_lobby_node = Lobby.new()
		layer.add_child(_lobby_node)
	return _lobby_node


## The table sets itself up in front of you: the nobles drop in from the top,
## the decks slide in, the cards are dealt from them and turn over, the gem
## piles fill up chip by chip, your tray rises and the panels come in.
func _opening() -> void:
	intro_running = true
	if mode in ["online", "friends"] and not resumed and net == null:
		await _lobby().show_ready([me] + opps, demo)
	hud.modulate.a = 0.0
	for n in nobles:
		n.visible = false
	for t in deck_nodes:
		(deck_nodes[t] as Node3D).visible = false
	for c in cards:
		c.visible = false
	for col in bank:
		(bank[col] as ChipStack).set_count(0)
	await _wait(0.35)
	# nobles fall in from above, one by one
	for i in nobles.size():
		var n := nobles[i]
		if noble_owner[i] != "":
			continue  # already visiting someone (a continued game)
		var home := n.position
		n.visible = true
		n.position = home + Vector3(0, 260.0 * U, -220.0 * U)
		n.rotation.z = (randf() - 0.5) * 0.5
		var tw := n.create_tween().set_parallel(true)
		tw.tween_property(n, "position", home, 0.45).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
		tw.tween_property(n, "rotation:z", 0.0, 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		get_tree().create_timer(0.3).timeout.connect(func():
			FX.ring(world_root, home, Color(1.0, 0.82, 0.45), U, 110.0, 0.4))
		await _wait(0.11)
	await _wait(0.3)
	# row by row a deck arrives as a flat stack, deals its four cards from
	# there, then turns up on its edge and sinks into its hole
	Sfx.play("game_start")
	for r in 3:
		_deck_row(r)
		await _wait(1.05)  # the next deck comes in while this one deals
	await _wait(1.7)
	# the gem piles fill up
	for col in Gems.ALL:
		_fill_pile(bank[col], int(bank_counts[col]))
		await _wait(0.08)
	await _wait(0.4)
	# the players arrive: the others from the left, you and the clock from below
	await hud.arrive()
	intro_running = false


## Chips drop onto a pile one at a time until it holds `n`.
func _fill_pile(st: ChipStack, n: int) -> void:
	for k in n:
		var chip := ChipStack.make_chip(st.color)
		world_root.add_child(chip)
		chip.scale = Vector3.ONE * st.world_radius()
		var to := st.top_world()
		chip.global_position = to + Vector3(0, 120.0 * U, 0)
		var tw := chip.create_tween()
		tw.tween_property(chip, "global_position", to, 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		await tw.finished
		st.receive(chip)
		Sfx.play("token_place", -1.0, -8.0)
	FX.ring(world_root, st.global_position, Gems.GLOW[st.color], U, 70.0, 0.35)


# ------------------------------------------------------------------ frame + input

func _process(delta: float) -> void:
	_stage_follow(delta)
	var t := Time.get_ticks_msec() / 1000.0
	if not Perf.mobile:  # the candle flicker; on phones the light stays steady
		RenderingServer.global_shader_parameter_set("flicker", sin(t * 7.3) * 0.5 + sin(t * 13.1) * 0.3 + sin(t * 2.1) * 0.6)
	if _busy > 0 or intro_running or not staged.is_empty() or (turn != 0 and net == null and not game_over):
		Perf.wake(0.5)  # something moves on the table: full frame rate
	if layout == null:
		return
	var hit := layout.screen_to_table(pointer) if pointer_inside else Vector3(0, -100, 0)
	RenderingServer.global_shader_parameter_set("pointer_world", hit)
	pointer_light.visible = pointer_inside
	pointer_light.global_position = hit + Vector3(0, 220.0 * U, 0)
	var free_hover := pointer_inside and inspecting == null and not hud.is_modal() and not intro_running
	var hovered: SCard = null
	if free_hover:
		for c in cards + fan:
			if not c.busy and c.contains_world(_hit_at(pointer, c)):
				hovered = c
	for c in cards + fan:
		c.target_hover = 1.0 if c == hovered else 0.0
		if c == hovered:
			c.tilt_target = c.local_tilt(_hit_at(pointer, c))
	for n in nobles:
		n.target_hover = 1.0 if free_hover and not n.busy and n.contains_world(_hit_at(pointer, n)) else 0.0





func _unhandled_input(e: InputEvent) -> void:
	if hud == null:  # an online table is still arriving
		return
	if e is InputEventKey and (e as InputEventKey).pressed and (e as InputEventKey).keycode == KEY_ESCAPE:
		_back()
		return
	if demo or intro_running:
		return
	if e is InputEventMouseMotion:
		pointer = (e as InputEventMouseMotion).position
		pointer_inside = true
	if hud.is_modal():
		press_target = null
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		pointer = mb.position
		pointer_inside = true
		if mb.pressed:
			press_pos = pointer
			press_target = _target_at(pointer)
		else:
			if inspecting != null:
				close_inspect()
			elif not fan.is_empty() and not (press_target is SCard and fan.has(press_target)):
				close_fan()
			elif press_target != null and pointer.distance_to(press_pos) < 30.0:
				var t: Variant = _target_at(pointer)
				if t != null and _same_target(t, press_target):
					_activate(t)
			press_target = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_EXIT:
		pointer_inside = false
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_back()
	elif what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_auto_pause()


func _back() -> void:
	if _overlay_screen and is_instance_valid(_overlay_screen):
		if not (_overlay_screen as Screen).on_back():
			_overlay_screen.get_parent().queue_free()
			_overlay_screen = null
	elif _net_down:
		pass  # the connection dialog stays until the line is back or you leave
	elif paused:
		resume_game()
	elif hud.is_modal():
		hud.close_modal()
	elif inspecting:
		close_inspect()
	else:
		open_menu()


func _same_target(a: Variant, b: Variant) -> bool:
	if a is Object and b is Object:
		return a == b
	return typeof(a) == typeof(b) and a == b


## What is under a screen point: SCard, ChipStack, NobleTile, "deck:N",
## "reserve", "opp:N", "me" - or null. Each piece is tested at its own height.
func _target_at(sp: Vector2) -> Variant:
	if layout == null or inspecting != null:
		return null
	if not fan.is_empty():
		for c in fan:
			if not c.busy and c.contains_world(_hit_at(sp, c)):
				return c
		return null
	var opp := hud.opponent_at(sp)
	if opp >= 0:
		return "opp:%d" % opp
	if hud.reserve_at(sp):
		return "reserve"
	if hud.me_at(sp):
		return "me"
	for c in cards:
		if c.visible and not c.busy and c.contains_world(_hit_at(sp, c)):
			return c
	for col in bank:
		var st: ChipStack = bank[col]
		if st.contains_world(_hit_at(sp, st)):
			return st
	for t in deck_nodes:
		var dn: DeckStack = deck_nodes[t]
		if dn.contains_world(layout.screen_to_table(sp, BOARD_T * U)):
			return "deck:%d" % t
	for n in nobles:
		if n.contains_world(_hit_at(sp, n)):
			return n
	return null


## The point under the screen point at the height of `node`.
func _hit_at(sp: Vector2, node: Node3D) -> Vector3:
	return layout.screen_to_table(sp, node.global_position.y)


func _activate(t: Variant) -> void:
	if tut_gate.is_valid() and not tut_gate.call(t):
		return
	if t is String:
		var s: String = t
		if s.begins_with("opp:"):
			open_player(int(s.get_slice(":", 1)) + 1)
		elif s == "me":
			open_player(0)
		elif s.begins_with("deck:"):
			reserve_blind(int(s.get_slice(":", 1)))
		elif s == "reserve":
			open_fan()
		return
	if t is SCard:
		if fan.has(t):
			open_inspect(t as SCard, fan.find(t))
		else:
			open_inspect(t as SCard)
	elif t is ChipStack:
		take_coin((t as ChipStack).color)
	elif t is NobleTile:
		_show_noble(nobles.find(t))


# ------------------------------------------------------------------ turns + clock

func _my_turn() -> bool:
	return turn == 0 and not game_over and not (net and net.awaiting)


func start_turn(t: int, continuing := false) -> void:
	if game_over:
		return
	turn = t
	if t == first_seat and not continuing:
		round_no += 1
	hud.round_no = maxi(round_no, 1)
	picks.clear()
	if mode != "tutorial" and not demo:
		SavedGame.save(self)  # every turn starts from a kept table
	hud.set_turn(t, mode != "tutorial")  # no clock while learning
	tut_event.emit("turn", t)
	_update_bar()
	_refresh_glows()
	if t == 0:
		Sfx.play("turn_mine")
		hud.banner(L.t("your_turn"), true)
		if not demo:
			Prefs.buzz(120)  # a short buzz: it is your turn
	else:
		Sfx.play("turn_other")
		hud.banner(L.t("turn_of", String(opps[t - 1]["name"])), false)
		if net == null:
			_ai_turn(t - 1)


func end_turn() -> void:
	hud.stop_timer()
	hud.show_skip(false)
	_refresh_glows()
	await _wait(0.5)
	while _busy > 0:
		await get_tree().process_frame
	await _check_nobles(turn - 1)
	var p: Dictionary = _seat(turn)
	if int(p["prestige"]) >= win_points and not final_round:
		final_round = true
		hud.banner(L.t("final_round"), turn == 0)
		await _wait(1.4)
	_set_move_power(turn, int(p["prestige"]))
	var next := (turn + 1) % (opps.size() + 1)
	if final_round and next == first_seat:
		_finish_game()
		return
	start_turn(next)


func _seat(t: int) -> Dictionary:
	return me if t == 0 else opps[t - 1]


## Most prestige wins; a tie goes to whoever bought fewer cards.
func _finish_game() -> void:
	game_over = true
	SavedGame.clear()
	hud.stop_timer()
	var rows := [me] + opps
	rows.sort_custom(func(x, y):
		if int(x["prestige"]) != int(y["prestige"]):
			return int(x["prestige"]) > int(y["prestige"])
		return _card_count(x) < _card_count(y))
	var w: Dictionary = rows[0]
	var won := w == me
	Sfx.play("win" if won else "lose")
	hud.banner(L.t("you_win") if won else L.t("wins", String(w["name"])), won)
	if won:
		for k in 4:
			FX.burst(world_root, layout.world(Vector2(layout.mid(CARD_AREA_X) + (k - 1.5) * 300.0, 420), 200.0 * U),
					Color(1.0, 0.82, 0.35), U, 70, 520.0, 1.4, 14.0)
	var out := []
	for q in rows:
		out.append({"name": q["name"], "portrait": q["portrait"], "power": int(q["prestige"]),
				"cards": _card_count(q), "me": q == me})
	_record_game(won)
	await _wait(1.8)
	hud.show_results(out, L.t("victory") if won else L.t("wins", String(w["name"])), won, after_results(_play_again),
			after_results(_to_menu))


func _card_count(q: Dictionary) -> int:
	var n := 0
	for c in Gems.COLORS:
		n += int(q["cards"][c])
	return n


## The game is over for you: kept in the history, counted for the rate
## prompt, and sent as `game_end`. `quit`: you left before the end. `place`
## (1 = first) comes from the server online; otherwise it is worked out here.
func _record_game(won: bool, rating_delta := 0, quit := false, place := 0) -> void:
	if demo:
		return
	_track_end(won, quit, place)
	if won and mode in ["ai", "online", "friends"]:
		Prefs.set_v("wins", int(Prefs.get_v("wins")) + 1)
		Prefs.just_won = true
	var seats := []
	for q in [me] + opps:
		seats.append({"name": q["name"], "portrait": q["portrait"], "power": int(q["prestige"])})
	Prefs.add_history({
		"result": "win" if won else "loss", "mode": mode, "players": opps.size() + 1,
		"difficulty": difficulty, "power": int(me["prestige"]), "rating_delta": rating_delta,
		"played_at": int(Time.get_unix_time_from_system()), "seats": seats, "moves": moves,
	})


## Leaving the results (Play again or Menu) may show an ad first ("postgame").
func after_results(then: Callable) -> Callable:
	return func():
		await Ads.show("postgame")
		then.call()


## Analytics: a game begins (a continued one too, marked `resumed`).
func _track_start() -> void:
	_started_at = Time.get_ticks_msec() / 1000.0
	if demo:
		return
	var p := {"mode": mode, "players": opps.size() + 1, "difficulty": difficulty if net == null else "", "win": win_points}
	if resumed:
		p["resumed"] = true
	Analytics.event("game_start", p)


## Analytics: the game is over (or left).
func _track_end(won: bool, quit: bool, place: int) -> void:
	if place <= 0:
		var rows := [me] + opps
		rows.sort_custom(func(x, y):
			if int(x["prestige"]) != int(y["prestige"]):
				return int(x["prestige"]) > int(y["prestige"])
			return _card_count(x) < _card_count(y))
		place = 1 if won else maxi(rows.find(me) + 1, 2)
	var sec := int(Time.get_ticks_msec() / 1000.0 - _started_at) if _started_at > 0.0 else 0
	Analytics.event("game_end", {"mode": mode, "players": opps.size() + 1, "difficulty": difficulty if net == null else "",
			"won": won, "place": place, "points": int(me["prestige"]), "rounds": maxi(round_no, 1), "sec": sec, "quit": quit})


func _play_again() -> void:
	if net:
		_to_menu()
		return
	get_tree().reload_current_scene()


## After an online game: straight to choosing the next one.
func _to_play() -> void:
	_to_menu()
	Prefs.start_screen = "play"


func _to_menu() -> void:
	get_tree().paused = false
	if net and not game_over:
		Api.leave_match()  # "leave for now": the seat stays, Rejoin from the menu
	Net.in_game = false
	Prefs.start_screen = "menu"
	get_tree().change_scene_to_file("res://scenes/app.tscn")


func _log(seat: int, kind: String, extra := {}) -> void:
	var m := {"turn": round_no, "seat": seat, "kind": kind}
	m.merge(extra)
	moves.append(m)


func _set_move_power(seat: int, power: int) -> void:
	for k in range(moves.size() - 1, -1, -1):
		var m: Dictionary = moves[k]
		if m["seat"] != seat or m["turn"] != round_no:
			break
		m["power"] = power


## The buttons under the middle follow the turn: Skip, or Undo / Done.
func _update_bar() -> void:
	var mine_ := _my_turn()
	hud.show_skip(mine_ and picks.is_empty() and inspecting == null and net == null)
	if not mine_ or picks.is_empty():
		if staged.is_empty() or mine_:
			hud.set_stage("", false)
		return
	var full: bool = picks.size() == 3 or (picks.size() == 2 and picks[0] == picks[1]) \
			or _coin_total() + picks.size() >= MAX_COINS
	hud.set_stage(L.t("you_taking"), true, full)


## Cards you can buy right now glow green on your turn.
func _refresh_glows() -> void:
	var on := _my_turn() and picks.is_empty()
	for c in cards:
		if not c.data.is_empty():
			c.glow_target = 1.0 if on and can_afford(me, c.data) else 0.0
	for c in fan:
		c.glow_target = 1.0 if on and can_afford(me, c.data) else 0.0


# ------------------------------------------------------------------ menu

func open_menu() -> void:
	if game_over or intro_running:
		return
	var items := [
		[L.t("resume"), "green", func(): pass],
		[L.t("how_to"), "dark", func(): _open_screen("howto")],
		[L.t("settings"), "dark", func(): _open_screen("settings")],
	]
	if can_pause():
		items.insert(1, [L.t("pause"), "dark", pause_game])
	if mode in ["online", "friends"]:
		items.append([L.t("report"), "dark", _report])
	items.append([L.t("leave"), "red", _ask_leave])
	hud.show_menu(items)


func _open_screen(screen_name: String) -> void:
	var paths := {"howto": "res://scripts/screens/howto.gd", "settings": "res://scripts/screens/settings_screen.gd"}
	if not paths.has(screen_name):
		return
	var layer := CanvasLayer.new()
	layer.layer = 9
	add_child(layer)
	var sc: Screen = load(paths[screen_name]).new()
	layer.add_child(sc)
	_overlay_screen = sc
	sc.back.connect(func():
		layer.queue_free()
		_overlay_screen = null)
	sc.go.connect(func(n: String, _a: Variant):
		layer.queue_free()
		_open_screen(n))
	sc.play.connect(func(g: Dictionary):
		Prefs.game = g
		get_tree().reload_current_scene())


# ------------------------------------------------------------------ pause (games against the computer)

## Only a game against the computer can wait: online the server runs the clock.
func can_pause() -> bool:
	return mode == "ai" and net == null and not demo and not game_over


## Everything on the table stands still (the clock, the computer players,
## every move in flight) under a dialog that Resume closes.
func pause_game() -> void:
	if paused or not can_pause():
		return
	paused = true
	_paused_at = Time.get_ticks_msec() / 1000.0
	if inspecting:
		close_inspect()
	get_tree().paused = true
	hud.pause_overlay(resume_game)


func resume_game() -> void:
	if not paused:
		return
	paused = false
	get_tree().paused = false
	var sec := Time.get_ticks_msec() / 1000.0 - _paused_at
	hud.turn_started += sec  # the clock goes on from where it stopped
	if hud.modal and is_instance_valid(hud.modal):
		hud.close_modal()
	Analytics.event("pause", {"sec": int(sec)})


## The app went to the background (or lost focus) during a game against the
## computer: pause it, unless a dialog is already waiting for an answer.
func _auto_pause() -> void:
	if paused or intro_running or not can_pause() or hud == null:
		return
	if OS.get_cmdline_user_args().has("--autoplay"):
		return  # a test or recording plays on in an unfocused window
	if hud.modal and is_instance_valid(hud.modal):
		return
	pause_game()


## --pause: open the pause a moment after the table is up (checks).
func _pause_if_asked(args: PackedStringArray) -> void:
	if args.has("--pause"):
		await get_tree().create_timer(1.0).timeout
		pause_game()


func _report() -> void:
	var items := []
	for o in opps:
		var who: String = o["name"]
		items.append([who, "dark", func():
			var uid := String(o.get("user_id", ""))
			hud.confirm(L.t("report_title", who), L.t("report_body"), L.t("send"), func():
				if net and uid != "" and not o.has("bot"):
					Api.rpc_call("report_player", {"matchId": match_id, "reportedId": uid, "reason": "reported in game"})
				hud.toast(L.t("report_sent")))])
	hud.show_menu(items)


func _ask_leave() -> void:
	var body: String = {"online": L.t("leave_online"), "friends": L.t("leave_friends")}.get(mode, L.t("leave_ai"))
	hud.confirm(L.t("leave_title"), body, L.t("leave"), _leave)


func _leave() -> void:
	SavedGame.clear()
	if net:  # leaving an online game concedes it
		net.concede()
		game_over = true
		_record_game(false, 0, true)
		Api.leave_match()
		_to_menu()
		return
	if not game_over:
		game_over = true
		_record_game(false, 0, true)
	_to_menu()


## The clock ran out: tokens already taken count as your move.
func _on_time_up() -> void:
	if turn != 0 or game_over:
		return
	if inspecting:
		close_inspect()
	hud.close_modal()
	Sfx.play("time_up")
	hud.toast(L.t("time_up"))
	if net:  # the server passes the turn; tokens not sent go back
		return
	if not picks.is_empty():
		_commit_my_coins()
	else:
		_log(0, "timeout")
	end_turn()


func _deny(msg: String, node: Node3D = null) -> void:
	hud.toast(msg)
	Sfx.play("denied")
	Prefs.buzz(40)
	if node is ChipStack:
		(node as ChipStack).shake()
	elif node:
		_shake(node)


# ------------------------------------------------------------------ inspect

func open_inspect(card: SCard, reserve_index := -1) -> void:
	if card.busy or inspecting != null:
		return
	if not _my_turn():
		_deny(L.t("wait_turn"))
		return
	if not picks.is_empty():
		_deny(L.t("finish_tokens_first"))
		return
	inspecting = card
	_inspect_reserve = reserve_index
	Sfx.play("card_deal", -1.0, -6.0)
	card.press()
	card.lift_to(_air_point(Vector2(layout.mid(CARD_AREA_X), 380), 320.0), 2.0 * U / card.global_basis.get_scale().x,
			deg_to_rad(CAM_TILT) * 0.8)
	_set_dim(0.66)
	hud.set_dim(1.0)
	hud.show_skip(false)
	var can_buy := can_afford(me, card.data)
	var can_res: bool = reserve_index < 0 and (me["reserved"] as Array).size() < RESERVE_MAX
	var note := ""
	var gold_note := ""
	if not can_buy:
		note = L.t("missing", _missing_text(me, card.data))
	else:
		var g := _gold_needed(me, card.data)
		if g > 0:
			gold_note = L.t("uses_gold", g)
	hud.show_inspect(true, can_buy, can_res, note, gold_note, reserve_index < 0)
	tut_event.emit("inspect", card)


## Tap your reserve stack: your reserved cards fan out over the middle.
func open_fan() -> void:
	var res: Array = me["reserved"]
	if res.is_empty():
		hud.toast(L.t("reserved_empty"))
		return
	if not fan.is_empty():
		return
	var from := _hud_point(hud.me_reserve_anchor(), 40.0)
	_set_dim(0.55)
	hud.set_dim(1.0)
	for j in res.size():
		var x := layout.mid(CARD_AREA_X) + (j - (res.size() - 1) * 0.5) * (SCard.W * 1.2 + 50.0)
		var c := SCard.new()
		_place_card_node(c, Vector2(x, FAN_Y), 1.2, 200.0)
		c.set_data(res[j])
		c.set_raised(true)
		c.set_backlight(true)
		fan.append(c)
		# each one rises out of the reserve stack, turning over
		c.busy = true
		c.set_face_up(false)
		var start := c.to_local(from)
		c.pivot.position = start
		c.pivot.scale = Vector3.ONE * 0.2
		var tw := c.create_tween()
		tw.tween_interval(j * 0.08)
		tw.tween_method(func(t: float):
			var e := 1.0 - pow(1.0 - t, 3.0)
			c.pivot.position = start.lerp(Vector3.ZERO, e) + Vector3(0, sin(t * PI) * 80.0, 0)
			c.pivot.scale = Vector3.ONE * lerpf(0.2, 1.0, e)
			c.flipper.rotation.z = PI * (1.0 - smoothstep(0.2, 0.8, t)), 0.0, 1.0, 0.5)
		tw.tween_callback(func():
			c.set_face_up(true)
			c.busy = false)
	_refresh_glows()


## The fanned cards go back into the reserve stack.
func close_fan(dur := 0.35) -> void:
	if fan.is_empty():
		return
	var to := _hud_point(hud.me_reserve_anchor(), 40.0)
	for c in fan:
		if not is_instance_valid(c):
			continue
		c.busy = true
		c.fly_to(to, 0.15, dur, 60.0)
		c.arrived.connect(c.queue_free)
	fan.clear()
	_set_dim(0.0)
	hud.set_dim(0.0)


## A screen point (2D HUD) as a point in the air over the table.
func _hud_point(sp: Vector2, height_px := 200.0) -> Vector3:
	return layout.screen_to_table(sp, height_px * U)


## A point floating `height_px` above the table under a design point.
func _air_point(m: Vector2, height_px: float) -> Vector3:
	return layout.world(m, height_px * U)


func close_inspect() -> void:
	if inspecting == null:
		return
	inspecting.drop_back()
	inspecting = null
	_inspect_reserve = -1
	if fan.is_empty():
		_set_dim(0.0)
		hud.set_dim(0.0)
	hud.show_inspect(false)
	_update_bar()


func _end_inspect_for(card: SCard) -> void:
	if inspecting == card:
		inspecting = null
		_inspect_reserve = -1
		_set_dim(0.0)
		hud.set_dim(0.0)
		hud.show_inspect(false)


func _set_dim(a: float) -> void:
	var m: ShaderMaterial = dim.material_override
	dim.visible = true
	var tw := create_tween()
	tw.tween_method(func(v: float):
		_dim_alpha = v
		m.set_shader_parameter("alpha", v), _dim_alpha, a, 0.22)
	if a <= 0.0:
		tw.tween_callback(func(): dim.visible = false)


func _on_buy_pressed() -> void:
	if inspecting == null:
		return
	if not can_afford(me, inspecting.data):
		_deny(L.t("not_enough") if _inspect_reserve < 0 else L.t("missing", _missing_text(me, inspecting.data)))
		_shake(inspecting.pivot)
		return
	if net:
		var id := String(inspecting.data["id"])
		var from_res := _inspect_reserve >= 0
		var after: Dictionary = me["cards"].duplicate()
		after[String(inspecting.data["element"])] = int(after[String(inspecting.data["element"])]) + 1
		close_inspect()
		if from_res:
			close_fan()
		net.send_buy(id, from_res, await _net_noble_pick(after))
		return
	buy_card(inspecting, _inspect_reserve)


func _on_reserve_pressed() -> void:
	if inspecting == null or _inspect_reserve >= 0:
		return
	if (me["reserved"] as Array).size() >= RESERVE_MAX:
		_deny(L.t("reserve_full"))
	elif net:
		var id := String(inspecting.data["id"])
		close_inspect()
		net.send_reserve(id, await _net_noble_pick(me["cards"]))
	else:
		reserve_card(inspecting)


# ------------------------------------------------------------------ rules helpers

func _coin_total() -> int:
	return _total(me)


func _total(p: Dictionary) -> int:
	var n := 0
	for c in Gems.ALL:
		n += int(p["coins"][c])
	return n


func _cost_after_bonus(p: Dictionary, d: Dictionary) -> Dictionary:
	var need := {}
	for cost in d["costs"]:
		var c: String = cost[0]
		need[c] = maxi(int(cost[1]) - int(p["cards"][c]), 0)
	return need


func _gold_needed(p: Dictionary, d: Dictionary) -> int:
	var need := _cost_after_bonus(p, d)
	var g := 0
	for c in need:
		g += maxi(int(need[c]) - int(p["coins"][c]), 0)
	return g


func can_afford(p: Dictionary, d: Dictionary) -> bool:
	return _gold_needed(p, d) <= int(p["coins"]["gold"])


func _missing_text(p: Dictionary, d: Dictionary) -> String:
	var need := _cost_after_bonus(p, d)
	var parts := []
	for c in need:
		var miss := int(need[c]) - int(p["coins"][c])
		if miss > 0:
			parts.append("%d %s" % [miss, L.gem(c)])
	var gold := int(p["coins"]["gold"])
	var sep := "، " if L.fa() else ", "
	return sep.join(parts) + ("  " + L.t("gold_covers", gold) if gold > 0 else "")


# ------------------------------------------------------------------ taking gems

## Pick a gem: the top chip lifts off its pile and flies to the middle, where
## everyone can see what you are taking. Done sends them to your tray.
func take_coin(col: String) -> void:
	if not _my_turn():
		_deny(L.t("wait_turn"))
		return
	var src: ChipStack = bank[col]
	if col == "gold":
		_deny(L.t("gold_only_reserve"), src)
		return
	if int(bank_counts[col]) <= 0:
		_deny(L.t("none_left"), src)
		return
	if _coin_total() + picks.size() + 1 > MAX_COINS:
		_deny(L.t("max_tokens", MAX_COINS), src)
		return
	if picks.size() == 1 and picks[0] == col and int(bank_counts[col]) < 3:
		_deny(L.t("two_needs_four"), src)
		return
	if picks.size() == 2 and (picks.has(col) or picks[0] == picks[1]):
		_deny(L.t("three_or_two"), src)
		return
	if picks.size() >= 3:
		_deny(L.t("already_three"), src)
		return
	picks.append(col)
	bank_counts[col] -= 1
	_stage_add(col)
	tut_event.emit("coin", col)
	_update_bar()
	_refresh_glows()
	var full: bool = picks.size() == 3 or (picks.size() == 2 and picks[0] == picks[1]) \
			or _coin_total() + picks.size() >= MAX_COINS
	if full:
		hud.toast(L.t("done_hint"))


func undo_pick() -> void:
	if not _my_turn() or picks.is_empty():
		return
	var col: String = picks.pop_back()
	bank_counts[col] += 1
	_stage_undo()
	_update_bar()
	_refresh_glows()


func done_picking() -> void:
	if not _my_turn() or picks.is_empty():
		return
	var full: bool = picks.size() == 3 or (picks.size() == 2 and picks[0] == picks[1])
	if full or not Prefs.get_v("confirm_moves"):
		_finish_picking()
		return
	var n := picks.size()
	hud.confirm(L.t("take_only_title", n), L.t("take_only_body", n), L.t("done"), _finish_picking)


func _finish_picking() -> void:
	if not _my_turn() or picks.is_empty():
		return
	if net:  # the server says yes, then the tokens fly to you
		var taken := picks.duplicate()
		var noble := await _net_noble_pick(me["cards"])
		net.send_take(taken, noble)
		hud.set_stage("", false)
		_refresh_glows()
		return
	_commit_my_coins()
	end_turn()


func _commit_my_coins() -> void:
	_log(0, "coins", {"colors": picks.duplicate()})
	tut_event.emit("coins_done", picks.duplicate())
	for c in picks:
		me["coins"][c] += 1
	picks.clear()
	hud.set_stage("", false)
	_stage_commit(-1)
	_update_bar()


func skip_turn() -> void:
	if not _my_turn() or net:  # an online turn passes only when its clock runs out
		return
	if not picks.is_empty():
		_deny(L.t("finish_tokens_first"))
		return
	var do_skip := func():
		if _my_turn() and picks.is_empty():
			hud.toast(L.t("you_skipped"))
			_log(0, "skip")
			end_turn()
	if not Prefs.get_v("confirm_moves"):
		do_skip.call()
		return
	hud.confirm(L.t("skip_title"), L.t("skip_body"), L.t("skip"), do_skip)


# ------------------------------------------------------------------ buying + reserving

## Buy `card` (from the board, or from your reserve when reserve_index >= 0).
func buy_card(card: SCard, reserve_index := -1) -> void:
	var d := card.data
	_end_inspect_for(card)
	_busy += 1
	var g0 := _gen  # this table; a rebuild makes it stale
	var col: String = d["element"]
	var idx := cards.find(card)
	if reserve_index >= 0:
		fan.erase(card)
		close_fan()
	# pay: colour tokens first, gold for the rest; they fly back to the bank
	var delay := 0.0
	var need := _cost_after_bonus(me, d)
	for c in need:
		var pay := mini(int(need[c]), int(me["coins"][c]))
		var gold := int(need[c]) - pay
		for k in pay:
			_pay_coin(c, delay)
			delay += 0.08
		for k in gold:
			_pay_coin("gold", delay)
			delay += 0.08
	hud.update_me()
	_log(0, "buy_reserved" if reserve_index >= 0 else "buy", {"card": d["id"]})
	if reserve_index >= 0:
		(me["reserved"] as Array).remove_at(reserve_index)
		hud.update_me()
	var dest := _hud_point(hud.me_card_anchor(col), 60.0)
	var line1 := L.t("you_bought") + ("  (%s)" % L.t("from_reserve") if reserve_index >= 0 else "")
	card.set_backlight(false)
	await _reveal(card, line1, L.t("card_of", L.gem(col), d["tier"]), true, dest, 0.36)
	Sfx.play("card_buy")
	card.visible = false
	me["cards"][col] += 1
	hud.update_me()
	hud.me_view.pop_card(col)
	FX.burst(world_root, dest, Gems.GLOW[col], U, 44, 340.0)
	FX.ring(world_root, dest, Gems.GLOW[col], U, 120.0, 0.5)
	if reserve_index >= 0:
		card.queue_free()
	elif idx >= 0:
		card.reset_pose()
		card.set_backlight(true)
		_refill(idx)
	var points: int = d["points"]
	if points > 0:
		await _wait(0.25)
		await _score_orb(dest, points)
	_done(g0)
	tut_event.emit("bought", d["id"])
	end_turn()


func reserve_card(card: SCard) -> void:
	var d := card.data
	_end_inspect_for(card)
	_busy += 1
	var g0 := _gen  # this table; a rebuild makes it stale
	var idx := cards.find(card)
	Sfx.play("card_reserve")
	_give_gold()
	_log(0, "reserve", {"card": d["id"]})
	var dest := _hud_point(hud.me_reserve_anchor(), 60.0)
	card.set_backlight(false)
	await _reveal(card, L.t("you_reserved"), L.t("card_of", L.gem(d["element"]), d["tier"]), true, dest, 0.3)
	(me["reserved"] as Array).append(d)
	hud.update_me()
	card.visible = false
	card.reset_pose()
	card.set_backlight(true)
	FX.burst(world_root, dest, Color(1.0, 0.8, 0.4), U, 30, 260.0)
	_refill(idx)
	_done(g0)
	tut_event.emit("reserved", d["id"])
	end_turn()


## Reserve the top card of a deck without seeing it.
func reserve_blind(tier: int) -> void:
	if not _my_turn():
		_deny(L.t("wait_turn"))
		return
	if not picks.is_empty():
		_deny(L.t("already_took"))
		return
	if (me["reserved"] as Array).size() >= RESERVE_MAX:
		_deny(L.t("reserve_full"))
		return
	if (decks[tier] as Array).is_empty():
		_deny(L.t("deck_empty"))
		return
	if not Prefs.get_v("confirm_moves"):
		_do_reserve_blind(tier)
		return
	var gold_text := L.t("gold_yes")
	if _coin_total() >= MAX_COINS:
		gold_text = L.t("gold_no_max", MAX_COINS)
	elif int(bank_counts["gold"]) <= 0:
		gold_text = L.t("gold_no_bank")
	hud.confirm(L.t("blind_title"), L.t("blind_body", Gems.ROMAN[tier], gold_text), L.t("reserve"),
			_do_reserve_blind.bind(tier))


func _do_reserve_blind(tier: int) -> void:
	if not _my_turn() or not picks.is_empty() or (decks[tier] as Array).is_empty():
		return
	if net:
		net.send_reserve_blind(tier, await _net_noble_pick(me["cards"]))
		return
	_busy += 1
	var g0 := _gen  # this table; a rebuild makes it stale
	var d: Dictionary = (decks[tier] as Array).pop_back()
	_update_deck(tier)
	_log(0, "reserve_blind", {"tier": tier})
	Sfx.play("card_reserve")
	_give_gold()
	var dest := _hud_point(hud.me_reserve_anchor(), 60.0)
	var c := _loose_card(d, (deck_nodes[tier] as DeckStack).top_world(), false)
	c.set_backlight(false)
	await _reveal(c, L.t("you_reserved"), L.t("hidden_card", Gems.ROMAN[tier]), true, dest, 0.3)
	c.queue_free()
	(me["reserved"] as Array).append(d)
	hud.update_me()
	# only you see what it was
	hud.announce(L.t("you_drew"), L.t("card_of", L.gem(d["element"]), d["tier"]), true, 1.6)
	FX.burst(world_root, dest, Color(1.0, 0.8, 0.4), U, 30, 260.0)
	_done(g0)
	end_turn()


## A card that is not on the board (drawn blind), placed at a world point.
func _loose_card(d: Dictionary, at: Vector3, face_up := true) -> SCard:
	var c := SCard.new()
	world_root.add_child(c)
	c.global_position = at
	c.scale = Vector3.ONE * U
	c.cam_tilt = deg_to_rad(CAM_TILT)
	c.interactive = false
	c.set_data(d)
	c.set_face_up(face_up)
	return c


func _give_gold() -> void:
	if _coin_total() >= MAX_COINS:
		hud.toast(L.t("gold_no_max", MAX_COINS))
		return
	if int(bank_counts["gold"]) > 0:
		bank_counts["gold"] -= 1
		me["coins"]["gold"] += 1
		_fly_to_me(bank["gold"], 0.2)


func _pay_coin(col: String, delay: float) -> void:
	if int(me["coins"][col]) <= 0:
		return
	me["coins"][col] -= 1
	bank_counts[col] += 1
	_fly_chip_from_point(col, _hud_point(hud.me_token_anchor(col), 40.0), bank[col], delay)


## The public reveal of a purchase or reservation: the card glides through
## the middle (biggest and slowest there) while the plaque names who did it,
## then on into `dest`, shrinking to `end_k` of its board size.
func _reveal(card: SCard, line1: String, line2: String, mine_: bool, dest: Vector3, end_k := 0.3, dur := 1.9) -> void:
	var zoom := 2.0 * U / card.global_basis.get_scale().x
	var end_scale := end_k * U / card.global_basis.get_scale().x
	card.present_to(_air_point(Vector2(layout.mid(CARD_AREA_X), 440), 320.0), zoom, deg_to_rad(CAM_TILT) * 0.8, dest, end_scale, dur,
			not card.face_up)
	_reveal_plaque(line1, line2, mine_, dur)
	await card.arrived


func _reveal_plaque(line1: String, line2: String, mine_: bool, dur: float) -> void:
	await _wait(dur * 0.12)
	_set_dim(0.5)
	hud.announce(line1, line2, mine_, dur * 0.55)
	await _wait(dur * 0.6)
	_set_dim(0.0)


## Earned prestige: "+N" rises where it was earned, a glowing orb carries it
## to your score, which then counts up.
func _score_orb(from: Vector3, points: int) -> void:
	var plus := Fonts.label3d("+%d" % points, 70.0, Color(1.0, 0.86, 0.4), "num", 7.0, Color(0.25, 0.14, 0.02))
	plus.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	plus.rotation = Vector3.ZERO
	plus.render_priority = 40
	plus.outline_render_priority = 39
	plus.no_depth_test = true
	world_root.add_child(plus)
	plus.global_position = from + Vector3(0, 60.0 * U, 0)
	plus.scale = Vector3.ONE * U * 0.4
	var tw := plus.create_tween()
	tw.tween_property(plus, "scale", Vector3.ONE * U * 1.2, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(plus, "global_position", from + Vector3(0, 170.0 * U, 0), 0.4)
	await tw.finished
	var orb := Meshes.glow(1.0, Color(1.0, 0.8, 0.35), 2.0)
	orb.scale = Vector3.ONE * 80.0 * U
	(orb.material_override as Material).render_priority = 42
	world_root.add_child(orb)
	var start := plus.global_position
	var to := layout.screen_to_table(hud.me_score_anchor(), 160.0 * U)
	orb.global_position = start
	var trail := FX.trail(world_root, Color(1.0, 0.8, 0.35), U, 16.0)
	var tw2 := orb.create_tween()
	tw2.tween_method(func(t: float):
		var p := start.lerp(to, t)
		p.y += sin(t * PI) * 160.0 * U
		orb.global_position = p
		trail.global_position = p
		plus.global_position = p
		plus.modulate.a = 1.0 - t, 0.0, 1.0, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	await tw2.finished
	FX.stop_trail(trail)
	orb.queue_free()
	plus.queue_free()
	FX.ring(world_root, to, Color(1.0, 0.8, 0.35), U, 150.0, 0.5)
	FX.burst(world_root, to, Color(1.0, 0.82, 0.35), U, 60, 420.0, 0.9)
	for k in points:
		me["prestige"] += 1
		hud.update_me()
		await _wait(0.12)


## A new card is dealt into the empty place from its deck.
func _refill(idx: int) -> void:
	if idx < 0:
		return
	var tier: int = TIER_OF_ROW[idx / 4]
	var card := cards[idx]
	await _wait(0.15)
	if (decks[tier] as Array).is_empty():
		board_cards[idx] = {}
		card.visible = false
		card.data = {}
		return
	var nd: Dictionary = (decks[tier] as Array).pop_back()
	_update_deck(tier)
	board_cards[idx] = nd
	card.reset_pose()
	card.set_data(nd)
	card.visible = true
	await _deal(card, tier, 0.75)
	FX.burst(world_root, card.global_position, Color(1.0, 0.75, 0.35), U, 26, 220.0, 0.7, 10.0)
	_refresh_glows()


## One row of the opening: the deck flies in, deals its four cards from the
## stack, then settles into its hole.
func _deck_row(r: int) -> void:
	var stack := await _deck_fly_in(r)
	for c in 4:
		var card := cards[r * 4 + c]
		if card.data.is_empty():
			continue
		card.visible = true
		Sfx.play("card_deal")
		card.deal_from(stack.global_position + Vector3(0, 10.0 * U, 0), 0.65, 1.0, 0.0, 0.0)
		await _wait(0.13)
	await _wait(0.7)
	await _deck_settle(r, stack)


## A deck comes to its hole in clear steps: a stack of card backs slides in
## from the left edge lying flat (face down, landscape) and stops above its
## hole (the cards are dealt from it there); then it turns up on its long edge
## (75 degrees, the swing the deck is drawn with) and sinks into the hole,
## where the drawn deck takes its place.
func _deck_fly_in(r: int) -> Node3D:
	var dn: DeckStack = deck_nodes[TIER_OF_ROW[r]]
	var home := dn.position
	var w := SCard.W * CARD_K * U
	var d := SCard.H * CARD_K * U
	var p := "res://assets/splendor/hud/back_%d.png" % TIER_OF_ROW[r]
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = Tex.get_tex(p) if ResourceLoader.exists(p) else null
	var stack := Node3D.new()
	world_root.add_child(stack)
	for k in 3:  # three backs, a little apart: a stack, with edges once it stands
		var q := MeshInstance3D.new()
		q.mesh = Meshes.quad(w, d)
		q.material_override = mat
		q.position = Vector3(k * 2.5 * U, k * 3.0 * U, 0)
		stack.add_child(q)
	var lift := w * 0.5 * sin(deg_to_rad(75.0)) + 34.0 * U  # standing up stays above the board
	stack.position = home + Vector3(-760.0 * U, lift, 0)
	var tw := stack.create_tween()
	tw.tween_property(stack, "position", home + Vector3(0, lift, 0), 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await tw.finished
	return stack


func _deck_settle(r: int, stack: Node3D) -> void:
	var dn: DeckStack = deck_nodes[TIER_OF_ROW[r]]
	var home := dn.position
	var tw := stack.create_tween()
	tw.tween_property(stack, "rotation:z", deg_to_rad(75.0), 0.3).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(stack, "position", home, 0.28).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await tw.finished
	dn.visible = true
	dn.position = home
	dn.rotation = Vector3.ZERO
	stack.queue_free()
	FX.ring(world_root, home + Vector3(0, 6.0 * U, 0), Color(1.0, 0.82, 0.45), U, 90.0, 0.35)


## A card comes out of its deck: it lifts off the top face down, already lying
## flat and landscape as on its place (never turned or tipped: in the camera's
## perspective that reads as a bent card), glides there and turns over.
func _deal(card: SCard, tier: int, dur: float) -> void:
	var dn: DeckStack = deck_nodes[tier]
	Sfx.play("card_deal")
	await card.deal_from(dn.top_world(), dur, 0.92, 0.0, (BOARD_T + 24.0) / CARD_K)


func _update_deck(tier: int) -> void:
	var dn: DeckStack = deck_nodes[tier]
	dn.set_count((decks[tier] as Array).size())
	dn.pop()


# ------------------------------------------------------------------ players + nobles

func open_player(seat: int) -> void:
	var everyone := [me] + opps
	seat = posmod(seat, everyone.size())
	hud.show_sheet(everyone[seat], seat == 0, func(dd: int): open_player(seat + dd))


func _show_noble(i: int) -> void:
	if i < 0:
		return
	i = posmod(i, noble_data.size())
	var owner_name: String = noble_owner[i]
	hud.show_noble(noble_data[i], me["cards"], owner_name, func(dd: int): _show_noble(i + dd))
	tut_event.emit("noble_shown", i)


## A noble visits whoever has its bonuses (at most one per turn).
## One noble per turn visits whoever has its bonuses; when several could
## come, you choose (the computer takes the first). The others may come on
## a later turn if they are still free.
func _check_nobles(opp_i: int) -> void:
	if net:
		return  # online, the server awards nobles (net_game.gd shows them)
	var p: Dictionary = me if opp_i < 0 else opps[opp_i]
	var ready := _nobles_for(p["cards"])
	if ready.is_empty():
		return
	var i: int = ready[0]
	if opp_i < 0 and ready.size() > 1:
		i = await _ask_noble(ready)
	noble_owner[i] = p["name"]
	p["nobles"] = int(p.get("nobles", 0)) + 1
	_log(opp_i + 1, "noble", {"noble": noble_data[i]["id"]})
	await _noble_claim(i, opp_i)


## The nobles still free whose requirements `cards` (bonuses by colour) meet.
func _nobles_for(cards_: Dictionary) -> Array:
	var out := []
	for i in noble_data.size():
		if noble_owner[i] != "":
			continue
		var ok := true
		for c in noble_data[i]["reqs"]:
			if int(cards_.get(c, 0)) < int(noble_data[i]["need"]):
				ok = false
		if ok:
			out.append(i)
	return out


## Ask which of the nobles `idx` (indices into noble_data) should come.
func _ask_noble(idx: Array) -> int:
	var list := idx.map(func(i): return noble_data[i])
	hud.choose_noble(list)
	if demo or OS.get_cmdline_user_args().has("--autoplay"):
		get_tree().create_timer(1.0).timeout.connect(func():
			hud.close_modal()
			hud.noble_chosen.emit(0))
	var k: int = await hud.noble_chosen
	return idx[k]


## Online: the noble to ask the server for with a move that leaves you
## with bonuses `after` ("" when at most one would come).
func _net_noble_pick(after: Dictionary) -> String:
	var ready := _nobles_for(after)
	if ready.size() < 2:
		return ""
	var i := await _ask_noble(ready)
	return "A-" + String(noble_data[i]["id"]).substr(2)

## The noble slides out of its place, comes to the middle of the table, big,
## turning, with a golden burst and a plaque, then goes to its host.
func _noble_claim(i: int, opp_i: int) -> void:
	var n := nobles[i]
	var nd: Dictionary = noble_data[i]
	var p: Dictionary = me if opp_i < 0 else opps[opp_i]
	hud.stop_timer()
	_busy += 1
	var g0 := _gen  # this table; a rebuild makes it stale
	n.busy = true
	n.set_raised(true)
	var from := n.global_position
	var mid := _air_point(Vector2(layout.mid(CARD_AREA_X), 470), 260.0)
	var to: Vector3 = layout.screen_to_table(hud.me_anchor() if opp_i < 0 else hud.opponent_anchor(opp_i), 200.0 * U)
	var s0 := n.scale.x
	var big := s0 * 2.4
	_set_dim(0.6)
	Sfx.play("noble_visit")
	hud.announce(L.t("noble_visit_you") if opp_i < 0 else L.t("noble_visit_opp", String(p["name"])),
			"%s  +3" % L.t("noble_" + String(nd["id"])), opp_i < 0, 2.6)
	var tw := n.create_tween()
	tw.tween_method(func(t: float):
		var e := 1.0 - pow(1.0 - t, 3.0)
		n.global_position = from.lerp(mid, e) + Vector3(0, sin(t * PI) * 90.0 * U, 0)
		n.scale = Vector3(1.0, 1.0, ZS) * lerpf(s0, big, e)
		n.pivot.rotation = Vector3(deg_to_rad(CAM_TILT) * e, sin(t * PI) * 0.6, 0), 0.0, 1.0, 0.7)
	await tw.finished
	var c := mid + Vector3(0, 60.0 * U, 0)
	FX.flash(world_root, c, Color(1.0, 0.85, 0.5), U, 320.0, 1.0)
	FX.burst(world_root, c, Color(1.0, 0.82, 0.3), U, 110, 620.0, 1.3, 16.0)
	FX.ring(world_root, c, Color(1.0, 0.85, 0.4), U, 300.0, 0.9)
	var tw2 := n.create_tween()
	tw2.tween_method(func(t: float):
		n.global_position = mid + Vector3(0, sin(t * TAU) * 14.0 * U, 0)
		n.flash(0.3 * sin(t * PI))
		n.pivot.rotation.y = sin(t * TAU) * 0.15, 0.0, 1.0, 1.8)
	await tw2.finished
	_set_dim(0.0)
	var tw3 := n.create_tween()
	tw3.tween_method(func(t: float):
		var e := t * t
		n.global_position = mid.lerp(to, e) + Vector3(0, sin(t * PI) * 60.0 * U, 0)
		n.scale = Vector3.ONE * lerpf(big, s0 * 0.25, e), 0.0, 1.0, 0.55)
	await tw3.finished
	n.visible = false
	FX.flash(world_root, to, Color(1.0, 0.82, 0.4), U, 160.0, 0.5)
	_done(g0)
	if opp_i < 0:
		hud.update_me()
		await _score_orb(to, 3)
	else:
		p["prestige"] += 3
		hud.update_opponent(opp_i)


# ------------------------------------------------------------------ opponents

## The computer: AIBrain (ai_brain.gd) chooses a legal move for its level
## (easy, normal, hard, very_hard); the helpers below play it on the table.
var _tut_ai_turn := 0


func _ai_turn(i: int) -> void:
	var o: Dictionary = opps[i]
	await _wait(1.5)
	if game_over:
		return
	if mode == "tutorial":  # Cosimo takes gems, never the card you are shown
		var plan := [["black", "white", "blue"], ["black", "red", "white"], ["blue", "black", "white"]]
		var take: Array = plan[mini(_tut_ai_turn, plan.size() - 1)]
		_tut_ai_turn += 1
		await _ai_take(i, MAX_COINS - _total(o), [], take)
		hud.update_opponent(i)
		end_turn()
		return
	if _video():  # the store videos' story, at a person's pace
		await _wait(_video_pace() - 1.5)
		var mv := _video_logged(o, false)
		match String(mv["kind"]):
			"buy":
				await _ai_buy(i, mv["card"])
			"buy_reserved":
				await _ai_buy_reserved(i, int(mv["k"]))
			"reserve":
				await _ai_reserve(i, mv["card"])
			_:
				await _ai_take(i, MAX_COINS - _total(o), [], mv["colors"])
		hud.update_opponent(i)
		end_turn()
		return
	var brain := AIBrain.new()
	brain.load_snapshot(_ai_snapshot(i))
	var dec := await _ai_think(brain)
	if game_over or not is_inside_tree():
		return
	if not _ai_legal(o, dec):  # never expected: the old computer's choice is always legal
		brain.level = "legacy"
		dec = brain.decide()
	if OS.get_cmdline_user_args().has("--netdebug"):
		print("AIMOVE round=%d %s style=%s %s %s" % [round_no, String(o["name"]), String(o.get("style", "")),
				String(dec.get("kind", "")), str(dec.get("colors", dec.get("index", "")))])
	match String(dec.get("kind", "skip")):
		"buy":
			await _ai_buy(i, cards[int(dec["index"])])
		"buy_reserved":
			await _ai_buy_reserved(i, int(dec["k"]))
		"reserve":
			await _ai_reserve(i, cards[int(dec["index"])])
		"reserve_blind":
			await _ai_reserve_blind(i, int(dec["tier"]))
		"take":
			await _ai_take(i, MAX_COINS - _total(o), [], dec["colors"])
		_:
			hud.toast(L.t("opp_skips", String(o["name"])))
			_log(i + 1, "skip")
	hud.update_opponent(i)
	end_turn()


## The table as plain data for AIBrain: what this computer player can see
## (another player's card reserved blind stays hidden).
func _ai_snapshot(i: int) -> Dictionary:
	var board := []
	for c in cards:
		board.append(c.data if c.visible and not c.busy and not c.data.is_empty() else {})
	var shown := {}
	for m in moves:
		if String(m.get("kind", "")) == "reserve":
			shown[String(m.get("card", ""))] = true
	var players := []
	var everyone := [me] + opps
	for s in everyone.size():
		var q: Dictionary = everyone[s]
		var res := []
		for d in q["reserved"]:
			res.append(d if s == i + 1 or shown.has(String(d.get("id", ""))) else {"hidden": true})
		players.append({"coins": q["coins"], "cards": q["cards"], "prestige": q["prestige"], "reserved": res})
	var free := []
	for owner_name in noble_owner:
		free.append(String(owner_name) == "")
	return {
		"bank": bank_counts, "board": board, "players": players, "seat": i + 1,
		"decks": {1: (decks[1] as Array).size(), 2: (decks[2] as Array).size(), 3: (decks[3] as Array).size()},
		"nobles": noble_data, "noble_free": free, "first_seat": first_seat, "final_round": final_round,
		"win_points": win_points, "difficulty": difficulty, "style": String(opps[i].get("style", "")),
	}


## Let the brain choose (on a worker thread where there are threads, so the
## table keeps moving); the stronger levels take a moment longer to "think".
func _ai_think(brain: AIBrain) -> Dictionary:
	var pause := 0.0
	if difficulty == "hard":
		pause = randf_range(0.3, 0.7)
	elif difficulty == "very_hard":
		pause = randf_range(0.5, 1.2)
	var until := Time.get_ticks_msec() + int(pause * 1000.0)
	if OS.has_feature("web") or OS.get_processor_count() < 2:
		brain.decide()
	else:
		var task := WorkerThreadPool.add_task(brain.decide)
		while not WorkerThreadPool.is_task_completed(task) and is_inside_tree():
			await get_tree().process_frame
		WorkerThreadPool.wait_for_task_completion(task)
	var left := until - Time.get_ticks_msec()
	if left > 0 and is_inside_tree():
		await _wait(left / 1000.0)
	return brain.result


## A last check of the brain's move against the table as it is now.
func _ai_legal(o: Dictionary, dec: Dictionary) -> bool:
	var reserved: Array = o["reserved"]
	match String(dec.get("kind", "")):
		"buy", "reserve":
			var k := int(dec.get("index", -1))
			if k < 0 or k >= cards.size():
				return false
			var c := cards[k]
			if not c.visible or c.busy or c.data.is_empty():
				return false
			return can_afford(o, c.data) if dec["kind"] == "buy" else reserved.size() < RESERVE_MAX
		"buy_reserved":
			var k := int(dec.get("k", -1))
			return k >= 0 and k < reserved.size() and can_afford(o, reserved[k])
		"reserve_blind":
			return reserved.size() < RESERVE_MAX and not (decks.get(int(dec.get("tier", 0)), []) as Array).is_empty()
		"take":
			var cols: Array = dec.get("colors", [])
			if cols.is_empty() or cols.size() > 3 or _total(o) + cols.size() > MAX_COINS:
				return false
			if cols.size() == 2 and cols[0] == cols[1]:
				return int(bank_counts.get(cols[0], 0)) >= 4
			for c in cols:
				if c == "gold" or cols.count(c) > 1 or int(bank_counts.get(c, 0)) <= 0:
					return false
			return true
		"skip":
			return true
	return false


func _opp_world(i: int, height_px := 200.0) -> Vector3:
	return layout.screen_to_table(hud.opponent_anchor(i), height_px * U)


func _ai_take(i: int, room: int, want: Array = [], exact: Array = []) -> void:
	var o: Dictionary = opps[i]
	var avail: Array = Gems.COLORS.filter(func(c): return int(bank_counts[c]) > 0)
	avail.shuffle()
	if not want.is_empty():
		avail.sort_custom(func(a, b): return want.has(a) and not want.has(b))
	var take: Array = avail.slice(0, mini(3, room))
	var deep: Array = Gems.COLORS.filter(func(c): return int(bank_counts[c]) >= 4)
	if room >= 2 and not deep.is_empty() and (take.size() < 2 or randf() < 0.2):
		take = [deep[0], deep[0]]
	if not exact.is_empty():
		take = exact.filter(func(c): return int(bank_counts[c]) > 0).slice(0, room)
	if take.is_empty():
		return
	hud.set_stage(L.t("opp_taking", String(o["name"])), false)
	for c in take:
		bank_counts[c] -= 1
		_stage_add(c)
		await _wait(0.42)
	await _wait(0.9)
	for c in take:
		o["coins"][c] += 1
	_log(i + 1, "coins", {"colors": take.duplicate()})
	hud.set_stage("", false)
	await _stage_commit(i)


func _ai_pay(i: int, d: Dictionary) -> void:
	var o: Dictionary = opps[i]
	var need := _cost_after_bonus(o, d)
	var delay := 0.3
	for c in need:
		var pay := mini(int(need[c]), int(o["coins"][c]))
		var gold := int(need[c]) - pay
		o["coins"][c] -= pay
		o["coins"]["gold"] -= gold
		bank_counts[c] += pay
		bank_counts["gold"] += gold
		for k in pay:
			_fly_chip_from_point(c, _hud_point(hud.seat_token_anchor(i, c), 40.0), bank[c], delay)
			delay += 0.08
		for k in gold:
			_fly_chip_from_point("gold", _hud_point(hud.seat_token_anchor(i, "gold"), 40.0), bank["gold"], delay)
			delay += 0.08
	hud.update_opponent(i)


func _ai_buy(i: int, card: SCard) -> void:
	var o: Dictionary = opps[i]
	var d := card.data
	var idx := cards.find(card)
	_ai_pay(i, d)
	_log(i + 1, "buy", {"card": d["id"]})
	card.set_backlight(false)
	await _reveal(card, L.t("opp_bought", String(o["name"])), L.t("card_of", L.gem(d["element"]), d["tier"]), false,
			_hud_point(hud.seat_card_anchor(i, d["element"]), 60.0), 0.2)
	Sfx.play("card_buy", -1.0, -3.0)
	card.visible = false
	o["cards"][d["element"]] += 1
	o["prestige"] += int(d["points"])
	hud.update_opponent(i)
	hud.seats[i].pop_card(d["element"])
	card.reset_pose()
	card.set_backlight(true)
	_refill(idx)
	await _wait(0.3)


func _ai_buy_reserved(i: int, k: int) -> void:
	var o: Dictionary = opps[i]
	var d: Dictionary = (o["reserved"] as Array)[k]
	_ai_pay(i, d)
	(o["reserved"] as Array).remove_at(k)
	_log(i + 1, "buy_reserved", {"card": d["id"]})
	var c := _loose_card(d, _hud_point(hud.seat_reserve_anchor(i), 60.0))
	c.set_backlight(false)
	c.pivot.scale = Vector3.ONE * 0.2
	await _reveal(c, L.t("opp_bought", String(o["name"])) + "  (%s)" % L.t("from_reserve"),
			L.t("card_of", L.gem(d["element"]), d["tier"]), false, _hud_point(hud.seat_card_anchor(i, d["element"]), 60.0), 0.2)
	Sfx.play("card_buy", -1.0, -3.0)
	c.queue_free()
	o["cards"][d["element"]] += 1
	o["prestige"] += int(d["points"])
	hud.update_opponent(i)


func _ai_gold(i: int) -> void:
	var o: Dictionary = opps[i]
	if int(bank_counts["gold"]) > 0 and _total(o) < MAX_COINS:
		bank_counts["gold"] -= 1
		o["coins"]["gold"] += 1
		_fly_chip_to_point(bank["gold"], _hud_point(hud.seat_token_anchor(i, "gold"), 40.0), 1.4)


func _ai_reserve(i: int, card: SCard) -> void:
	var o: Dictionary = opps[i]
	var d := card.data
	var idx := cards.find(card)
	Sfx.play("card_reserve")
	_ai_gold(i)
	_log(i + 1, "reserve", {"card": d["id"]})
	card.set_backlight(false)
	await _reveal(card, L.t("opp_reserved", String(o["name"])), L.t("card_of", L.gem(d["element"]), d["tier"]), false,
			_hud_point(hud.seat_reserve_anchor(i), 60.0), 0.15)
	(o["reserved"] as Array).append(d)
	card.visible = false
	card.reset_pose()
	card.set_backlight(true)
	hud.update_opponent(i)
	_refill(idx)
	await _wait(0.3)


func _ai_reserve_blind(i: int, tier: int) -> void:
	var o: Dictionary = opps[i]
	if (decks[tier] as Array).is_empty():
		return
	var d: Dictionary = (decks[tier] as Array).pop_back()
	_update_deck(tier)
	_log(i + 1, "reserve_blind", {"tier": tier})
	Sfx.play("card_reserve")
	_ai_gold(i)
	var c := _loose_card(d, (deck_nodes[tier] as DeckStack).top_world(), false)
	c.set_backlight(false)
	await _reveal(c, L.t("opp_reserved", String(o["name"])), L.t("hidden_card", Gems.ROMAN[tier]), false,
			_hud_point(hud.seat_reserve_anchor(i), 60.0), 0.15)
	c.queue_free()
	(o["reserved"] as Array).append(d)
	hud.update_opponent(i)


# ------------------------------------------------------------------ the middle (tokens being taken)

## The slot of the i-th token taken (from the top), as a design y.
func _stage_slot_x(i: int, _n: int) -> float:
	return STAGE_TOP + i * STAGE_STEP


func _stage_point(y: float) -> Vector3:
	return _air_point(Vector2(layout.right(STAGE_X), y), 60.0)


## Every frame: landed tokens hover over their slot (slots ease when one is
## added or taken back) and bob gently.
func _stage_follow(delta: float) -> void:
	if staged.is_empty() or layout == null:
		return
	var n := staged.size()
	var t := Time.get_ticks_msec() / 1000.0
	for i in n:
		var e: Dictionary = staged[i]
		var tx := _stage_slot_x(i, n)
		e["x"] = lerpf(float(e.get("x", tx)), tx, 1.0 - exp(-delta * 14.0))
		if e["landed"]:
			var node: Node3D = e["node"]
			node.global_position = _stage_point(float(e["x"])) + Vector3(0, sin(t * 2.4 + i) * 6.0 * U, 0)
			# rocks a little so the light plays on it, easing in after it lands
			var rock := minf((t - float(e["land_t"])) / 0.6, 1.0) * deg_to_rad(6.0)
			node.basis = _facing_cam(sin(t * 1.7 + i) * rock, sin(t * 1.3 + i * 2.0) * rock, (t - float(e["land_t"])) * 0.5).scaled(Vector3.ONE * STAGE_R * U)


## A token held up to you: its face turned to the camera, so it reads as a true
## circle, tipped by `tip` / `roll` and turned by `spin` around its own centre.
func _facing_cam(tip: float, roll: float, spin: float) -> Basis:
	return Basis(Vector3.RIGHT, deg_to_rad(CAM_TILT) + tip) * Basis(Vector3.BACK, roll) * Basis(Vector3.UP, spin)


func _stage_add(col: String) -> void:
	_busy += 1
	var g0 := _gen  # this table; a rebuild makes it stale
	var src: ChipStack = bank[col]
	var chip := src.take_flying(world_root)
	Sfx.play("token_pick")
	var e := {"col": col, "node": chip, "landed": false}
	staged.append(e)
	e["x"] = _stage_slot_x(staged.size() - 1, staged.size())
	var from := chip.global_position
	var s0 := chip.scale.x
	var trail := FX.trail(world_root, Gems.GLOW[col], U)
	trail.global_position = from
	FX.ring(world_root, from, Gems.GLOW[col], U, 70.0, 0.35)
	var tw := chip.create_tween()
	tw.tween_method(func(t: float):
		var to := _stage_point(float(e["x"]))
		var p := from.lerp(to, t)
		p.y += sin(t * PI) * 200.0 * U
		chip.global_position = p
		# two flips, ending face to the camera
		chip.basis = Basis(Vector3.RIGHT, t * (TAU * 2.0 + deg_to_rad(CAM_TILT))) * Basis(Vector3.BACK, sin(t * PI) * 0.5).scaled(Vector3.ONE * lerpf(s0, STAGE_R * U, t))
		trail.global_position = p, 0.0, 1.0, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	FX.stop_trail(trail)
	e["land_t"] = Time.get_ticks_msec() / 1000.0
	e["landed"] = true
	if staged.has(e):
		FX.ring(world_root, chip.global_position, Gems.GLOW[col], U, 90.0, 0.4)
	_done(g0)


func _stage_undo() -> void:
	if staged.is_empty():
		return
	var e: Dictionary = staged.back()
	_busy += 1
	var g0 := _gen  # this table; a rebuild makes it stale
	while not e["landed"]:
		await get_tree().process_frame
	staged.erase(e)
	var chip: Node3D = e["node"]
	var dst: ChipStack = bank[e["col"]]
	await _arc(chip, e["col"], chip.global_position, dst.top_world(), chip.scale.x, dst.world_radius())
	dst.receive(chip)
	Sfx.play("token_return")
	_done(g0)


## Every token in the middle flies to its owner: you (-1) or opponent i.
func _stage_commit(owner: int) -> void:
	var list := staged.duplicate()
	_busy += 1
	var g0 := _gen  # this table; a rebuild makes it stale
	for e in list:
		while not e["landed"]:
			await get_tree().process_frame
	staged.clear()
	var delay := 0.0
	for e in list:
		var chip: Node3D = e["node"]
		var col: String = e["col"]
		if owner < 0:
			_fly_staged_to(chip, col, null, _hud_point(hud.me_token_anchor(col), 40.0), delay, true)
		else:
			_fly_staged_to(chip, col, null, _hud_point(hud.seat_token_anchor(owner, col), 40.0), delay)
		delay += 0.1
	await _wait(delay + 0.65)
	if owner < 0:
		hud.update_me()
	else:
		hud.update_opponent(owner)
	_done(g0)


func _fly_staged_to(chip: Node3D, col: String, dst: ChipStack, point: Vector3, delay: float, to_me := false) -> void:
	if delay > 0.0:
		await _wait(delay)
	if not is_instance_valid(chip) or (dst and not is_instance_valid(dst)):
		return  # the table was built again meanwhile
	if dst:
		await _arc(chip, col, chip.global_position, dst.top_world(), chip.scale.x, dst.world_radius())
		dst.receive(chip)
		FX.burst(world_root, dst.top_world(), Gems.GLOW[col], U, 18, 200.0, 0.5, 10.0)
	else:
		await _arc(chip, col, chip.global_position, point, chip.scale.x, chip.scale.x * (0.9 if to_me else 0.3))
		Sfx.play("token_place", -1.0, 0.0 if to_me else -4.0)
		FX.burst(world_root, point, Gems.GLOW[col], U, 18, 200.0, 0.5, 10.0)
		chip.queue_free()
		if to_me:
			hud.update_me()
			hud.me_view.pop_token(col)


# ------------------------------------------------------------------ token flights

## A token leaves a pile and lands on your tray.
func _fly_to_me(src: ChipStack, delay: float) -> void:
	_busy += 1
	var g0 := _gen  # this table; a rebuild makes it stale
	if delay > 0.0:
		await _wait(delay)
	var chip := src.take_flying(world_root)
	var to := _hud_point(hud.me_token_anchor(src.color), 40.0)
	await _arc(chip, src.color, chip.global_position, to, chip.scale.x, chip.scale.x * 0.9)
	Sfx.play("token_place")
	chip.queue_free()
	FX.burst(world_root, to, Gems.GLOW[src.color], U, 18, 200.0, 0.5, 10.0)
	hud.update_me()
	hud.me_view.pop_token(src.color)
	_done(g0)


func _fly_chip_to_point(src: ChipStack, to: Vector3, delay: float) -> void:
	if delay > 0.0:
		await _wait(delay)
	var chip := src.take_flying(world_root)
	await _arc(chip, src.color, chip.global_position, to, chip.scale.x, chip.scale.x * 0.35)
	Sfx.play("token_place", -1.0, -4.0)
	FX.burst(world_root, to, Gems.GLOW[src.color], U, 14, 160.0, 0.4, 9.0)
	chip.queue_free()


func _fly_chip_from_point(col: String, from: Vector3, dst: ChipStack, delay: float) -> void:
	if delay > 0.0:
		await _wait(delay)
	var chip := ChipStack.make_chip(col)
	world_root.add_child(chip)
	chip.global_position = from
	chip.scale = Vector3.ONE * dst.world_radius() * 0.35
	await _arc(chip, col, from, dst.top_world(), chip.scale.x, dst.world_radius())
	Sfx.play("token_return")
	chip.queue_free()
	dst.set_count(int(bank_counts[col]))
	dst.pop()


func _arc(chip: Node3D, col: String, from: Vector3, to: Vector3, s0: float, s1: float) -> void:
	var trail := FX.trail(world_root, Gems.GLOW[col], U)
	trail.global_position = from
	FX.ring(world_root, from, Gems.GLOW[col], U, 70.0, 0.35)
	var arc := 220.0 * U
	var tw := chip.create_tween()
	tw.tween_method(func(t: float):
		var p := from.lerp(to, t)
		p.y = lerpf(from.y, to.y, t) + sin(t * PI) * arc
		chip.global_position = p
		chip.rotation = Vector3(t * TAU * 2.0, 0.0, sin(t * PI) * 0.5)
		chip.scale = Vector3.ONE * lerpf(s0, s1, t)
		trail.global_position = p, 0.0, 1.0, 0.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	chip.rotation = Vector3.ZERO
	FX.stop_trail(trail)


func _pop(n: Node3D, k := 1.45, dur := 0.45) -> void:
	var base := n.scale
	n.scale = base * k
	var tw := n.create_tween()
	tw.tween_property(n, "scale", base, dur).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


func _shake(n: Node3D) -> void:
	var base := n.position
	var tw := n.create_tween()
	for i in 4:
		tw.tween_property(n, "position", base + Vector3((8.0 if i % 2 == 0 else -8.0), 0, 0), 0.04)
	tw.tween_property(n, "position", base, 0.04)


## An animation of table `g0` has finished: it no longer keeps the board busy
## (unless the table was built again since, which already cleared _busy).
func _done(g0: int) -> void:
	if g0 == _gen:
		_busy = maxi(_busy - 1, 0)


## Wait `s` seconds of play: the wait stands still while the game is paused.
func _wait(s: float) -> void:
	await get_tree().create_timer(s, false).timeout


# ------------------------------------------------------------------ demo

func _wait_my_turn() -> void:
	while turn == 0:
		await get_tree().process_frame
	while turn != 0 or _busy > 0:
		await get_tree().process_frame


## --test=inspect|noble|sheet|results|confirm|buy: one view, for screenshots.
func _run_test(what: String) -> void:
	await _wait(1.6)
	me["coins"] = {"white": 2, "blue": 1, "green": 2, "red": 1, "black": 1, "gold": 1}
	me["cards"]["green"] = 2
	_build()
	await _wait(0.3)
	match what:
		"texts":  # test: the longest banner and stage lines, to check they fit
			hud.set_stage(L.t("opp_taking", "فرشته"), false)
			hud.announce("فرشته خرید", "کارت عقیق سیاه سطح 1", false, 30.0)
		"empty":  # test: empty piles
			for c in Gems.COLORS:
				bank_counts[c] = 0
			_build()
		"design":  # the host's mock-up numbers, to compare with Frame 45
			var cards_ := {"white": 2, "blue": 4, "red": 1, "green": 5, "black": 3}
			var coins_ := {"white": 1, "blue": 2, "red": 3, "green": 4, "black": 5, "gold": 2}
			var names := ["Cpu 3", "Cpu 2", "Cpu 1"]
			var pts := [22, 18, 15]
			for q in [me] + opps:
				q["cards"] = cards_.duplicate()
				q["coins"] = coins_.duplicate()
				q["rating"] = 268
				q["reserved"] = [(decks[1] as Array)[0], (decks[2] as Array)[0]]
			for k in opps.size():
				opps[k]["name"] = names[k]
				opps[k]["prestige"] = pts[k]
			me["prestige"] = 25
			me["reserved"] = []
			_build()
			hud.turn_started = Time.get_ticks_msec() / 1000.0 - 27.0
		"nobles":  # you qualify for two nobles at once: choose one
			for c in Gems.COLORS:
				me["cards"][c] = 4
			_build()
			await _check_nobles(-1)
		"pulse":  # the portrait of the player on turn beats
			for k in 8:
				print("PULSE me=%.3f seat1=%.3f" % [hud.me_view._face.scale.x, hud.seats[0]._face.scale.x])
				await _wait(0.2)
		"netdrop":  # the server stops answering mid-game
			Net.force("off")
		"inspect":
			open_inspect(cards[5])
		"fan":
			for t in [1, 2, 3]:
				(me["reserved"] as Array).append((decks[t] as Array).pop_back())
			hud.update_me()
			await _wait(0.3)
			open_fan()
		"noble":
			_show_noble(1)
		"sheet":
			opps[0]["cards"]["red"] = 3
			opps[0]["coins"]["blue"] = 2
			open_player(1)
		"results":
			me["prestige"] = 16
			opps[0]["prestige"] = 12
			_finish_game()
		"confirm":
			reserve_blind(2)
		"pick":  # three tokens taken, held up in the middle
			for col in ["red", "blue", "white"]:
				take_coin(col)
				await _wait(0.25)
		"buy":
			for c in cards:
				if can_afford(me, c.data):
					open_inspect(c)
					await _wait(0.8)
					_on_buy_pressed()
					break


func _run_demo() -> void:
	await _wait(1.6)
	take_coin("red")
	await _wait(0.5)
	take_coin("blue")
	await _wait(0.5)
	take_coin("green")
	await _wait(1.2)
	done_picking()
	await _wait_my_turn()
	await _wait(1.0)
	open_inspect(cards[4])
	await _wait(1.6)
	reserve_card(cards[4])
	await _wait_my_turn()
	await _wait(1.0)
	_show_noble(0)
	await _wait(1.8)
	hud.close_modal()


## Test: play every one of your online turns by itself (buy what you can,
## else take gems, else reserve), to check a whole game against the server.
func _autoplay() -> void:
	while not game_over and is_inside_tree():
		await _wait(0.6)
		if not _my_turn() or _busy > 0 or intro_running or not picks.is_empty():
			continue
		await _wait(0.8)
		if not _my_turn():
			continue
		if _video():
			await _video_my_move()
			continue
		var bought := false
		for c in cards:
			if c.visible and not c.data.is_empty() and can_afford(me, c.data):
				open_inspect(c)
				await _wait(0.6)
				_on_buy_pressed()
				bought = true
				break
		if bought:
			continue
		var room := MAX_COINS - _coin_total()
		var cols: Array = Gems.COLORS.filter(func(col): return int(bank_counts[col]) > 0)
		cols.shuffle()
		if room > 0 and not cols.is_empty():
			for col in cols.slice(0, mini(3, room)):
				take_coin(col)
				await _wait(0.5)
			await _wait(0.4)
			_finish_picking()
			continue
		for c in cards:
			if c.visible and not c.data.is_empty() and (me["reserved"] as Array).size() < RESERVE_MAX:
				open_inspect(c)
				await _wait(0.6)
				_on_reserve_pressed()
				break


# ------------------------------------------------------------------ store videos

## Test (store videos): `--video-script` plays a set story at a person's pace.
## In rounds 1 and 2 everyone takes gems; in round 2 the player started with
## `--video-reserve` reserves a card instead. From round 3 everyone buys a card
## when they can, else takes gems. Each move takes 7 to 30 seconds.
func _video() -> bool:
	return OS.get_cmdline_user_args().has("--video-script")


func _video_pace() -> float:
	var t := 7.0 + 23.0 * pow(randf(), 1.6)  # mostly short, now and then a long think
	return maxf(t / 10.0, 1.6) if OS.get_cmdline_user_args().has("--video-fast") else t  # --video-fast: checks


## The story's move for player `p`: {"kind": "buy" | "reserve", "card"} or
## {"kind": "take", "colors"}.
func _video_move(p: Dictionary, reserver: bool) -> Dictionary:
	var shown: Array = cards.filter(func(c: SCard): return c.visible and not c.data.is_empty())
	var keeps := reserver or (absi(String(p["name"]).hash()) % 3 == 0 and round_no == 1 + absi(String(p["name"]).hash()) % 2)
	if (round_no == 2 or not reserver) and keeps and (p["reserved"] as Array).is_empty() and round_no <= 2:
		# a card worth points that is near to buy: kept now, bought a round or two later
		var best: SCard = null
		var score := func(c: SCard) -> int:
			return _gold_needed(p, c.data) * 3 - int(c.data.get("points", 0)) * 2
		for c in shown:
			if best == null or score.call(c) < score.call(best):
				best = c
		if best:
			return {"kind": "reserve", "card": best}
	if round_no >= 3:
		var res: Array = p["reserved"]
		for k in res.size():  # a card kept back is bought first, once it can be
			if can_afford(p, res[k]):
				return {"kind": "buy_reserved", "k": k}
		var buy: SCard = null
		for c in shown:
			if can_afford(p, c.data) and (buy == null or int(c.data.get("points", 0)) > int(buy.data.get("points", 0))):
				buy = c
		if buy:
			return {"kind": "buy", "card": buy}
	# gems toward the card that is nearest to buy, so buying can start in round 3
	var room := MAX_COINS - _total(p)
	var target: SCard = null
	for c in shown:
		if target == null or _gold_needed(p, c.data) < _gold_needed(p, target.data):
			target = c
	var need: Dictionary = _cost_after_bonus(p, target.data) if target else {}
	var cols: Array = Gems.COLORS.filter(func(col): return int(bank_counts[col]) > 0)
	cols.shuffle()
	cols.sort_custom(func(a, b):
		var da := int(need.get(a, 0)) - int(p["coins"][a])
		var db := int(need.get(b, 0)) - int(p["coins"][b])
		return da > db if da != db else int(bank_counts[a]) > int(bank_counts[b]))
	# players differ from the start: about half take two of the colour they
	# need most in round 1, the others in round 2 (two of a colour need a pile
	# of 4 or more); one in three keeps a card back in round 1 or 2 too
	var two_round := 1 + absi(String(p["name"]).hash()) % 2
	if round_no == two_round and not reserver and room >= 2 and not cols.is_empty() and int(bank_counts[cols[0]]) >= 4:
		return {"kind": "take", "colors": [cols[0], cols[0]]}
	return {"kind": "take", "colors": cols.slice(0, mini(3, room))}


## The story's move, logged (the recordings are checked against it).
func _video_logged(p: Dictionary, reserver: bool) -> Dictionary:
	var mv := _video_move(p, reserver)
	print("VIDEOMOVE round=%d %s %s" % [round_no, String(p["name"]), mv["kind"]])
	return mv


## Your move in the story, played through the table as a player would.
func _video_my_move() -> void:
	await _wait(_video_pace() - 1.4)
	if not _my_turn():
		return
	var mv := _video_logged(me, OS.get_cmdline_user_args().has("--video-reserve"))
	match String(mv["kind"]):
		"buy":
			open_inspect(mv["card"])
			await _wait(1.0)
			_on_buy_pressed()
		"buy_reserved":
			open_fan()
			await _wait(1.3)
			var k := int(mv["k"])
			if k < fan.size():
				open_inspect(fan[k], k)
				await _wait(1.1)
				_on_buy_pressed()
		"reserve":
			open_inspect(mv["card"])
			await _wait(1.2)
			_on_reserve_pressed()
		_:
			for col in mv["colors"]:
				take_coin(col)
				await _wait(0.55)
			await _wait(0.5)
			_finish_picking()
