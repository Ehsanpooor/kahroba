extends Screen
## The main menu: the merchant's hall behind; on the left the title over a
## row of the five gems, PLAY (emerald) and three onyx choices; top right,
## you (portrait, name, rating) and the settings button. A first-time player
## is offered the tutorial.

static var _offered := false
static var _synced := false  ## profile sent and rating read once per launch


func build() -> void:
	Sfx.music(true, "menu")
	backdrop("menu_bg", 0.15)
	# a soft dark band behind the menu, so it reads on any hall
	var band := TextureRect.new()
	var gt := GradientTexture2D.new()
	gt.fill_from = Vector2(1.0 if L.fa() else 0.0, 0.5)
	gt.fill_to = Vector2(0.0 if L.fa() else 1.0, 0.5)
	var g := Gradient.new()
	g.set_color(0, Color(0, 0.01, 0, 0.72))
	g.set_color(1, Color(0, 0.01, 0, 0.0))
	gt.gradient = g
	band.texture = gt
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	put(band, Vector2(mx(0, 1300), 0), Vector2(1300, D.y))

	var cx := mx(140, 900)
	var logo := Kit.tex("logo_splendor")
	if logo:
		var r := TextureRect.new()
		r.texture = logo
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		put(r, Vector2(cx, 40), Vector2(900, 350))
		text(L.t("game_sub"), TS.LABEL, Kit.IVORY, "title_bold", Rect2(cx, 370, 900, 60))
	else:
		text(L.t("game_title"), 150.0, Kit.GOLD, "title_bold", Rect2(cx, 90, 900, 190))
		text(L.t("game_sub"), TS.LABEL, Kit.IVORY, "title_bold", Rect2(cx, 270, 900, 60))
		put_at(Kit.gem_row(760.0 * u, 70.0 * u), Vector2(cx + 70, 345))

	var play_b := Kit.button(L.t("play"), Vector2(760, 160) * u, "emerald", "", 64.0 * u)
	put_at(play_b, Vector2(cx + 70, 450))
	play_b.pressed.connect(func(): go.emit("play", null))
	var items := [["how_to", "book", "howto"], ["leaderboard", "trophy", "leaderboard"], ["history", "scroll", "history"]]
	for i in items.size():
		var b := Kit.button(L.t(items[i][0]), Vector2(680, 124) * u, "onyx", items[i][1], 44.0 * u)
		put_at(b, Vector2(cx + 110, 650 + i * 136))
		var target: String = items[i][2]
		b.pressed.connect(func(): go.emit(target, null))

	# you, and the settings: your portrait as a medallion on the end of an onyx plate
	var me := Button.new()
	me.focus_mode = Control.FOCUS_NONE
	Kit._empty_styles(me)
	put(me, Vector2(mx(1540, 600), 24), Vector2(600, 150))
	var plate := Kit.plate("onyx", Vector2(500, 130) * u)
	plate.position = Vector2(mx(90, 500, 600), 10) * u
	me.add_child(plate)
	var av := Kit.avatar(String(Prefs.get_v("portrait")), 150.0 * u)
	av.position = Vector2(mx(0, 150, 600), 0) * u
	me.add_child(av)
	text(Prefs.display_name(), TS.BODY, Kit.GOLD, "sans_bold", Rect2(mx(170, 330, 600), 26, 330, 50), start_align(), me)
	text(L.t("rating_n", int(Prefs.get_v("rating"))), TS.CAPTION, Kit.IVORY, "sans", Rect2(mx(170, 330, 600), 76, 330, 40),
			start_align(), me)
	Kit.feedback(me)
	me.pressed.connect(func(): go.emit("profile", null))
	var gear := Kit.round_button("settings", 140.0 * u)
	put_at(gear, Vector2(mx(2200, 140), 30))
	gear.pressed.connect(func(): go.emit("settings", null))

	if Net.online and not _synced:
		_synced = true
		_sync_server()
	var saved := SavedGame.read()
	if not saved.is_empty():
		_saved_panel(saved)
		if String(saved.get("match_id", "")) != "" and Net.online:
			_check_server_game(String(saved["match_id"]))
		if not Net.changed.is_connected(_on_net):
			Net.changed.connect(_on_net)

	if not Prefs.get_v("tutorial_done") and not _offered and saved.is_empty():
		_offered = true
		get_tree().create_timer(0.7).timeout.connect(_offer_tutorial)


func _offer_tutorial() -> void:
	if not is_inside_tree():
		return
	message(L.t("tut_title"), L.t("tut_body"), [
		[L.t("later"), "onyx", func(): pass],
		[L.t("tut_start"), "emerald", func(): play.emit({"mode": "tutorial", "players": 2, "difficulty": "easy"})],
	])


