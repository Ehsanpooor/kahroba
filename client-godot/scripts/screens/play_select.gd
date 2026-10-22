extends Screen
## Choose how to play: three gem panels side by side (Online sapphire,
## Computer emerald, Friends ruby). Tapping one opens a dialog with its few
## options and one start button.

const MODES := [
	{"key": "online", "style": "sapphire", "gem": "blue", "icon": "exchange"},
	{"key": "ai", "style": "emerald", "gem": "green", "icon": "knight"},
	{"key": "friends", "style": "ruby", "gem": "red", "icon": "friends"},
]
const DIFF := ["easy", "normal", "hard", "very_hard"]
const WIN := [15, 18, 21, 25, 30]


func build() -> void:
	backdrop("screen_bg", 0.35)
	title_bar(L.t("play"))
	var order := MODES.duplicate()
	if L.fa():
		order.reverse()
	for i in order.size():
		_card(order[i], Vector2(180 + i * 700, 210))
	text(L.t("turn_rules"), TS.BODY, Kit.MUTED, "serif", Rect2(0, 990, D.x, 60))
	if not Net.changed.is_connected(_on_net):
		Net.changed.connect(_on_net)
	if Net.online and not Api.socket_ready():
		Api.connect_socket()  # open the line now, so finding or joining a table starts at once
	if arg is int and not has_meta("opened"):  # test: --screen=play:1 opens a dialog
		set_meta("opened", true)
		if int(arg) == 3:  # --screen=play:3 opens the room-code keypad
			_join_dialog.call_deferred()
		else:
			_open.call_deferred(["online", "ai", "friends"][int(arg)])


func _card(m: Dictionary, pos: Vector2) -> void:
	var key: String = m["key"]
	var sz := Vector2(560, 717)
	pos += Vector2(40, 0)
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	Kit._empty_styles(b)
	put(b, pos, sz)
	var tile := Kit.tex("mode_" + {"online": "online", "ai": "computer", "friends": "friends"}[key])
	if tile:
		var r := TextureRect.new()
		r.texture = tile
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_SCALE
		r.size = b.size
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(r)
	else:
		b.add_child(Kit.panel(b.size))
	# the title and line on the tile's plain lower panel, the gem above them
	var gem := Kit.gem(m["gem"], 70.0 * u)
	gem.position = Vector2((b.size.x - gem.size.x) * 0.5, 425 * u)
	b.add_child(gem)
	var fa_shift := 14.0 if L.fa() else 0.0  # Persian letters stand taller: title up, line down
	text(L.t("mode_" + key), TS.BANNER, Kit.GOLD, "title_bold", Rect2(30, 490 - fa_shift, sz.x - 60, 90), HORIZONTAL_ALIGNMENT_CENTER, b)
	var needs_server := key in ["online", "friends"]
	if needs_server and not Net.online:
		# no server: the tile rests dark and says why
		for c in b.get_children():
			(c as CanvasItem).modulate = Color(0.42, 0.42, 0.44)
		text(L.t("no_server") if Net.checked else L.t("connecting"), TS.BODY, Color(0.95, 0.6, 0.45), "serif_bold",
				Rect2(40, 575 + fa_shift, sz.x - 80, 60), HORIZONTAL_ALIGNMENT_CENTER, b)
	else:
		text(L.t("mode_%s_sub" % key), TS.BODY, Kit.IVORY, "serif", Rect2(40, 575 + fa_shift, sz.x - 80, 60), HORIZONTAL_ALIGNMENT_CENTER, b)
	Kit.feedback(b)
	b.pressed.connect(func():
		if needs_server and not Net.online:
			_no_server()
		else:
			_open(key))


## Online and friends need the server; it is not answering.
func _no_server() -> void:
	message(L.t("no_server_t"), L.t("no_server_body"), [
		[L.t("ok"), "onyx", func(): pass],
		[L.t("retry"), "sapphire", func(): Net.check()],
	])


func _on_net(_online: bool) -> void:
	if is_inside_tree() and _dialog == null:
		_rebuild()


