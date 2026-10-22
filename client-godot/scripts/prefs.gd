extends Node
## Autoload "Prefs": the player's settings (saved on the device) and the
## little state the screens hand to each other (which game to start, which
## screen to open when coming back from a game).

signal changed(key: String)

const PATH := "user://settings.cfg"
const DEFAULTS := {
	"lang": "fa",  # Persian is the main language; the first start asks
	"view_mode": 0,  # board view: 0 normal, 1 names (rows closer), 2 faded portraits
	"brightness": 1.0,  # 0.6 .. 1.4
	"music": 0.7,
	"sound": 0.8,
	"vibration": true,
	"confirm_moves": true,  # Skip, short coin take and blind jail ask first
	"tutorial_done": false,
	"tutorial_offered": false,  # "Later" was chosen: the menu does not ask again
	"onboarded": false,  # language, name and portrait chosen
	"name": "",
	"portrait": "A-01",  # a character id, or "custom" for the player's own photo
	"rating": 1000,  # a new player's rating (the server's DefaultRating)
	"server": "",  # the game server's address ("" = Net.DEFAULT_SERVER)
	"device_id": "",  # this device's sign-in on the server, made on first use
	"email": "",  # the account's recovery email, once checked
	"email_nag_at": 1000,  # the rating of the last "add an email" reminder (one every 50 points)
}

var data := {}
## The game the board starts: mode "ai" | "online" | "friends" | "tutorial",
## players 2..4, difficulty "easy" | "normal" | "hard".
var game := {"mode": "ai", "players": 4, "difficulty": "normal"}
## The screen the app opens on ("splash" on a cold start, "menu" after a game).
var start_screen := "splash"

var _bright: ColorRect


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--fresh"):
		_wipe()  # test: start as a brand-new player
	data = DEFAULTS.duplicate()
	var cf := ConfigFile.new()
	if cf.load(PATH) == OK:
		for k in DEFAULTS:
			data[k] = cf.get_value("prefs", k, DEFAULTS[k])
	L.code = String(data["lang"])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--lang="):  # test: show another language without saving it
			L.code = a.get_slice("=", 1)
	# brightness: the whole picture, drawn over everything
	var layer := CanvasLayer.new()
	layer.layer = 128
	add_child(layer)
	_bright = ColorRect.new()
	_bright.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bright.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/brightness.gdshader")
	_bright.material = m
	layer.add_child(_bright)
	_apply()


func get_v(key: String) -> Variant:
	return data.get(key, DEFAULTS.get(key))


func set_v(key: String, value: Variant) -> void:
	data[key] = value
	if key == "lang":
		L.code = String(value)
		Fonts.clear()
	_save()
	_apply()
	changed.emit(key)


## Finished games on this device, newest first: {result, mode, players,
## difficulty, power, rating_delta, played_at, seats:[{name, portrait, power}],
## moves:[...]}. Only the newest 3 keep their moves (the replays).
const HISTORY_PATH := "user://history.json"
const KEEP_GAMES := 50
const KEEP_REPLAYS := 3


func history() -> Array:
	if not FileAccess.file_exists(HISTORY_PATH):
		return []
	var f := FileAccess.open(HISTORY_PATH, FileAccess.READ)
	var v: Variant = JSON.parse_string(f.get_as_text())
	return v if v is Array else []


func add_history(entry: Dictionary) -> void:
	var h := history()
	h.push_front(entry)
	if h.size() > KEEP_GAMES:
		h.resize(KEEP_GAMES)
	for i in range(KEEP_REPLAYS, h.size()):
		(h[i] as Dictionary).erase("moves")
	var f := FileAccess.open(HISTORY_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify(h))


## Forget everything on this device: settings, profile, photo, history.
func reset_all() -> void:
	_wipe()
	data = DEFAULTS.duplicate()
	L.code = String(data["lang"])
	Fonts.clear()
	Tex.forget(Tex.CUSTOM)
	_apply()
	changed.emit("sound")
	changed.emit("music")


func _wipe() -> void:
	for f in [PATH, HISTORY_PATH, Tex.CUSTOM_FILE, SavedGame.PATH]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(f))


## The name to show (a new player has none yet).
func display_name() -> String:
	var n := String(get_v("name")).strip_edges()
	return n if n != "" else L.t("player")


## A short buzz on phones, when vibration is on.
func buzz(ms := 30) -> void:
	if get_v("vibration"):
		Input.vibrate_handheld(ms)


func _save() -> void:
	var cf := ConfigFile.new()
	for k in data:
		cf.set_value("prefs", k, data[k])
	cf.save(PATH)


func _apply() -> void:
	var b := float(get_v("brightness"))
	_bright.visible = absf(b - 1.0) > 0.01
	(_bright.material as ShaderMaterial).set_shader_parameter("brightness", b)
	# sound and music volumes: the Sfx autoload follows `changed`
