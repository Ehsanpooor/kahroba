extends Node
## Autoload "Remote": the settings the game server hands every app
## (docs/REMOTE_CONFIG_ADS_ANALYTICS.md): the ad switches, the oldest and the
## newest app version, an announcement, the rate prompt and the analytics
## switch. Asked once the server answers (`get_client_config`), kept on the
## device so the last answer still holds offline, and the built-in defaults
## until the first answer ever arrives. `updated` fires on every new answer.
##
## Test flag (after `--`): `--fakeconfig=<json file>` takes the config from a
## file instead of the server (to see the update, announcement and rate
## dialogs).

signal updated

const CACHE := "user://remote_config.json"
const REFETCH_AFTER := 1800.0  ## seconds: coming back to the app asks again after this long
## The server's own defaults (runtime/remote_config.go), used until it answers.
const DEFAULTS := {
	"ads": {
		"enabled": false,
		"minIntervalSec": 180,
		"adBreakMaxSec": 30,
		"slots": {
			"pregame_online": {"enabled": false},
			"pregame_ai": {"enabled": false},
			"postgame": {"enabled": false},
		},
	},
	"minVersion": "0.9.3",
	"latestVersion": "0.9.4",
	"updateUrl": "https://cafebazaar.ir/app/ir.aizood.splendor",
	"updateMessage": {"fa": "", "en": ""},
	"announcement": null,
	"ratePrompt": {"enabled": true, "afterWins": 2},
	"analytics": {"enabled": true, "flushSec": 30},
}

var config: Dictionary = DEFAULTS.duplicate(true)
var fetched := false  ## the server answered during this launch
var _fake := false
var _busy := false
var _fetched_at := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fakeconfig="):
			_load_fake(a.get_slice("=", 1))
			return
	var cached: Variant = _read_json(CACHE)
	if cached is Dictionary:
		config = _merged(DEFAULTS, cached)
	Net.changed.connect(func(online: bool):
		if online and not fetched:
			fetch())
	if Net.online:
		fetch()


## Ask the server for the config now. Never throws; on failure the config
## stays as it was.
func fetch() -> void:
	if _fake or _busy:
		return
	_busy = true
	var r: Dictionary = await Api.rpc_call("get_client_config", {})
	_busy = false
	if OS.get_cmdline_user_args().has("--netdebug"):
		print("REMOTE get_client_config: ok=%s code=%d %s" % [r["ok"], int(r["code"]), String(r["message"])])
	if not r["ok"] or not (r["data"] is Dictionary) or (r["data"] as Dictionary).is_empty():
		return
	config = _merged(DEFAULTS, r["data"])
	fetched = true
	_fetched_at = Time.get_ticks_msec() / 1000.0
	var f := FileAccess.open(CACHE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(r["data"]))
	updated.emit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if fetched and Net.online and Time.get_ticks_msec() / 1000.0 - _fetched_at > REFETCH_AFTER:
			fetch()


## Test: the config from a json file, as if the server had sent it.
func _load_fake(path: String) -> void:
	_fake = true
	var v: Variant = _read_json(path)
	if v is Dictionary:
		config = _merged(DEFAULTS, v)
		fetched = true
	else:
		push_warning("fakeconfig: cannot read " + path)
	updated.emit.call_deferred()


# ------------------------------------------------------------------ reading it

## This app's version (project.godot application/config/version).
func app_version() -> String:
	return String(ProjectSettings.get_setting("application/config/version", "0.0.0"))


## True when version `a` is older than `b`, comparing dotted numbers
## (0.9.10 is newer than 0.9.9; a missing part counts as 0).
static func version_less(a: String, b: String) -> bool:
	var pa := a.strip_edges().split(".")
	var pb := b.strip_edges().split(".")
	for i in maxi(pa.size(), pb.size()):
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return x < y
	return false


## This app is older than the oldest version the server still accepts.
func must_update() -> bool:
	var v := String(config.get("minVersion", ""))
	return v != "" and version_less(app_version(), v)


## A newer version than this one is out.
func update_available() -> bool:
	var v := String(config.get("latestVersion", ""))
	return v != "" and version_less(app_version(), v)


func latest_version() -> String:
	return String(config.get("latestVersion", ""))


func update_url() -> String:
	var u := String(config.get("updateUrl", ""))
	return u if u != "" else String(DEFAULTS["updateUrl"])


## The server's own words for the update dialog in the current language, or "".
func update_message() -> String:
	var m: Variant = config.get("updateMessage")
	return String((m as Dictionary).get(L.code, "")) if m is Dictionary else ""


## The announcement {id, text} in the current language, or {} for none.
func announcement() -> Dictionary:
	var a: Variant = config.get("announcement")
	if not (a is Dictionary):
		return {}
	var id := String(a.get("id", ""))
	var t := String(a.get(L.code, ""))
	if t == "":
		t = String(a.get("fa", a.get("en", "")))
	if id == "" or t.strip_edges() == "":
		return {}
	return {"id": id, "text": t}


## The ad master switch and this slot's switch are both on.
func ad_slot_on(slot: String) -> bool:
	var ads: Dictionary = _dict(config.get("ads"))
	if not bool(ads.get("enabled", false)):
		return false
	return bool(_dict(_dict(ads.get("slots")).get(slot)).get("enabled", false))


## Seconds that must pass between two ads.
func ad_min_interval() -> float:
	return float(_dict(config.get("ads")).get("minIntervalSec", 180))


func rate_prompt_on() -> bool:
	return bool(_dict(config.get("ratePrompt")).get("enabled", false))


func rate_after_wins() -> int:
	return maxi(int(_dict(config.get("ratePrompt")).get("afterWins", 2)), 1)


func analytics_on() -> bool:
	return bool(_dict(config.get("analytics")).get("enabled", true))


func analytics_flush_sec() -> float:
	return clampf(float(_dict(config.get("analytics")).get("flushSec", 30)), 5.0, 3600.0)


# ------------------------------------------------------------------ helpers

static func _dict(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}


## `over` laid on `base`, key by key (nested dictionaries too); a value of
## another kind than the default's is ignored, except for the announcement.
static func _merged(base: Dictionary, over: Dictionary) -> Dictionary:
	var out := base.duplicate(true)
	for k in over:
		var v: Variant = over[k]
		if not out.has(k) or out[k] == null:
			out[k] = v
		elif out[k] is Dictionary and v is Dictionary:
			out[k] = _merged(out[k], v)
		elif typeof(out[k]) == typeof(v) or (out[k] is float or out[k] is int) and (v is float or v is int):
			out[k] = v
	return out


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())
