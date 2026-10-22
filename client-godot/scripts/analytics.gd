extends Node
## Autoload "Analytics": our own game analytics (docs/REMOTE_CONFIG_ADS_ANALYTICS.md
## §3). `Analytics.event(name, props)` puts an event in a queue; the queue is
## sent to our server (`track`, at most 50 events a call) every
## `analytics.flushSec` seconds and when the app goes to the background, and is
## kept on the device (the newest 500) so games played offline are counted
## later. Nothing here ever throws or waits: with no server the queue simply
## stays.
##
## Script errors are sent as `error` events (each message once, at most 20 a
## launch). A launch that did not end cleanly is sent as `crash` on the next
## start, with the end of its log.
##
## Test runs (--nettest, --aiarena, --compilecheck, --shot, ...) send nothing;
## `--analytics` sends anyway.

const QUEUE_FILE := "user://analytics_queue.json"
const MARKER := "user://running.marker"  ## present while the app runs in front
const KEEP := 500  ## events kept while unsent
const PER_CALL := 50
const PROPS_MAX := 2000  ## bytes of props (the server takes up to 2048)
const CRASH_LOG_MAX := 4096
const DEV_FLAGS := ["--nettest", "--aiarena", "--compilecheck", "--shot", "--apitest", "--demo", "--test=",
		"--autoplay", "--fakeconfig", "--emailtest", "--device=", "--tutauto", "--bench"]

var on := true  ## false in test runs: nothing is recorded or sent
var session_id := ""
var _queue: Array = []  ## [{n, t, p}], oldest first
var _sending := 0  ## events of the queue's front now on their way
var _dirty := false
var _wait := 0.0
var _save_wait := 0.0
var _started := 0.0  ## when this stretch in front began (ticks, s)
var _logger: ErrorLog


## Catches the engine's and the scripts' errors. It may be called from any
## thread and must never cause an error itself: it only queues, under a lock.
class ErrorLog extends Logger:
	const LIMIT := 20  ## errors sent in one launch
	var lock := Mutex.new()
	var pending: Array = []  ## [{msg, file, line}]
	var seen := {}
	var count := 0
	var inside := false

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_ERROR and error_type != ERROR_TYPE_SCRIPT:
			return  # warnings and shader messages are not sent
		lock.lock()
		if inside or count >= LIMIT:
			lock.unlock()
			return
		inside = true
		var msg := rationale if rationale != "" else code
		if not seen.has(msg):
			seen[msg] = true
			count += 1
			var f := file
			var l := line
			# a script error: where in the scripts it happened
			for bt in script_backtraces:
				if bt != null and bt.get_frame_count() > 0:
					f = bt.get_frame_file(0)
					l = bt.get_frame_line(0)
					break
			pending.append({"msg": msg.left(500), "file": f.left(200), "line": l, "fn": function.left(100)})
		inside = false
		lock.unlock()

	## The errors caught since the last call (main thread).
	func take() -> Array:
		lock.lock()
		var out := pending
		pending = []
		lock.unlock()
		return out


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args := OS.get_cmdline_user_args()
	for a in args:
		for f in DEV_FLAGS:
			if a.begins_with(f):
				on = false
	if args.has("--analytics"):
		on = true
	if not on:
		return
	session_id = Crypto.new().generate_random_bytes(12).hex_encode()
	_started = _now_s()
	_load_queue()
	_check_crash()
	_mark_running(true)
	_logger = ErrorLog.new()
	OS.add_logger(_logger)
	# a player from before 0.9.4 has no "opened_before" yet, but is onboarded
	var first := not bool(Prefs.get_v("opened_before")) and not bool(Prefs.get_v("onboarded"))
	if not bool(Prefs.get_v("opened_before")):
		Prefs.set_v("opened_before", true)
	event("app_open", {"first": first})
	Net.changed.connect(func(online: bool):
		if online:
			flush())


## Record an event. `name` like "game_end"; `props` a small dictionary.
func event(name: String, props := {}) -> void:
	if not on or not Remote.analytics_on():
		return
	var p: Dictionary = props
	if JSON.stringify(p).to_utf8_buffer().size() > PROPS_MAX:
		p = {"too_big": true}
	_queue.append({"n": name, "t": int(Time.get_unix_time_from_system() * 1000.0), "p": p})
	if _queue.size() > KEEP:
		var drop := _queue.size() - KEEP
		_queue = _queue.slice(drop)
		_sending = maxi(_sending - drop, 0)
	_dirty = true


func _process(delta: float) -> void:
	if not on:
		return
	if _logger:
		for e in _logger.take():
			event("error", {"msg": e["msg"], "file": e["file"], "line": e["line"]})
	_save_wait += delta
	if _save_wait >= 3.0:  # new events reach the disk within seconds (a crash keeps them)
		_save_wait = 0.0
		_save_queue()
	_wait += delta
	if _wait >= Remote.analytics_flush_sec():
		_wait = 0.0
		flush()


