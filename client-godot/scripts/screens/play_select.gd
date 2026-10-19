extends Screen
## Choose how to play: three gem panels side by side (Online sapphire,
## Computer emerald, Friends ruby). Tapping one opens a dialog with its few
## options and one start button.

const MODES := [
	{"key": "online", "style": "sapphire", "gem": "blue", "icon": "exchange"},
	{"key": "ai", "style": "emerald", "gem": "green", "icon": "knight"},
	{"key": "friends", "style": "ruby", "gem": "red", "icon": "friends"},
]
const DIFF := ["easy", "normal", "hard"]
const WIN := [15, 18, 21]


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
	if arg is int and not has_meta("opened"):  # test: --screen=play:1 opens a dialog
		set_meta("opened", true)
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
		var t := Kit.tabs(options, sel, chip * u, 24.0 * u, on_pick)
		in_dialog(box, t, Vector2((w - t.size.x / u) * 0.5, yy[0] + 64))
		yy[0] += 176.0
	if key == "ai":
		row.call(L.t("opponents"), ["1", "2", "3"], choice["players"] - 2, func(i: int): choice["players"] = i + 2)
		row.call(L.t("difficulty"), [L.t("easy"), L.t("normal"), L.t("hard")], choice["difficulty"],
				func(i: int): choice["difficulty"] = i)
		row.call(L.t("play_to"), WIN.map(func(v): return str(v)), choice["win"], func(i: int): choice["win"] = i)
		dialog_text(box, L.t("not_rated_first"), TS.BODY, Kit.MUTED, "serif", Rect2(0, yy[0] - 10, w, 50))
	elif key == "online":
		row.call(L.t("players_n"), ["2", "3", "4"], choice["players"] - 2, func(i: int): choice["players"] = i + 2)
		dialog_text(box, L.t("rated_rules"), TS.BODY, Kit.MUTED, "serif", Rect2(0, yy[0] - 10, w, 50))
	else:
		row.call(L.t("players_n"), ["2", "3", "4"], choice["players"] - 2, func(i: int): choice["players"] = i + 2)
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
				"win_points": 15 if key == "online" else WIN[int(choice["win"])]}
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


## Public search: the server's matchmaker, a minute at most; a seat freed in a
## ready check at another table is taken if the server offers one.
func _search(players: int) -> void:
	var cancelled := [false]
	var ticket := [""]
	var line := _busy_dialog(L.t("mode_online"), L.t("searching"), func():
		cancelled[0] = true
		Api.matchmaker_remove(ticket[0]))
	await Api.sync_profile()
	var r := await Api.rpc_call("start_public_search", {"playerCount": players})
	if cancelled[0]:
		return
	if not r["ok"]:
		close_dialog()
		_fail(L.t("in_a_game") if int(r["code"]) == 9 else "")
		return
	var game := {"mode": "online", "players": players, "win_points": 15}
	if String(r["data"].get("refillMatchId", "")) != "":
		await _enter(String(r["data"]["refillMatchId"]), "", game)
		return
	if not await Api.connect_socket():
		close_dialog()
		_fail("")
		return
	var found := [{}]
	var on_match := func(info: Dictionary): found[0] = info
	Api.matched.connect(on_match)
	ticket[0] = await Api.matchmaker_add(r["data"])
	var limit := float(r["data"].get("timeoutSeconds", 60))
	var t := 0.0
	var poll := 0.0
	while found[0].is_empty() and not cancelled[0] and t < limit:
		await get_tree().process_frame
		var dt := get_process_delta_time()
		t += dt
		poll += dt
		if is_instance_valid(line):
			line.text = "%s  %d:%02d" % [L.t("searching"), int(t) / 60, int(t) % 60]
		if poll >= 5.0:  # a seat opened at another table?
			poll = 0.0
			var again := await Api.rpc_call("start_public_search", {"playerCount": players})
			if again["ok"] and String(again["data"].get("refillMatchId", "")) != "" and found[0].is_empty():
				await Api.matchmaker_remove(ticket[0])
				Api.matched.disconnect(on_match)
				await _enter(String(again["data"]["refillMatchId"]), "", game)
				return
	Api.matched.disconnect(on_match)
	if cancelled[0]:
		return
	if found[0].is_empty():
		await Api.matchmaker_remove(ticket[0])
		close_dialog()
		message(L.t("mode_online"), L.t("nobody_found"), [
			[L.t("cancel"), "onyx", func(): pass],
			[L.t("retry"), "sapphire", func(): _search(players)],
		])
		return
	var info: Dictionary = found[0]
	await _enter(String(info.get("match_id", "")), String(info.get("token", "")), game)