func _open(key: String) -> void:
	var g: Dictionary = Prefs.game.duplicate()
	var choice := {"players": clampi(int(g.get("players", 4)), 2, 4),
			"difficulty": maxi(DIFF.find(String(g.get("difficulty", "normal"))), 0),
			"win": maxi(WIN.find(int(g.get("win_points", 15))), 0)}
	var h: float = {"ai": 880.0, "friends": 760.0, "online": 580.0}[key]
	var box := dialog(Vector2(1300, h), L.t("mode_" + key))
	var w := dialog_w(box)
	var yy := [0.0]  # shared with the lambda (lambdas copy plain locals)
	var chip := Vector2(250, 96)
	var row := func(title: String, options: Array, sel: int, on_pick: Callable) -> void:
		dialog_text(box, title, TS.LABEL, Kit.MUTED, "serif_bold", Rect2(0, yy[0], w, 56))
		var c := chip if options.size() <= 3 else (Vector2(230, 96) if options.size() == 4 else Vector2(200, 96))
		var t := Kit.tabs(options, sel, c * u, 20.0 * u, on_pick)
		in_dialog(box, t, Vector2((w - t.size.x / u) * 0.5, yy[0] + 64))
		yy[0] += 176.0
	if key == "ai":
		row.call(L.t("opponents"), ["1", "2", "3"], choice["players"] - 2, func(i: int): choice["players"] = i + 2)
		row.call(L.t("difficulty"), [L.t("easy"), L.t("normal"), L.t("hard"), L.t("very_hard")], choice["difficulty"],
				func(i: int): choice["difficulty"] = i)
		row.call(L.t("play_to"), WIN.map(func(v): return str(v)), choice["win"], func(i: int): choice["win"] = i)
		dialog_text(box, L.t("not_rated_first"), TS.BODY, Kit.MUTED, "serif", Rect2(0, yy[0] - 10, w, 50))
	elif key == "online":
		row.call(L.t("players_n"), ["2", "3", "4"], choice["players"] - 2, func(i: int): choice["players"] = i + 2)
		dialog_text(box, L.t("rated_rules"), TS.BODY, Kit.MUTED, "serif", Rect2(0, yy[0] - 10, w, 50))
	else:
		# a friends' room seats up to 6 (the Iranian edition's board)
		var room_n := clampi(int(g.get("room_players", choice["players"])), 2, 6)
		choice["players"] = room_n
		row.call(L.t("players_n"), ["2", "3", "4", "5", "6"], room_n - 2, func(i: int): choice["players"] = i + 2)
		row.call(L.t("play_to"), WIN.map(func(v): return str(v)), choice["win"], func(i: int): choice["win"] = i)
		dialog_text(box, L.t("room_hint"), TS.BODY, Kit.MUTED, "serif", Rect2(0, yy[0] - 10, w, 50))
		# two ways in: open a room, or join a friend's with its code
		var mk := Kit.button(L.t("room_create"), Vector2(480, 130) * u, "emerald", "", 44.0 * u)
		var jn := Kit.button(L.t("room_join"), Vector2(480, 130) * u, "sapphire", "", 44.0 * u)
		var bx := (box.size.x / u - 480.0 * 2 - 50.0) * 0.5
		mk.position = Vector2(bx + (530.0 if L.fa() else 0.0), box.size.y / u - 170.0) * u
		jn.position = Vector2(bx + (0.0 if L.fa() else 530.0), box.size.y / u - 170.0) * u
		box.add_child(mk)
		box.add_child(jn)
		mk.pressed.connect(func():
			close_dialog()
			if _guard_net():
				_create_room(int(choice["players"]), WIN[int(choice["win"])]))
		jn.pressed.connect(func():
			close_dialog()
			if _guard_net():
				_join_dialog())
		return
	var label: String = {"online": L.t("find_match"), "ai": L.t("start")}[key]
	var go_b := Kit.button(label, Vector2(560, 130) * u, "emerald")
	go_b.position = Vector2((box.size.x - go_b.size.x) * 0.5, box.size.y - go_b.size.y - 40 * u)
	box.add_child(go_b)
	go_b.pressed.connect(func():
		close_dialog()
		var game := {"mode": key, "players": int(choice["players"]), "difficulty": DIFF[int(choice["difficulty"])],
				"win_points": 18 if key == "online" else WIN[int(choice["win"])]}
		if key == "online":
			if _guard_net():
				_search(int(choice["players"]))
			return
		var start := func():
			SavedGame.clear()
			Prefs.game = game
			play.emit(game)
		if SavedGame.exists():  # a new game replaces the unfinished one: say so first
			message(L.t("new_game"), L.t("new_over_saved"), [
				[L.t("cancel"), "onyx", func(): pass],
				[L.t("new_game"), "emerald", start],
			])
		else:
			start.call())


