extends Node
## Autoload "Api": talks to the game server (Nakama). A device session (made
## on first use, renewed when it runs out), the custom RPCs, and the realtime
## socket that carries matchmaking and the match itself.
##
## Every call is awaited and never throws: an RPC answers
## {ok, data, code, message}; `code` is Nakama's status code (0 when the server
## was not reached at all).

signal match_message(op: int, data: Dictionary)  ## a match op code (100..112) from the server
signal matched(info: Dictionary)  ## the matchmaker found a table: {match_id, token}
signal notification(code: int, content: Dictionary)
signal socket_closed

## The key every client sends with its first sign-in. Change it on the
## server (NAKAMA_SERVER_KEY) and here together.
const SERVER_KEY := "splendor-tester-2026"

## Server match op codes (API_DOC §6).
const OP_HARVEST := 1
const OP_CHANNEL := 2
const OP_HIRE := 3
const OP_JAIL := 4
const OP_CONCEDE := 6
const OP_SYNC := 7
const OP_READY := 8
const OP_AD_DONE := 9  ## this device's ad break is over (payload {})
const OP_PAUSE := 10  ## {on}: ask for the pause of a friends' game (or take it back)
const OP_RESUME := 11  ## {on}: ready to go on (while paused)
const OP_SKIP := 12  ## pass this turn
const OP_STATE := 100
const OP_TURN := 102
const OP_REJECTED := 103
const OP_ARTIFACT := 104
const OP_ABANDONED := 105
const OP_ENDED := 106
const OP_READY_STATE := 107
const OP_REMOVED := 108
const OP_STARTED := 109
const OP_AD_BREAK := 110  ## everyone is ready: show an ad, then send OP_AD_DONE ({deadlineMs})
const OP_TABLE_STATUS := 111  ## every seat's flags (offline, pause votes) and the pause
const OP_TURN_SKIPPED := 112  ## {playerIndex}: the player on turn passed it

## Server elements as the game's gem colours, and back.
const TO_GEM := {"light": "white", "water": "blue", "nature": "green", "fire": "red", "shadow": "black", "aether": "gold"}
const TO_ELEMENT := {"white": "light", "blue": "water", "green": "nature", "red": "fire", "black": "shadow", "gold": "aether"}

var token := ""
var user_id := ""
var match_id := ""  ## the match this device is seated in (socket joined)
var _token_exp := 0
var _ws: WebSocketPeer
var _ws_open := false
var _cid := 0
var _waiting := {}  ## cid -> the reply, once it arrives
var _authing := false
var _synced_profile := ""  ## the profile the server last accepted this session
## The heartbeat. A socket whose network went away (Wi-Fi to mobile data, a
## tunnel, the phone asleep) often never reports itself closed: it just goes
## quiet. The app pings the server every few seconds; when nothing at all has
## come back for a while the socket is treated as closed, so the game's
## reconnect starts at once instead of waiting on a dead line.
const PING_EVERY := 5.0
const DEAD_AFTER := 20.0  # a slow phone line can hold a few pongs back; this is silence
const ALIVE_WITHIN := 12.0  # a socket that brought something this recently works
var _last_rx := 0.0  ## when the socket last brought anything (seconds)
var _last_ping := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


# ------------------------------------------------------------------ session

## A valid session, signing in with this device if needed. False if the
## server could not be reached.
func ensure_session() -> bool:
	if token != "" and Time.get_unix_time_from_system() < _token_exp - 60:
		return true
	while _authing:
		await get_tree().process_frame
	if token != "" and Time.get_unix_time_from_system() < _token_exp - 60:
		return true
	_authing = true
	var auth := "Basic " + Marshalls.utf8_to_base64(SERVER_KEY + ":")
	var r := await _http("/v2/account/authenticate/device?create=true", HTTPClient.METHOD_POST,
			JSON.stringify({"id": _device_id()}), auth)
	_authing = false
	if not r["ok"]:
		return false
	token = String(r["data"].get("token", ""))
	_read_token(token)
	return token != ""


func _device_id() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--device="):  # test: play as another device
			return "splendor-test-" + a.get_slice("=", 1)
	var id := String(Prefs.get_v("device_id"))
	if id.length() < 10:
		var b := Crypto.new().generate_random_bytes(16)
		id = "splendor-" + b.hex_encode()
		Prefs.set_v("device_id", id)
	return id


## The user id and expiry from the session token (a JWT).
func _read_token(t: String) -> void:
	var parts := t.split(".")
	if parts.size() < 2:
		return
	var p := parts[1].replace("-", "+").replace("_", "/")
	while p.length() % 4 != 0:
		p += "="
	var claims: Variant = JSON.parse_string(Marshalls.base64_to_utf8(p))
	if claims is Dictionary:
		user_id = String(claims.get("uid", ""))
		_token_exp = int(claims.get("exp", 0))