## The game still in progress, on the right: what it is, who is at the
## table, how you stand; Continue (or Rejoin, for an online game once the
## server answers) and Abandon.
func _saved_panel(d: Dictionary) -> void:
	var online := SavedGame.is_online(d)
	var box_w := 820.0
	var box_h := 680.0 if online else 600.0
	var dlg := Kit.dialog(Vector2(box_w, box_h) * u, L.t("saved_t"), false)
	put_at(dlg, Vector2(mx(1470, box_w), 350))
	var r: Rect2 = dlg.get_meta("content")
	var top := r.position.y / u
	var mode := String(d.get("mode", "ai"))
	var line := L.t("saved_" + mode, int(d.get("round_no", 1)))
	_in(dlg, Kit.label(line, TS.LABEL * u, Kit.IVORY, "serif_bold", box_w * u), Vector2(0, top))
	# the others at the table
	var opps: Array = d.get("opps", [])
	var cell := 220.0
	var x0 := (box_w - opps.size() * cell) * 0.5
	for i in opps.size():
		var q: Dictionary = opps[i]
		var k := opps.size() - 1 - i if L.fa() else i
		var av := Kit.avatar(String(q.get("portrait", "")), 120.0 * u)
		_in(dlg, av, Vector2(x0 + k * cell + (cell - 120.0) * 0.5, top + 70))
		var nm := String(L.t("bot_" + String(q["bot"]))) if q.has("bot") else String(q.get("name", ""))
		_in(dlg, Kit.label(nm.get_slice(" ", 0), TS.CAPTION * u, Kit.IVORY, "sans_bold", cell * u),
				Vector2(x0 + k * cell, top + 192))
		_in(dlg, Kit.label(str(int(q.get("prestige", 0))), TS.CAPTION * u, Kit.GOLD, "num", cell * u),
				Vector2(x0 + k * cell, top + 228))
	var me: Dictionary = d.get("me", {})
	_in(dlg, Kit.label(L.t("saved_you", int(me.get("prestige", 0)), int(d.get("win_points", 15))), TS.BODY * u,
			Kit.GOLD, "sans_bold", box_w * u), Vector2(0, top + 285))
	# the way back in, and the way out
	var go_text := L.t("rejoin") if online else L.t("continue")
	var cont := Kit.button(go_text, Vector2(420, 124) * u, "sapphire" if online else "emerald", "", 44.0 * u)
	var ab := Kit.button(L.t("abandon"), Vector2(280, 108) * u, "onyx", "", 36.0 * u)
	var bx := (box_w - 420.0 - 280.0 - 40.0) * 0.5
	_in(dlg, cont, Vector2(bx + (320.0 if L.fa() else 0.0), top + 355))
	_in(dlg, ab, Vector2(bx + (0.0 if L.fa() else 460.0), top + 363))
	if online:
		var mins := maxi(int(ceil((SavedGame.REJOIN_SECONDS - SavedGame.age(d)) / 60.0)), 1)
		var note := L.t("seat_kept", mins) if Net.online else L.t("waiting_server")
		_in(dlg, Kit.label(note, TS.CAPTION * u, Color(0.95, 0.66, 0.45) if not Net.online else Kit.MUTED, "serif",
				box_w * u), Vector2(0, top + 490))
		Kit.set_enabled(cont, Net.online)
	var net_id := String(d.get("match_id", ""))
	cont.pressed.connect(func():
		var opp_n := opps.size()
		if net_id != "":
			_rejoin(net_id, mode)
			return
		play.emit({"mode": mode, "players": opp_n + 1, "difficulty": String(d.get("difficulty", "normal")),
				"win_points": int(d.get("win_points", 15)), "resume": true}))
	ab.pressed.connect(func():
		message(L.t("abandon_t"), L.t("abandon_online") if online else L.t("abandon_ai"), [
			[L.t("cancel"), "onyx", func(): pass],
			[L.t("abandon"), "ruby", func():
				if online:  # leaving a rated table is a loss
					_record_loss(d)
					if net_id != "":
						Api.rpc_call("concede_match", {"matchId": net_id})
				SavedGame.clear()
				_rebuild()],
		]))


func _record_loss(d: Dictionary) -> void:
	var seats := []
	for q in [d["me"]] + (d["opps"] as Array):
		seats.append({"name": q["name"], "portrait": q["portrait"], "power": int(q["prestige"])})
	Prefs.add_history({"result": "loss", "mode": d["mode"], "players": seats.size(), "difficulty": d["difficulty"],
			"power": int(d["me"]["prestige"]), "rating_delta": 0, "played_at": int(Time.get_unix_time_from_system()),
			"seats": seats, "moves": d.get("moves", [])})


func _in(dlg: Control, c: Control, pos: Vector2) -> void:
	c.position = pos * u
	dlg.add_child(c)


func _on_net(_online: bool) -> void:
	if is_inside_tree() and _dialog == null:
		_rebuild()


## An online game kept on this device that the server has already finished
## is forgotten.
func _check_server_game(id: String) -> void:
	var r := await Api.rpc_call("get_active_game", {})
	if r["ok"] and String(r["data"].get("matchId", "")) != id and is_inside_tree():
		SavedGame.clear()
		_rebuild()


## Back to the table of an online game: sit down again and open the board.
func _rejoin(id: String, mode: String) -> void:
	var why := await Api.join_match(id)
	if why != "":
		SavedGame.clear()
		message(L.t("saved_t"), L.t("game_gone"), [[L.t("ok"), "onyx", func(): _rebuild()]])
		return
	play.emit({"mode": mode, "net": true, "match_id": Api.match_id})


## Tell the server your name and portrait; take your rating from it.
func _sync_server() -> void:
	await Api.sync_profile()
	var r := await Api.my_rating()
	if r.has("rating") and int(r["rating"]) != int(Prefs.get_v("rating")):
		Prefs.set_v("rating", int(r["rating"]))
		if is_inside_tree() and _dialog == null:
			_rebuild()