# ------------------------------------------------------------------ online: finding a table, rooms with a code

## Online needs the server.
func _guard_net() -> bool:
	if not Net.online:
		_no_server()
		return false
	return true


## A dialog that says what is happening, with a turning gem and Cancel.
## Returns the line inside it (to update).
func _busy_dialog(title: String, line: String, on_cancel: Callable) -> Label:
	var box := dialog(Vector2(1100, 560), title, false)
	var w := dialog_w(box)
	var gem := Kit.gem("blue", 110.0 * u)
	gem.pivot_offset = gem.size * 0.5
	in_dialog(box, gem, Vector2((w - 110.0) * 0.5, 20))
	var spin := gem.create_tween().set_loops()
	spin.tween_property(gem, "rotation", TAU, 1.6).from(0.0)
	var l := dialog_text(box, line, TS.LABEL, Kit.IVORY, "serif", Rect2(0, 160, w, 110))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var cancel := Kit.button(L.t("cancel"), Vector2(360, 116) * u, "onyx", "", 40.0 * u)
	cancel.position = Vector2((box.size.x - cancel.size.x) * 0.5, box.size.y - cancel.size.y - 40 * u)
	box.add_child(cancel)
	cancel.pressed.connect(func():
		close_dialog()
		on_cancel.call())
	return l


func _fail(msg: String) -> void:
	message(L.t("no_server_t") if msg == "" else L.t("oops"), msg if msg != "" else L.t("no_server_body"),
			[[L.t("ok"), "onyx", func(): pass]])


## Sit at the match and open the board.
func _enter(match_key: String, mm_token: String, game: Dictionary) -> void:
	var why := await Api.join_match(match_key, mm_token)
	if why != "":
		push_warning("join refused: " + why)
		close_dialog()
		_fail(L.t("join_failed"))
		return
	close_dialog()
	SavedGame.clear()
	game["net"] = true
	game["match_id"] = Api.match_id
	Prefs.game = game
	play.emit(game)


## Online: the server seats you at a table of this size (one that is filling,
## or a new one); the board's waiting room then shows players arriving.
func _search(players: int) -> void:
	var cancelled := [false]
	var t0 := Time.get_unix_time_from_system()
	Analytics.event("search_start", {"players": players, "sec": 0})
	_busy_dialog(L.t("mode_online"), L.t("searching"), func():
		cancelled[0] = true
		Analytics.event("search_cancel", {"players": players, "sec": int(Time.get_unix_time_from_system() - t0)}))
	await Api.sync_profile()
	var r := await Api.rpc_call("start_public_search", {"playerCount": players})
	if cancelled[0]:
		return
	if not r["ok"]:
		close_dialog()
		if int(r["code"]) == 9:
			_busy_elsewhere()
		else:
			_fail("")
		return
	var table := String(r["data"].get("matchId", r["data"].get("refillMatchId", "")))
	if table == "":
		close_dialog()
		_fail("")
		return
	await _enter(table, "", {"mode": "online", "players": players, "win_points": 18, "search_started": t0})


