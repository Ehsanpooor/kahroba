extends Node
## Autoload "Api": talks to the game server (Nakama). A device session (made
## on first use, renewed when it runs out), the custom RPCs, and the realtime
## socket that carries matchmaking and the match itself.
##
## Every call is awaited and never throws: an RPC answers
## {ok, data, code, message}; `code` is Nakama's status code (0 when the server
## was not reached at all).

signal match_message(op: int, data: Dictionary)  ## a match op code (100..109) from the server
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
const OP_STATE := 100
const OP_TURN := 102
const OP_REJECTED := 103
const OP_ARTIFACT := 104
const OP_ABANDONED := 105
const OP_ENDED := 106
const OP_READY_STATE := 107
const OP_REMOVED := 108
const OP_STARTED := 109

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
## whenever the profile changes.
func sync_profile() -> Dictionary:
	var portrait := String(Prefs.get_v("portrait"))
	if not portrait.begins_with("A-") and portrait != "custom":
		portrait = "A-01"
	return await rpc_call("bootstrap_profile", {"displayName": Prefs.display_name(), "avatarId": portrait})


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
				"me": String(rec.get("owner_id", "")) == user_id})
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
	var err := req.request(Net.server() + path, headers, method, body)
	if err != OK:
		req.queue_free()
		return {"ok": false, "code": 0, "message": "request failed", "data": {}}
	var res: Array = await req.request_completed
	req.queue_free()
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
		var v: Variant = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
		if v is Dictionary:
			_on_message(v)


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