## Tell the server who you are (name and portrait). Called after sign-in and
## whenever the profile changes; a profile the server already has this session
## is not sent again (every request costs a round trip on a slow phone line).
func sync_profile() -> Dictionary:
	var portrait := String(Prefs.get_v("portrait"))
	if not portrait.begins_with("A-") and portrait != "custom":
		portrait = "A-01"
	var name := Prefs.display_name()
	for a in OS.get_cmdline_user_args():  # test: play as someone else (store screenshots)
		if a.begins_with("--name="):
			name = a.get_slice("=", 1)
		elif a.begins_with("--portrait="):
			portrait = a.get_slice("=", 1)
	var sent := "%s|%s|%s" % [user_id, name, portrait]
	if sent == _synced_profile and token != "":
		return {"ok": true, "code": 0, "message": "", "data": {}}
	var r := await rpc_call("bootstrap_profile", {"displayName": name, "avatarId": portrait})
	if r["ok"]:
		_synced_profile = sent
	return r


# ------------------------------------------------------------------ recovery email

## This account's recovery email ("" for none) and whether the server can send
## email: {email, available}. {} when the server was not reached.
func email_status() -> Dictionary:
	var r := await rpc_call("email_status", {})
	if not r["ok"]:
		return {}
	var e := String(r["data"].get("email", ""))
	if e != "":
		Prefs.set_v("email", e)
	return r["data"]


## Email a six-digit code: purpose "link" (add the email to this account) or
## "recover" (bring that email's account to this device).
func email_send_code(email: String, purpose: String) -> Dictionary:
	return await rpc_call("email_send_code", {"email": email, "purpose": purpose, "lang": L.code})


## Check the code. "link": the email is saved. "recover": this device signs in
## as that account from now on, and takes its name, portrait and rating.
func email_verify(email: String, code: String, purpose: String) -> Dictionary:
	var r := await rpc_call("email_verify", {"email": email, "code": code, "purpose": purpose})
	if not r["ok"]:
		return r
	var d: Dictionary = r["data"]
	Prefs.set_v("email", String(d.get("email", email)))
	if purpose == "recover":
		close_socket()
		token = ""
		user_id = ""
		_token_exp = 0
		await ensure_session()
		if String(d.get("displayName", "")) != "":
			Prefs.set_v("name", String(d["displayName"]))
		var av := String(d.get("avatarId", ""))
		Prefs.set_v("portrait", av if av.begins_with("A-") else "A-01")  # an own photo stays on the old phone
		Prefs.set_v("rating", int(d.get("rating", 1000)))
		Prefs.set_v("email_nag_at", int(d.get("rating", 1000)))
	return r


# ------------------------------------------------------------------ RPCs

func rpc_call(id: String, payload: Dictionary = {}) -> Dictionary:
	if not await ensure_session():
		return {"ok": false, "code": 0, "message": "no connection", "data": {}}
	var r := await _http("/v2/rpc/" + id, HTTPClient.METHOD_POST, JSON.stringify(JSON.stringify(payload)),
			"Bearer " + token)
	if not r["ok"] and int(r["code"]) == 16:  # the session ran out: sign in again once
		token = ""
		if await ensure_session():
			r = await _http("/v2/rpc/" + id, HTTPClient.METHOD_POST, JSON.stringify(JSON.stringify(payload)),
					"Bearer " + token)
	if r["ok"]:
		var inner: Variant = JSON.parse_string(String(r["data"].get("payload", "{}")))
		r["data"] = inner if inner is Dictionary else {}
	return r


## The top of the rating board: [{name, portrait, rating, rank, me}].
func leaderboard(limit := 50) -> Array:
	if not await ensure_session():
		return []
	var r := await _http("/v2/leaderboard/splendor_elo?limit=%d" % limit, HTTPClient.METHOD_GET, "", "Bearer " + token)
	if not r["ok"]:
		return []
	var out := []
	for rec in r["data"].get("records", []):
		var meta: Variant = JSON.parse_string(String(rec.get("metadata", "{}")))
		out.append({"name": String(rec.get("username", "")), "rating": int(rec.get("score", 0)),
				"rank": int(rec.get("rank", 0)), "portrait": String((meta as Dictionary).get("avatarId", "A-01")) if meta is Dictionary else "A-01",
				"me": String(rec.get("owner_id", "")) == user_id, "owner": String(rec.get("owner_id", "")), "wins": -1})
	# the wins column: every listed player's public rating profile, in one read
	if not out.is_empty():
		var ids := []
		for o in out:
			ids.append({"collection": "rating", "key": "profile", "user_id": o["owner"]})
		var pr := await _http("/v2/storage", HTTPClient.METHOD_POST, JSON.stringify({"object_ids": ids}), "Bearer " + token)
		if pr["ok"]:
			var wins := {}
			for obj in pr["data"].get("objects", []):
				var v: Variant = JSON.parse_string(String(obj.get("value", "{}")))
				if v is Dictionary:
					wins[String(obj.get("user_id", ""))] = int((v as Dictionary).get("wins", 0))
			for o in out:
				o["wins"] = int(wins.get(o["owner"], -1))
	return out


