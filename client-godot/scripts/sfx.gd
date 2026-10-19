extends Node
## Autoload "Sfx": the game's sounds and its music. Sfx.play("token_pick")
## plays a sound by its meaning (a few takes of it at random, a little pitch
## variation so repeats do not sound mechanical, several at once from a small
## pool). Sfx.music(true, "game") fades the loop in (or crossfades to another
## track), Sfx.music(false) fades it out. Volumes follow Settings live
## (Prefs "sound" and "music", 0..1), on the buses "SFX" and "Music".
## A missing file is skipped quietly.

const SFX_DIR := "res://assets/audio/sfx/"
const MUSIC_DIR := "res://assets/audio/music/"
## name: [takes (files without .ogg), volume dB, pitch spread]
const SOUNDS := {
	"button_tap": [["button_tap"], -8.0, 0.04],
	"dialog_open": [["dialog_open"], -2.0, 0.05],
	"token_pick": [["token_pick_1", "token_pick_2", "token_pick_3"], -2.0, 0.08],
	"token_place": [["token_place_1", "token_place_2", "token_place_3"], -3.0, 0.1],
	"token_return": [["token_return_1", "token_return_2"], -4.0, 0.1],
	"card_deal": [["card_deal_1", "card_deal_2", "card_deal_3", "card_deal_4"], -3.0, 0.08],
	"card_buy": [["card_buy_1", "card_buy_2"], 0.0, 0.05],
	"card_reserve": [["card_reserve"], -1.0, 0.05],
	"noble_visit": [["noble_visit"], -1.0, 0.0],
	"turn_mine": [["turn_mine"], -5.0, 0.0],
	"turn_other": [["turn_other"], -16.0, 0.03],
	"clock_tick": [["clock_tick"], -6.0, 0.0],
	"time_up": [["time_up"], -2.0, 0.0],
	"denied": [["denied"], -8.0, 0.0],
	"win": [["win"], 0.0, 0.0],
	"lose": [["lose"], -2.0, 0.0],
	"game_start": [["game_start"], -2.0, 0.0],
}
## track: [file, volume dB]
const TRACKS := {
	"menu": ["menu_bards_tale", -4.0],
	"game": ["game_suonatore_di_liuto", -5.0],
}
const VOICES := 12
const FADE := 1.4
const SILENT := -60.0

var _streams := {}  # name -> Array of AudioStream (loaded on first use)
var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _last := {}  # name -> msec it last started (the same sound is not stacked in one instant)
var _decks: Array[AudioStreamPlayer] = []  # two music players, for crossfades
var _cur := 0
var _track := ""
var _music_on := false
var _fades := {}  # player -> its fade tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # sounds go on while the table is paused
	_bus("SFX")
	_bus("Music")
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_pool.append(p)
	for i in 2:
		var m := AudioStreamPlayer.new()
		m.bus = "Music"
		m.volume_db = SILENT
		add_child(m)
		_decks.append(m)
	_apply_volumes()
	Prefs.changed.connect(_on_pref_changed)


## Play a sound by its meaning. pitch_var < 0 uses the sound's own spread;
## db is added to its volume (e.g. -6 for a quieter echo of it).
func play(sound: String, pitch_var := -1.0, db := 0.0) -> void:
	var def: Array = SOUNDS.get(sound, [])
	if def.is_empty():
		return
	var takes := _takes(sound, def[0])
	if takes.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - int(_last.get(sound, -1000)) < 35:
		return
	_last[sound] = now
	var p := _voice()
	p.stream = takes.pick_random()
	p.volume_db = float(def[1]) + db
	var spread := float(def[2]) if pitch_var < 0.0 else pitch_var
	p.pitch_scale = 1.0 + randf_range(-spread, spread)
	p.play()


## Music on (track "menu" or "game"; "" keeps the current one) or off, with a
## gentle fade; a different track crossfades.
func music(on: bool, track := "") -> void:
	if track == "":
		track = _track if _track != "" else "menu"
	if not on:
		_music_on = false
		_fade(_decks[_cur], SILENT, FADE, true)
		return
	var deck := _decks[_cur]
	if _music_on and track == _track and deck.playing:
		return
	var def: Array = TRACKS.get(track, [])
	if def.is_empty():
		return
	var path: String = MUSIC_DIR + String(def[0]) + ".ogg"
	if not ResourceLoader.exists(path):
		return
	if track != _track or not deck.playing:
		if deck.playing:
			_fade(deck, SILENT, FADE, true)  # the old track goes out under the new one
			_cur = 1 - _cur
			deck = _decks[_cur]
		var s := load(path) as AudioStream
		if s is AudioStreamOggVorbis:
			(s as AudioStreamOggVorbis).loop = true
		deck.stream = s
		deck.volume_db = SILENT
		deck.play()
	_track = track
	_music_on = true
	_fade(deck, float(def[1]), FADE, false)


func _takes(sound: String, files: Array) -> Array:
	if _streams.has(sound):
		return _streams[sound]
	var out := []
	for f in files:
		var path: String = SFX_DIR + String(f) + ".ogg"
		if ResourceLoader.exists(path):
			var s := load(path) as AudioStream
			if s:
				out.append(s)
	_streams[sound] = out
	return out


## A free player from the pool (the oldest one when all are busy).
func _voice() -> AudioStreamPlayer:
	for k in VOICES:
		var p := _pool[(_next + k) % VOICES]
		if not p.playing:
			_next = (_next + k + 1) % VOICES
			return p
	var p := _pool[_next]
	_next = (_next + 1) % VOICES
	return p


func _fade(p: AudioStreamPlayer, to_db: float, dur: float, stop_after: bool) -> void:
	var old: Tween = _fades.get(p)
	if old and old.is_valid():
		old.kill()
	var tw := create_tween()
	tw.tween_property(p, "volume_db", to_db, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT if not stop_after else Tween.EASE_IN)
	if stop_after:
		tw.tween_callback(p.stop)
	_fades[p] = tw


func _bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) >= 0:
		return
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, bus_name)
	AudioServer.set_bus_send(i, "Master")


func _on_pref_changed(key: String) -> void:
	if key in ["sound", "music"]:
		_apply_volumes()


## "sound" drives the SFX bus, "music" the Music bus; Master stays at full
## (Prefs sets Master from "sound", which would also turn the music down).
func _apply_volumes() -> void:
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_volume_db(master, 0.0)
	AudioServer.set_bus_mute(master, false)
	_set_bus("SFX", float(Prefs.get_v("sound")))
	_set_bus("Music", float(Prefs.get_v("music")))


func _set_bus(bus_name: String, v: float) -> void:
	var i := AudioServer.get_bus_index(bus_name)
	if i < 0:
		return
	AudioServer.set_bus_volume_db(i, linear_to_db(maxf(v, 0.0001)))
	AudioServer.set_bus_mute(i, v <= 0.001)
