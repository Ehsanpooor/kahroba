extends Node
## Autoload "Sfx": the game's sounds and its music. Sfx.play("token_pick")
## plays a sound by its meaning (a few takes of it at random, a little pitch
## variation so repeats do not sound mechanical, several at once from a small
## pool). Sfx.music(true, "game") fades the music in (or crossfades from the
## menu's), Sfx.music(false) fades it out. "menu" and "game" are playlists: a
## piece is picked at random, and near its end the next one (never the same
## piece twice in a row) crossfades in; a playlist of one simply loops.
## Volumes follow Settings live
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
## playlist: [[file (without .ogg), volume dB], ...]. The new pieces are
## levelled to the same loudness as game_suonatore_di_liuto (-21.6 LUFS), so
## in-game they all sit at -5 dB; the menu plays louder, as it always did.
const TRACKS := {
	"menu": [
		["menu_bards_tale", -4.0],
		["music_midnight_tale", 1.0],
	],
	"game": [
		["game_suonatore_di_liuto", -5.0],
		["music_village_consort", -5.0],
		["music_midnight_tale", -5.0],
		["music_minstrel_dance", -5.0],
	],
}
const VOICES := 12
const FADE := 1.4
const SEGUE := 4.0  # seconds of crossfade from one piece of a playlist to the next
const MIN_PIECE := 100.0  # a short loop goes round again until it has played this long
const SILENT := -60.0

var _streams := {}  # name -> Array of AudioStream (loaded on first use)
var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _last := {}  # name -> msec it last started (the same sound is not stacked in one instant)
var _decks: Array[AudioStreamPlayer] = []  # two music players, for crossfades
var _cur := 0
var _track := ""  # the playlist playing ("menu" / "game")
var _piece := ""  # the file playing from it
var _piece_at := 0  # msec it started
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


## Music on (playlist "menu" or "game"; "" keeps the current one) or off,
## with a gentle fade; a different playlist crossfades to a piece of its own.
func music(on: bool, track := "") -> void:
	if track == "":
		track = _track if _track != "" else "menu"
	if not on:
		_music_on = false
		_fade(_decks[_cur], SILENT, FADE, true)
		return
	if not TRACKS.has(track):
		return
	var deck := _decks[_cur]
	if track == _track and deck.playing:
		if not _music_on:  # turned back on while fading out: the same piece comes back
			_music_on = true
			for d in TRACKS[track]:
				if String(d[0]) == _piece:
					_fade(deck, float(d[1]), FADE, false)
		return
	_track = track
	_music_on = true
	_segue(FADE)


## Crossfade to a piece of the current playlist other than the one playing
## (the same one again only when the list has nothing else).
func _segue(dur: float) -> void:
	var picks: Array = []
	for d in TRACKS[_track]:
		if ResourceLoader.exists(MUSIC_DIR + String(d[0]) + ".ogg"):
			picks.append(d)
	if picks.is_empty():
		return
	var deck := _decks[_cur]
	if picks.size() > 1:
		picks = picks.filter(func(d): return String(d[0]) != _piece)
	var def: Array = picks.pick_random()
	if String(def[0]) == _piece and deck.playing:
		_fade(deck, float(def[1]), dur, false)  # the one piece there is goes on
		return
	if deck.playing:
		_fade(deck, SILENT, dur, true)  # the old piece goes out under the new one
		_cur = 1 - _cur
		deck = _decks[_cur]
	var s := load(MUSIC_DIR + String(def[0]) + ".ogg") as AudioStream
	if s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = true  # it loops if nothing else follows
	deck.stream = s
	deck.volume_db = SILENT
	deck.play()
	_piece = String(def[0])
	_piece_at = Time.get_ticks_msec()
	_fade(deck, float(def[1]), dur, false)


## Near the end of a piece the next one of its playlist takes over (a short
## loop first goes round again until it has played MIN_PIECE seconds).
func _process(_delta: float) -> void:
	if not _music_on or _piece == "" or TRACKS.get(_track, []).size() < 2:
		return
	var deck := _decks[_cur]
	if not deck.playing or deck.stream == null:
		return
	var left := deck.stream.get_length() - deck.get_playback_position()
	var played := (Time.get_ticks_msec() - _piece_at) / 1000.0
	if left < SEGUE + 0.25 and played + left >= MIN_PIECE:
		_segue(SEGUE)


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