## Your rating profile {rating, gamesPlayed, provisional, wins, losses}, or {}.
func my_rating() -> Dictionary:
	if not await ensure_session():
		return {}
	var body := JSON.stringify({"object_ids": [{"collection": "rating", "key": "profile", "user_id": user_id}]})
	var r := await _http("/v2/storage", HTTPClient.METHOD_POST, body, "Bearer " + token)
	if not r["ok"]:
		return {}
	for o in r["data"].get("objects", []):
		var v: Variant = JSON.parse_string(String(o.get("value", "{}")))
		if v is Dictionary:
			return v
	return {}


func _http(path: String, method: int, body: String, auth: String) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 8.0
	add_child(req)
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	if auth != "":
		headers.append("Authorization: " + auth)
	var t0 := Time.get_ticks_msec()
	var err := req.request(Net.server() + path, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"ok": false, "code": 0, "message": "request failed", "data": {}}
	var res: Array = await req.request_completed
	req.queue_free()
	if OS.get_cmdline_user_args().has("--netdebug"):
		print("HTTP %s %d ms (result %d, status %d)" % [path.get_slice("?", 0), Time.get_ticks_msec() - t0, res[0], res[1]])
	var status := int(res[1])
	var text := (res[3] as PackedByteArray).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text) if text != "" else {}
	var data: Dictionary = parsed if parsed is Dictionary else {}
	if int(res[0]) != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": 0, "message": "no connection", "data": {}}
	if status < 200 or status >= 300:
		return {"ok": false, "code": int(data.get("code", 0)), "message": String(data.get("message", "error %d" % status)),
				"data": data}
	return {"ok": true, "code": 0, "message": "", "data": data}


# ------------------------------------------------------------------ the socket

func socket_ready() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


## The socket is open and the server answered it lately (pings go every 5 s):
## the game is connected, whatever a separate check of the line says.
func socket_alive() -> bool:
	return socket_ready() and _ws_open and _now() - _last_rx < ALIVE_WITHIN


## Seconds since the socket last brought anything (diagnostics).
func socket_quiet_for() -> float:
	return _now() - _last_rx


## Open the realtime socket (once signed in).
func connect_socket() -> bool:
	if socket_ready():
		return true
	if not await ensure_session():
		return false
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1 << 20
	var url := Net.server().replace("http://", "ws://").replace("https://", "wss://")
	if _ws.connect_to_url("%s/ws?lang=en&status=true&token=%s" % [url, token]) != OK:
		return false
	var t := 0.0
	while _ws.get_ready_state() == WebSocketPeer.STATE_CONNECTING and t < 8.0:
		await get_tree().process_frame
		t += get_process_delta_time()
	_ws_open = socket_ready()
	_last_rx = _now()
	_last_ping = _last_rx
	return _ws_open


func close_socket() -> void:
	if _ws:
		_ws.close()
	_ws_open = false
	match_id = ""


## Send a socket request and wait for its answer: the reply envelope (one of
## "match", "matchmaker_ticket", "error", ...), or {} on timeout.
func _request(msg: Dictionary, timeout := 10.0) -> Dictionary:
	if not socket_ready() and not await connect_socket():
		return {"error": {"message": "no connection"}}
	_cid += 1
	var cid := str(_cid)
	msg["cid"] = cid
	_waiting[cid] = null
	_ws.send_text(JSON.stringify(msg))
	var t := 0.0
	while _waiting[cid] == null and t < timeout:
		await get_tree().process_frame
		t += get_process_delta_time()
	var reply: Variant = _waiting[cid]
	_waiting.erase(cid)
	return reply if reply is Dictionary else {"error": {"message": "timeout"}}


## Sit at a match, by id (private, rejoin) or by matchmaker token.
## Returns "" when seated, or the reason it was refused.
func join_match(id: String, mm_token := "") -> String:
	var body := {"token": mm_token} if mm_token != "" else {"match_id": id}
	var r := await _request({"match_join": body})
	if r.has("match"):
		match_id = String(r["match"].get("match_id", id))
		return ""
	return String(r.get("error", {}).get("message", "failed"))