## Send what is queued (up to 50 a call, call after call). Never throws;
## when the server cannot be reached the queue stays.
func flush() -> void:
	if not on or _sending > 0 or _queue.is_empty() or not Remote.analytics_on() or not Net.online:
		return
	for _round in 20:  # at most 1000 events in one go
		var batch: Array = _queue.slice(0, PER_CALL)
		_sending = batch.size()
		var r: Dictionary = await Api.rpc_call("track", {"device": device(), "events": batch})
		var sent := _sending  # events dropped meanwhile may have shortened it
		_sending = 0
		if OS.get_cmdline_user_args().has("--netdebug"):
			print("ANALYTICS track %d events: ok=%s code=%d %s" % [batch.size(), r["ok"], int(r["code"]), String(r["message"])])
		# sent, or refused as a whole (bad payload: sending it again would fail again)
		if r["ok"] or int(r["code"]) == 3:
			_queue = _queue.slice(sent)
			_dirty = true
		else:
			break
		if _queue.is_empty():
			break
	_save_queue()


## Who sends the events.
func device() -> Dictionary:
	return {"appVersion": Remote.app_version(), "platform": OS.get_name(), "os": OS.get_version(),
			"model": OS.get_model_name(), "locale": L.code, "sessionId": session_id}


func _notification(what: int) -> void:
	if not on:
		return
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			_session_end()
			_mark_running(false)  # the system may close a background app: not a crash
			_save_queue()
			flush()
		NOTIFICATION_APPLICATION_RESUMED:
			_started = _now_s()
			_mark_running(true)
		NOTIFICATION_WM_CLOSE_REQUEST:
			_session_end()
			_save_queue()
			flush()


func _exit_tree() -> void:
	if not on:
		return
	if _started > 0.0:
		_session_end()
	_save_queue()
	_mark_running(false)
	if _logger:
		OS.remove_logger(_logger)
		_logger = null


## The time in front since the start (or the last return to the app).
func _session_end() -> void:
	if _started <= 0.0:
		return
	event("session_end", {"sec": int(_now_s() - _started)})
	_started = 0.0


func _now_s() -> float:
	return Time.get_ticks_msec() / 1000.0


# ------------------------------------------------------------------ the queue on the device

func _load_queue() -> void:
	if not FileAccess.file_exists(QUEUE_FILE):
		return
	var f := FileAccess.open(QUEUE_FILE, FileAccess.READ)
	if f == null:
		return
	var v: Variant = JSON.parse_string(f.get_as_text())
	if v is Array:
		for e in v:
			if e is Dictionary and e.has("n"):
				e["t"] = int(e.get("t", 0))  # JSON gives numbers back as floats: "t" must stay a whole number
				_queue.append(e)
		if _queue.size() > KEEP:
			_queue = _queue.slice(_queue.size() - KEEP)


func _save_queue() -> void:
	if not _dirty:
		return
	var f := FileAccess.open(QUEUE_FILE, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_queue))
	_dirty = false


# ------------------------------------------------------------------ crashes

## Present while the app runs in front; gone after a clean exit or while in
## the background.
func _mark_running(running: bool) -> void:
	if running:
		var f := FileAccess.open(MARKER, FileAccess.WRITE)
		if f:
			f.store_string(session_id)
	elif FileAccess.file_exists(MARKER):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(MARKER))


## The marker of the last launch is still there: it ended without closing.
## Send the end of its log (Godot keeps it as the newest rotated log file).
func _check_crash() -> void:
	if not FileAccess.file_exists(MARKER):
		return
	event("crash", {"log": _last_log_tail()})


## The end of the previous launch's log, cut to fit an event.
func _last_log_tail() -> String:
	var path := String(ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log"))
	var dir := path.get_base_dir()
	var stem := path.get_file().get_basename()
	var ext := path.get_extension()
	var best := ""
	var best_t := -1
	for f in DirAccess.get_files_at(dir):
		# the current log is <stem>.<ext>; the earlier ones <stem><date>.<ext>
		if f == path.get_file() or not f.begins_with(stem) or f.get_extension() != ext:
			continue
		var t := FileAccess.get_modified_time(dir.path_join(f))
		if t > best_t:
			best_t = t
			best = dir.path_join(f)
	if best == "":
		return ""
	var fa := FileAccess.open(best, FileAccess.READ)
	if fa == null:
		return ""
	var n := fa.get_length()
	fa.seek(maxi(n - CRASH_LOG_MAX, 0))
	var text := fa.get_buffer(mini(n, CRASH_LOG_MAX)).get_string_from_utf8()
	# the server takes props of at most 2048 bytes: keep the newest lines that fit
	while text != "" and JSON.stringify({"log": text}).to_utf8_buffer().size() > PROPS_MAX:
		var nl := text.find("\n", 100)
		text = text.substr(nl + 1) if nl >= 0 else text.substr(100)
	return text
