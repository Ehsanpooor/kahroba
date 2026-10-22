extends Node
## The app: opens the screens (splash, menu, play, settings, ...) one at a
## time with a short fade, keeps the way back, and starts the game board.
##
## Test flags (after `--`):  --screen=menu|play|settings|howto|leaderboard|history
## Any board flag (--demo, --no-intro, --jail, ...) or --board goes straight
## to the board, as before.

const SCREENS := {
	"splash": "res://scripts/screens/splash.gd",
	"menu": "res://scripts/screens/menu.gd",
	"play": "res://scripts/screens/play_select.gd",
	"settings": "res://scripts/screens/settings_screen.gd",
	"howto": "res://scripts/screens/howto.gd",
	"leaderboard": "res://scripts/screens/leaderboard.gd",
	"history": "res://scripts/screens/history.gd",
	"profile": "res://scripts/screens/profile.gd",
	"replay": "res://scripts/screens/replay.gd",
	"welcome": "res://scripts/screens/welcome.gd",
}
## Screens that are never returned to with Back.
const NO_RETURN := ["splash", "welcome"]
const BOARD_FLAGS := ["--board", "--demo", "--no-intro", "--award", "--views", "--compact", "--jail",
		"--jail1", "--ui", "--scroll", "--plaque", "--starter2", "--tutorial", "--resume"]

var layer: CanvasLayer
var current: Screen
var stack: Array = []  # [[name, arg], ...] the way back


func _ready() -> void:
	get_tree().set_quit_on_go_back(false)
	var args := OS.get_cmdline_user_args()
	if not Prefs.has_meta("launched"):  # test flags apply to the first launch only
		Prefs.set_meta("launched", true)
	else:
		args = PackedStringArray()
	if args.has("--compilecheck"):  # test: every script loads
		for d in ["res://scripts/", "res://scripts/screens/"]:
			for f in DirAccess.get_files_at(d):
				if f.ends_with(".gd"):
					var sc: Script = load(d + f)
					if sc == null or not sc.can_instantiate():
						printerr("SCRIPT FAILS: ", d + f)
		print("compile check done")
		get_tree().quit()
		return
	for a in args:
		if a.begins_with("--nettest="):
			add_child(load("res://scripts/dev_net.gd").new())
			return
	if args.has("--apitest"):
		add_child(load("res://scripts/dev_tests.gd").new())
		return
	if args.has("--aiarena"):  # test: the computer levels play each other (dev_ai_arena.gd)
		add_child(load("res://scripts/dev_ai_arena.gd").new())
		return
	if args.has("--resume"):  # test: straight back into the saved game
		var d := SavedGame.read()
		Prefs.game = {"mode": d.get("mode", "ai"), "players": (d.get("opps", []) as Array).size() + 1, "resume": true}
	if args.has("--tutorial"):
		Prefs.game = {"mode": "tutorial", "players": 2, "difficulty": "easy"}
	for f in BOARD_FLAGS:
		if args.has(f):
			get_tree().change_scene_to_file.call_deferred("res://scenes/board.tscn")
			return
	layer = CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	var first: String = Prefs.start_screen
	var first_arg: Variant = null
	for a in args:
		if a.begins_with("--screen="):  # e.g. --screen=menu, --screen=welcome:3
			var parts := a.get_slice("=", 1).split(":")
			first = parts[0]
			if parts.size() > 1:
				first_arg = int(parts[1])
	Prefs.start_screen = "splash"
	open(first, first_arg)
	_email_test(args)
	_shot_if_asked(args)


## --emailtest=link|recover|code: open the recovery email dialogs (checks).
func _email_test(args: PackedStringArray) -> void:
	for a in args:
		if a.begins_with("--emailtest="):
			await get_tree().create_timer(0.6).timeout
			var p := a.get_slice("=", 1)
			if p == "code":
				EmailFlow._code_step(current, "link", "sara.k@gmail.com", func(_d: Dictionary): pass)
			else:
				EmailFlow.open(current, p, func(_d: Dictionary): pass)


## --shot=<file> [--shot-at=<s>]: save what is on screen, then quit (checks).
func _shot_if_asked(args: PackedStringArray) -> void:
	var path := ""
	var at := 2.0
	for a in args:
		if a.begins_with("--shot="):
			path = a.get_slice("=", 1)
		elif a.begins_with("--shot-at="):
			at = float(a.get_slice("=", 1))
	if path == "":
		return
	await get_tree().create_timer(at).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()


func open(screen_name: String, arg: Variant = null, remember := true) -> void:
	if not SCREENS.has(screen_name):
		push_warning("no screen " + screen_name)
		return
	if remember and current and not (current.get_meta("name") in NO_RETURN):
		stack.append([current.get_meta("name"), current.arg])
	var old := current
	var s: Screen = load(SCREENS[screen_name]).new()
	s.set_meta("name", screen_name)
	s.arg = arg
	s.go.connect(func(n: String, a: Variant): open(n, a))
	s.back.connect(go_back)
	s.play.connect(start_game)
	current = s
	layer.add_child(s)
	s.modulate.a = 0.0
	var tw := s.create_tween()
	tw.tween_property(s, "modulate:a", 1.0, 0.22)
	if old:
		old.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tw2 := old.create_tween()
		tw2.tween_property(old, "modulate:a", 0.0, 0.18)
		tw2.tween_callback(old.queue_free)


func go_back() -> void:
	if stack.is_empty():
		if current and current.get_meta("name") != "menu":
			open("menu", null, false)
		return
	var prev: Array = stack.pop_back()
	open(prev[0], prev[1], false)


func start_game(game: Dictionary) -> void:
	Prefs.game = game
	var cover := ColorRect.new()
	cover.color = Color(0, 0, 0, 0)
	cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(cover)
	var tw := cover.create_tween()
	tw.tween_property(cover, "color:a", 1.0, 0.3)
	tw.tween_callback(func(): get_tree().change_scene_to_file("res://scenes/board.tscn"))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_handle_back()


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and (e as InputEventKey).keycode == KEY_ESCAPE:
		_handle_back()


func _handle_back() -> void:
	if current and current.on_back():
		return
	if current and current.get_meta("name") == "menu":
		return  # the menu is home; the system closes the app
	go_back()