func leave_match() -> void:
	if match_id != "" and socket_ready():
		_ws.send_text(JSON.stringify({"match_leave": {"match_id": match_id}}))
	match_id = ""


func send_op(op: int, data: Dictionary = {}) -> void:
	if match_id == "" or not socket_ready():
		return
	_ws.send_text(JSON.stringify({"match_data_send": {"match_id": match_id, "op_code": str(op),
			"data": Marshalls.utf8_to_base64(JSON.stringify(data))}}))


## Join the matchmaker; returns the ticket ("" on failure).
func matchmaker_add(params: Dictionary) -> String:
	var r := await _request({"matchmaker_add": {
		"min_count": int(params.get("minCount", 2)), "max_count": int(params.get("maxCount", 2)),
		"query": String(params.get("query", "*")),
		"string_properties": params.get("stringProperties", {}),
		"numeric_properties": params.get("numericProperties", {}),
	}})
	return String(r.get("matchmaker_ticket", {}).get("ticket", ""))


func matchmaker_remove(ticket: String) -> void:
	if ticket != "" and socket_ready():
		await _request({"matchmaker_remove": {"ticket": ticket}}, 4.0)


func _process(_delta: float) -> void:
	if _ws == null:
		return
	_ws.poll()
	var st := _ws.get_ready_state()
	if st == WebSocketPeer.STATE_CLOSED:
		if _ws_open:
			_ws_open = false
			socket_closed.emit()
		return
	while _ws.get_available_packet_count() > 0:
		_last_rx = _now()
		var v: Variant = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
		if v is Dictionary:
			_on_message(v)
	if st != WebSocketPeer.STATE_OPEN or not _ws_open:
		return
	var now := _now()
	if now - _last_rx > DEAD_AFTER:
		_drop_socket()
	elif now - _last_ping >= PING_EVERY:
		_last_ping = now
		_ws.send_text("{\"ping\":{}}")  # the server answers {"pong":{}}


## The socket went quiet: close it and say so, as if the server had closed it.
func _drop_socket() -> void:
	push_warning("socket silent for %.0f s: reconnecting" % (_now() - _last_rx))
	Analytics.event("net_drop", {"quiet": int(_now() - _last_rx)})
	_ws.close()
	_ws = null
	if _ws_open:
		_ws_open = false
		socket_closed.emit()


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## Back in the app (after the phone slept, or the network changed meanwhile):
## a socket that does not answer a ping within 5 s is treated as closed.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if _ws and _ws_open and socket_ready():
			_last_rx = minf(_last_rx, _now() - DEAD_AFTER + 5.0)
			_last_ping = _now()
			_ws.send_text("{\"ping\":{}}")


func _on_message(m: Dictionary) -> void:
	if m.has("cid") and _waiting.has(String(m["cid"])):
		_waiting[String(m["cid"])] = m
		return
	if m.has("match_data"):
		var md: Dictionary = m["match_data"]
		var raw := String(md.get("data", ""))
		var parsed: Variant = JSON.parse_string(Marshalls.base64_to_utf8(raw)) if raw != "" else {}
		match_message.emit(int(md.get("op_code", 0)), parsed if parsed is Dictionary else {})
	elif m.has("matchmaker_matched"):
		var mm: Dictionary = m["matchmaker_matched"]
		matched.emit({"match_id": String(mm.get("match_id", "")), "token": String(mm.get("token", ""))})
	elif m.has("notifications"):
		for n in m["notifications"].get("notifications", []):
			var c: Variant = JSON.parse_string(String(n.get("content", "{}")))
			notification.emit(int(n.get("code", 0)), c if c is Dictionary else {})


# ------------------------------------------------------------------ helpers

## A server cost/coin map {"light": 2, ...} as gem colours {"white": 2, ...}.
static func gems(m: Variant) -> Dictionary:
	var out := {}
	if m is Dictionary:
		for k in m:
			out[TO_GEM.get(String(k), String(k))] = int(m[k])
	return out


## A server card as the board's card dictionary.
static func card(c: Dictionary) -> Dictionary:
	var id := String(c.get("id", c.get("cardId", "")))
	if GameData.CARDS.has(id):
		return (GameData.CARDS[id] as Dictionary).duplicate(true)
	var costs := []
	var hc := gems(c.get("hireCost", {}))
	for col in Gems.COLORS:
		if int(hc.get(col, 0)) > 0:
			costs.append([col, int(hc[col])])
	return {"id": id, "tier": int(c.get("tier", 1)), "points": int(c.get("power", 0)),
			"element": TO_GEM.get(String(c.get("affinity", "light")), "white"), "costs": costs}