## A private room: the server opens it and gives a code to share.
func _create_room(players: int, win: int) -> void:
	var cancelled := [false]
	_busy_dialog(L.t("mode_friends"), L.t("room_opening"), func(): cancelled[0] = true)
	await Api.sync_profile()
	var r := await Api.rpc_call("create_private_match", {"playerCount": players, "winThreshold": win})
	if cancelled[0]:
		return
	if not r["ok"]:
		close_dialog()
		_fail(L.t("in_a_game") if int(r["code"]) == 9 else "")
		return
	await _enter(String(r["data"].get("matchId", "")), "", {"mode": "friends", "players": players, "win_points": win,
			"code": String(r["data"].get("code", ""))})


## Type a friend's room code (Persian digits are turned into English ones).
func _join_dialog() -> void:
	var box := dialog(Vector2(1100, 640), L.t("room_join"))
	var w := dialog_w(box)
	dialog_text(box, L.t("room_code_ask"), TS.LABEL, Kit.IVORY, "serif", Rect2(0, 0, w, 70))
	var fw := 640.0
	var field := Kit.tex("input_field")
	if field:
		in_dialog(box, Kit.strip(field, Vector2(fw, 140) * u, 0.08), Vector2((w - fw) * 0.5, 90))
	var le := LineEdit.new()
	le.max_length = 6
	le.alignment = HORIZONTAL_ALIGNMENT_CENTER
	le.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	le.placeholder_text = "000000"
	le.add_theme_font_override("font", Fonts.get_font("num"))
	le.add_theme_font_size_override("font_size", int(TS.NUM_L * 1.6 * u))
	le.add_theme_color_override("font_color", Kit.INK_DARK)
	le.add_theme_color_override("font_placeholder_color", Color(0.45, 0.38, 0.3, 0.6))
	le.add_theme_color_override("caret_color", Kit.INK_DARK)
	for st in ["normal", "focus", "read_only"]:
		le.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	in_dialog(box, le, Vector2((w - fw) * 0.5 + 40, 102), Vector2(fw - 80, 116))
	var go_b := Kit.button(L.t("join"), Vector2(440, 124) * u, "emerald", "", 44.0 * u)
	go_b.position = Vector2((box.size.x - go_b.size.x) * 0.5, box.size.y - go_b.size.y - 40 * u)
	box.add_child(go_b)
	Kit.set_enabled(go_b, false)
	var fa_digits := "۰۱۲۳۴۵۶۷۸۹"
	le.text_changed.connect(func(t: String):
		var digits := ""
		for ch in t:
			if ch >= "0" and ch <= "9":
				digits += ch
			elif fa_digits.contains(ch):
				digits += str(fa_digits.find(ch))
		if digits != t:
			le.text = digits
			le.caret_column = digits.length()
		Kit.set_enabled(go_b, digits.length() == 6))
	var join := func():
		var code := le.text
		if code.length() != 6:
			return
		close_dialog()
		_busy_dialog(L.t("room_join"), L.t("room_joining"), func(): pass)
		await Api.sync_profile()
		var r := await Api.rpc_call("join_by_code", {"code": code})
		if not r["ok"]:
			close_dialog()
			var why := L.t("in_a_game") if int(r["code"]) == 9 else (L.t("room_not_found") if int(r["code"]) in [3, 5] else "")
			_fail(why)
			return
		await _enter(String(r["data"].get("matchId", "")), "", {"mode": "friends", "players": 0, "code": code})
	go_b.pressed.connect(join)
	le.text_submitted.connect(func(_t: String): join.call())
	le.grab_focus.call_deferred()