## You are already at a table (a room you opened, a table you were waiting
## at, or a game in progress): say which, and offer the way back or out.
func _busy_elsewhere() -> void:
	var r := await Api.rpc_call("get_active_game", {})
	var d: Dictionary = r["data"] if r["ok"] else {}
	var id := String(d.get("matchId", "")) if d.get("matchId") != null else ""
	if id == "":
		_fail(L.t("join_failed"))  # the lock was stale and is gone now: try again
		return
	var mode := String(d.get("mode", ""))
	var phase := String(d.get("phase", ""))
	var count := int(d.get("playerCount", 2))
	var code := String(d.get("code", ""))
	var started := phase in ["playing", "finalRound"]
	var body: String
	if started:
		body = L.t("busy_game")
	elif mode == "private":
		body = L.t("busy_room", code.substr(0, 3) + " " + code.substr(3), count)
	else:
		body = L.t("busy_table", count)
	var back := func():
		var why := await Api.join_match(id)
		if why != "":
			_fail(L.t("game_gone"))
			return
		var game := {"mode": "friends" if mode == "private" else "online", "players": count, "net": true,
				"match_id": Api.match_id, "code": code, "search_started": Time.get_unix_time_from_system()}
		if started:
			game["resume"] = false
		Prefs.game = game
		play.emit(game)
	var close := func():
		await Api.rpc_call("concede_match", {"matchId": id})
		SavedGame.clear()
		message(L.t("mode_" + ("friends" if mode == "private" else "online")),
				L.t("room_closed_ok") if mode == "private" else L.t("left_ok"), [[L.t("ok"), "onyx", func(): pass]])
	message(L.t("busy_title"), body, [
		[L.t("room_close") if mode == "private" and not started else L.t("leave"), "ruby", close],
		[L.t("busy_back"), "emerald", back],
	])


## A private room: the server opens it and gives a code to share.
func _create_room(players: int, win: int) -> void:
	Prefs.game["room_players"] = players  # the next room starts from this size
	var cancelled := [false]
	_busy_dialog(L.t("mode_friends"), L.t("room_opening"), func(): cancelled[0] = true)
	await Api.sync_profile()
	var r := await Api.rpc_call("create_private_match", {"playerCount": players, "winThreshold": win})
	if cancelled[0]:
		return
	if not r["ok"]:
		close_dialog()
		if int(r["code"]) == 9:
			_busy_elsewhere()
		else:
			_fail("")
		return
	Analytics.event("room_create", {"players": players})
	await _enter(String(r["data"].get("matchId", "")), "", {"mode": "friends", "players": players, "win_points": win,
			"code": String(r["data"].get("code", ""))})


## Join a friend's room: its six-digit code on the keypad.
func _join_dialog() -> void:
	var box := dialog(Vector2(1640, 760), L.t("room_join"))
	var w := dialog_w(box)
	var left_w := 820.0
	var lx := 0.0 if not L.fa() else w - left_w
	var kx := left_w + 40.0 if not L.fa() else 0.0
	dialog_text(box, L.t("room_code_ask"), TS.LABEL, Kit.IVORY, "serif", Rect2(lx, 0, left_w, 70))
	var go_b := Kit.button(L.t("join"), Vector2(460, 130) * u, "emerald", "", 46.0 * u)
	in_dialog(box, go_b, Vector2(lx + (left_w - 460) * 0.5, 330))
	var note := dialog_text(box, "", TS.BODY, Color(0.95, 0.66, 0.45), "serif", Rect2(lx, 260, left_w, 50))
	var join := func(code: String):
		if code.length() != 6:
			return
		close_dialog()
		_busy_dialog(L.t("room_join"), L.t("room_joining"), func(): pass)
		await Api.sync_profile()
		var r := await Api.rpc_call("join_by_code", {"code": code})
		if not r["ok"]:
			close_dialog()
			if int(r["code"]) == 9:
				_busy_elsewhere()
				return
			_fail(L.t("room_not_found") if int(r["code"]) in [3, 5] else "")
			return
		await _enter(String(r["data"].get("matchId", "")), "", {"mode": "friends", "players": 0, "code": code,
				"joined_room": true})  # the board sends room_join once it knows the room's size
	var pad := pin_pad(box, Rect2(lx + (left_w - 700) * 0.5, 105, 700, 130), kx, w - left_w - 40.0,
			func(code: String, msg: String):
				note.text = msg
				Kit.set_enabled(go_b, code.length() == 6),
			join)
	Kit.set_enabled(go_b, String(pad["code"]).length() == 6)
	go_b.pressed.connect(func(): join.call(pad["code"]))
