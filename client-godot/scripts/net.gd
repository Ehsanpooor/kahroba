extends Node
## The connection to the game server. Asks the server's health check every
## few seconds and says whether online play is possible: `online` is true only
## while the server answers. Online and friends games need it; games against
## the computer never do.
##
## The address comes from `--server=<url>` or Prefs "server". Test flags:
## `--net=on` / `--net=off` fix the answer without asking anyone.

signal changed(online: bool)

const DEFAULT_SERVER := "https://splendor.aizood.ir"
const TIMEOUT := 4.0
const EVERY := 15.0  # seconds between checks while all is well
const EVERY_IN_GAME := 4.0  # during an online game, and while the line is down

var online := false
var checked := false  # at least one answer (or silence) came back
var in_game := false  # an online game is running: check more often
var _forced := ""
var _http: HTTPRequest
var _busy := false
var _busy_for := 0.0  ## how long the current check has been out
var _wait := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--net="):
			_forced = a.get_slice("=", 1)
	if _forced != "":
		online = _forced == "on"
		checked = true
		return
	_http = HTTPRequest.new()
	_http.timeout = TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_done)
	check()


func server() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--server="):
			return a.get_slice("=", 1).trim_suffix("/")
	var s := String(Prefs.get_v("server"))
	return (s if s != "" else DEFAULT_SERVER).trim_suffix("/")


## Ask now (a Retry button, coming back to the app).
func check() -> void:
	if _forced != "" or _busy:
		return
	_busy = true
	_busy_for = 0.0
	_wait = 0.0
	if _http.request(server() + "/healthcheck") != OK:
		_busy = false
		_set_online(false)
		IP.clear_cache()


func _on_done(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_busy = false
	var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	if not ok:
		IP.clear_cache()  # after a network change, look the server up afresh
	_set_online(ok)


func _set_online(v: bool) -> void:
	checked = true
	if v == online:
		return
	online = v
	changed.emit(v)


func _process(delta: float) -> void:
	if _forced != "":
		return
	if _busy:
		# a check that never came back (it can happen as the network changes):
		# give up on it and ask again
		_busy_for += delta
		if _busy_for > TIMEOUT + 3.0:
			_http.cancel_request()
			_busy = false
			IP.clear_cache()
			_set_online(false)
		return
	_wait += delta
	if _wait >= (EVERY_IN_GAME if in_game or not online else EVERY):
		check()


func _notification(what: int) -> void:
	if (what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_APPLICATION_RESUMED) 			and _forced == "" and _http:
		check()  # back in the app: the network may have changed meanwhile


## Test: switch the line off or on while running.
func force(state: String) -> void:
	_forced = state
	if state != "":
		_set_online(state == "on")
