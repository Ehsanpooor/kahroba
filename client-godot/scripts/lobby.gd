class_name Lobby
extends Control
## The table's opening, landscape, in the gem-merchant style: the ready check
## (everyone's portrait in a row; tap Ready; the others get ready on their
## own; a countdown) and who plays first (a gold light hops from seat to seat
## and settles). Both screens cover the board while open and let every touch
## through again when they close.

signal ready_pressed

const READY_SECONDS := 120.0
const D := Vector2(2400, 1080)
const CODE_COL := 700.0  ## the room code's column on the left of the waiting room

var _vp := Vector2.ZERO
var _u := 1.0
var _o := Vector2.ZERO
var _seats: Array[Control] = []
var _stamps: Array = []
var _status: Array[Label] = []
var _ready_btn: Button
var _count: Label
var _bar: ColorRect
var _deadline := 0.0
var _running := false


func _ready() -> void:
	_close()


func _setup() -> void:
	for c in get_children():
		c.queue_free()
	_seats.clear()
	_stamps.clear()
	_status.clear()
	_vp = get_viewport().get_visible_rect().size
	position = Vector2.ZERO
	size = _vp
	_u = minf(_vp.x / D.x, _vp.y / D.y)
	_o = (_vp - D * _u) * 0.5
	visible = true
	modulate.a = 1.0
	mouse_filter = Control.MOUSE_FILTER_STOP  # the board behind cannot be touched
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.025, 0.02)
	bg.size = _vp
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var hall := Kit.tex("menu_bg")
	if hall:
		var t := TextureRect.new()
		t.texture = hall
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		t.size = _vp
		t.modulate = Color(0.45, 0.45, 0.45)
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(t)


## The screen is gone: hidden, and every touch goes to the board again.
func _close() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in get_children():
		c.queue_free()


func _px(p: Vector2) -> Vector2:
	return _o + p * _u


func _text(parent: Control, t: String, px: float, color: Color, kind: String, box: Rect2) -> Label:
	var l := Kit.label(t, px * _u, color, kind, box.size.x * _u)
	l.size = box.size * _u
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.position = (box.position * _u if parent != self else _px(box.position)) - Vector2(0, float(l.get_meta("shift", 0.0)))
	parent.add_child(l)
	return l


## The dialog both screens sit on; returns it (its seats go inside).
func _dialog(title: String, tall := false) -> Control:
	var box := Kit.dialog(Vector2(1900, 760 if tall else 640) * _u, title, false)
	box.position = _px(Vector2(250, 110 if tall else 200))
	add_child(box)
	return box


## Seat i's centre inside the dialog (design px), for n players.
## `left`: a column on the left is taken (the room code); the seats share the rest.
func _seat_c(i: int, n: int, left := 0.0) -> Vector2:
	var step := minf(400.0, (1900.0 - left - 120.0) / maxf(n, 1))
	var mid := left + (1900.0 - left) * 0.5
	var k := (n - 1 - i) if L.fa() else i
	return Vector2(mid + (k - (n - 1) * 0.5) * step, 330)


## One player's seat: the portrait in its gold frame, the name, the rating,
## and a status line under it.
func _seat(box: Control, p: Dictionary, c: Vector2, mine: bool) -> Control:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.size = Vector2(340, 400) * _u
	holder.position = (c - Vector2(170, 170)) * _u
	holder.pivot_offset = Vector2(170, 170) * _u
	box.add_child(holder)
	var av := Kit.avatar(String(p["portrait"]), 240.0 * _u)
	av.position = Vector2(50, 50) * _u
	holder.add_child(av)
	_text(holder, String(p["name"]).strip_edges().get_slice(" ", 0), TS.LABEL, Kit.GOLD if mine else Kit.IVORY,
			"sans_bold", Rect2(0, 295, 340, 56))
	_text(holder, L.t("rating_n", int(p.get("rating", 1000))), TS.CAPTION, Kit.MUTED, "sans", Rect2(0, 345, 340, 40))
	return holder


# ------------------------------------------------------------------ the ready check

## `players` = [{name, portrait, rating}], seat 0 is you. Returns when everyone
## is ready (or the countdown ends). `auto` taps your Ready for you (demo).
func show_ready(players: Array, auto := false) -> void:
	_setup()
	_running = true
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.35)
	var box := _dialog(L.t("ready_title"))
	var r: Rect2 = box.get_meta("content")
	var sub := _text(box, L.t("ready_gather"), TS.BODY, Kit.IVORY, "serif", Rect2(0, r.position.y / _u - 10, 1900, 50))
	var n := players.size()
	for i in n:
		var h := _seat(box, players[i], _seat_c(i, n), i == 0)
		var st := _text(h, L.t("waiting"), TS.CAPTION, Kit.MUTED, "sans_bold", Rect2(0, 380, 340, 36))
		_seats.append(h)
		_stamps.append(null)
		_status.append(st)
		h.scale = Vector2.ONE * 0.6
		h.modulate.a = 0.0
		var tw := h.create_tween().set_parallel(true)
		tw.tween_property(h, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(h, "modulate:a", 1.0, 0.25)
		await get_tree().create_timer(0.2).timeout
	sub.text = L.t("ready_tap")
	_ready_btn = Kit.button(L.t("ready"), Vector2(520, 136) * _u, "emerald", "", 52.0 * _u)
	_ready_btn.position = _px(Vector2(940, 870))
	_ready_btn.pressed.connect(_press_ready)
	add_child(_ready_btn)
	_bar = ColorRect.new()
	_bar.color = Kit.GOLD_DEEP
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.position = _px(Vector2(940, 1020))
	_bar.size = Vector2(520, 8) * _u
	add_child(_bar)
	_count = _text(self, "2:00", TS.NUM_S, Kit.IVORY, "num", Rect2(1480, 880, 200, 110))
	_deadline = Time.get_ticks_msec() / 1000.0 + READY_SECONDS
	for i in range(1, n):
		_ready_later(i, randf_range(0.6, 2.6))
	if auto:
		get_tree().create_timer(1.6).timeout.connect(_press_ready)
	while _stamps.filter(func(s): return s != null).size() < n:
		await get_tree().process_frame
		if _left() <= 0.0:
			break
	sub.text = L.t("all_ready")
	_ready_btn.visible = false
	await get_tree().create_timer(0.8).timeout
	var tw2 := create_tween()
	tw2.tween_property(self, "modulate:a", 0.0, 0.4)
	await tw2.finished
	_running = false
	_close()


func _left() -> float:
	return maxf(_deadline - Time.get_ticks_msec() / 1000.0, 0.0)


func _ready_later(i: int, after: float) -> void:
	await get_tree().create_timer(after).timeout
	if _running:
		_mark_ready(i)


## A seat is ready: an emerald set on its portrait, the line turns green.
func _mark_ready(i: int) -> void:
	if i >= _stamps.size() or _stamps[i] != null:
		return
	var holder := _seats[i]
	var g := Kit.gem("green", 90.0 * _u)
	g.position = Vector2(225, 215) * _u
	g.pivot_offset = g.size * 0.5
	holder.add_child(g)
	g.scale = Vector2.ONE * 2.0
	g.modulate.a = 0.0
	var tw := g.create_tween().set_parallel(true)
	tw.tween_property(g, "scale", Vector2.ONE, 0.22).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(g, "modulate:a", 1.0, 0.12)
	_stamps[i] = g
	Sfx.play("token_place")
	_status[i].text = L.t("is_ready")
	_status[i].add_theme_color_override("font_color", Color(0.55, 0.95, 0.55))


func _press_ready() -> void:
	if not _running or _stamps.is_empty() or _stamps[0] != null:
		return
	_mark_ready(0)
	Kit.set_enabled(_ready_btn, false)
	ready_pressed.emit()


func _process(_delta: float) -> void:
	if _running and _count and is_instance_valid(_count) and _bar and is_instance_valid(_bar):
		var left := _left()
		_count.text = "%d:%02d" % [int(left) / 60, int(left) % 60]
		_bar.scale.x = left / READY_SECONDS


# ------------------------------------------------------------------ who plays first

## A gold light hops from seat to seat (fast, then slower) and settles on
## `index`; that seat grows, the others dim, a plaque names the first player.
func choose_starter(players: Array, index: int) -> void:
	_setup()
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.3)
	var box := _dialog(L.t("who_starts"))
	var r: Rect2 = box.get_meta("content")
	_text(box, L.t("who_starts_sub"), TS.BODY, Kit.IVORY, "serif", Rect2(0, r.position.y / _u - 10, 1900, 50))
	var n := players.size()
	var seats: Array[Control] = []
	for i in n:
		seats.append(_seat(box, players[i], _seat_c(i, n), i == 0))
	var light := Kit.gem("white", 120.0 * _u)
	light.pivot_offset = light.size * 0.5
	box.add_child(light)
	await get_tree().create_timer(0.5).timeout
	var hops := 2 * n + index + 1
	var t := 0.07
	for k in hops:
		var cur := k % n
		for j in n:
			var on := j == cur
			seats[j].create_tween().tween_property(seats[j], "scale", Vector2.ONE * (1.1 if on else 0.92), t * 0.8)
			seats[j].modulate = Color(1.12, 1.08, 1.0) if on else Color(0.6, 0.6, 0.62)
		light.position = seats[cur].position + Vector2(110, -60) * _u
		Sfx.play("clock_tick", 0.0, -4.0)
		await get_tree().create_timer(t).timeout
		t *= 1.17
	var win := seats[index]
	Sfx.play("token_pick")
	var tw := create_tween().set_parallel(true)
	tw.tween_property(win, "scale", Vector2.ONE * 1.22, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	for j in n:
		if j != index:
			tw.tween_property(seats[j], "modulate:a", 0.3, 0.35)
	var who := L.t("you_first") if index == 0 else L.t("plays_first", String(players[index]["name"]).get_slice(" ", 0))
	var plaque := Control.new()
	plaque.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plaque.size = Vector2(900, 130) * _u
	plaque.position = _px(Vector2(750, 875))
	plaque.add_child(Kit.plate("emerald" if index == 0 else "sapphire", plaque.size))
	_text(plaque, who, TS.TITLE, Kit.GOLD, "title_bold", Rect2(100, 0, 700, 130))
	add_child(plaque)
	plaque.pivot_offset = plaque.size * 0.5
	plaque.scale = Vector2.ONE * 0.6
	plaque.modulate.a = 0.0
	var tw2 := plaque.create_tween().set_parallel(true)
	tw2.tween_property(plaque, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw2.tween_property(plaque, "modulate:a", 1.0, 0.2)
	await get_tree().create_timer(1.8).timeout
	var out := create_tween()
	out.tween_property(self, "modulate:a", 0.0, 0.35)
	await out.finished
	_close()  # let the board take touches again


# ------------------------------------------------------------------ an online table (the server runs it)

## The waiting room of a friends' room (its code, the seats filling up), then
## the ready check, both as the server reports them. Returns when the game
## starts, or when the player leaves (the board then goes to the menu).
func show_net(net: NetGame) -> void:
	_setup()
	_running = true
	var sent_ready := [false]
	var draw := func():
		_setup()
		var phase := net.phase()
		var waiting := phase == "waiting"
		var with_code := waiting and net.room_code != ""
		var box := _dialog(L.t("room_code") if with_code else L.t("ready_title"))
		var r: Rect2 = box.get_meta("content")
		var top := r.position.y / _u
		if waiting and net.room_code != "":
			# the code on the left, the seats on the right
			var hint := _text(box, L.t("room_waiting"), TS.BODY, Kit.IVORY, "serif", Rect2(70, top + 40, CODE_COL - 70, 130))
			hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			_code_button(box, net.room_code, Vector2(70 + (CODE_COL - 70 - 560.0) * 0.5, top + 200))
		else:
			_text(box, L.t("ready_tap") if not sent_ready[0] else L.t("ready_gather"), TS.BODY, Kit.IVORY, "serif",
					Rect2(0, top - 10, 1900, 50))
		var seats: Array = net.lobby_seats()
		var n := seats.size()
		_seats.clear()
		_stamps.clear()
		_status.clear()
		for i in n:
			var sd: Dictionary = seats[i]
			var c := _seat_c(i, n, CODE_COL if with_code else 0.0)
			if sd["open"] or String(sd["name"]) == "":
				var h := Control.new()
				h.mouse_filter = Control.MOUSE_FILTER_IGNORE
				h.size = Vector2(340, 400) * _u
				h.position = (c - Vector2(170, 170)) * _u
				box.add_child(h)
				var g := Kit.gem("white", 120.0 * _u)
				g.position = Vector2(110, 110) * _u
				g.modulate = Color(0.45, 0.45, 0.45, 0.7)
				h.add_child(g)
				_text(h, L.t("waiting"), TS.CAPTION, Kit.MUTED, "sans_bold", Rect2(0, 295, 340, 56))
				_seats.append(h)
				_stamps.append(null)
				_status.append(null)
				continue
			var hs := _seat(box, sd, c, sd["me"])
			var st := _text(hs, "" if waiting else L.t("waiting"), TS.CAPTION, Kit.MUTED, "sans_bold", Rect2(0, 380, 340, 36))
			_seats.append(hs)
			_stamps.append(null)
			_status.append(st)
			if sd["ready"] and not waiting:
				_mark_ready(i)
		if phase == "readyCheck" and not sent_ready[0]:
			_ready_btn = Kit.button(L.t("ready"), Vector2(520, 136) * _u, "emerald", "", 52.0 * _u)
			_ready_btn.position = _px(Vector2(940, 870))
			_ready_btn.pressed.connect(func():
				sent_ready[0] = true
				Kit.set_enabled(_ready_btn, false)
				net.send_ready()
				ready_pressed.emit())
			add_child(_ready_btn)
			if OS.get_cmdline_user_args().has("--autoplay"):  # test: ready by itself
				get_tree().create_timer(1.5).timeout.connect(func():
					if is_instance_valid(_ready_btn) and not sent_ready[0]:
						_ready_btn.pressed.emit())
		if phase == "readyCheck":
			_count = _text(self, "", TS.NUM_S, Kit.IVORY, "num", Rect2(1480, 880, 200, 110))
			_deadline = Time.get_ticks_msec() / 1000.0 + net.ready_left()
			_bar = ColorRect.new()
			_bar.color = Kit.GOLD_DEEP
			_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_bar.position = _px(Vector2(940, 1020))
			_bar.size = Vector2(520, 8) * _u
			add_child(_bar)
		var leave := Kit.button(L.t("leave"), Vector2(300, 108) * _u, "onyx", "", 36.0 * _u)
		leave.position = _px(Vector2(mx_left(), 880))
		leave.pressed.connect(func():
			_running = false
			net.leave_lobby())
		add_child(leave)
	draw.call()
	_poll_room(net)
	while _running and net.phase() != "playing" and not net.is_ended():
		await net.state_arrived
		if _running and net.phase() != "playing":
			draw.call()
	_running = false
	_close()


## The room code on a plate: tap it to copy it (a toast says so), ready to
## paste into a chat.
func _code_button(box: Control, code: String, at: Vector2) -> void:
	var w := 560.0
	var h := 112.0
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	Kit._empty_styles(b)
	b.size = Vector2(w, h) * _u
	b.position = at * _u
	box.add_child(b)
	var field := Kit.tex("input_field")
	if field:
		b.add_child(Kit.strip(field, b.size, 0.08))
	var spaced := code.substr(0, 3) + " " + code.substr(3)
	_text(b, spaced, TS.NUM_L, Kit.INK_DARK, "num", Rect2(40, 0, w - 170, h))
	var icon := Kit.tex("icon_copy")
	var hint := _text(b, L.t("copy"), TS.CAPTION, Color(0.35, 0.25, 0.12), "sans_bold", Rect2(w - 150, 0, 110, h))
	if icon:
		hint.visible = false
		var ic := TextureRect.new()
		ic.texture = icon
		ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ic.position = Vector2(w - 120, (h - 60) * 0.5) * _u
		ic.size = Vector2(60, 60) * _u
		b.add_child(ic)
	Kit.feedback(b)
	b.pressed.connect(func():
		DisplayServer.clipboard_set(code)
		hint.text = L.t("copied")
		hint.visible = true
		_toast(L.t("code_copied")))


## A short note at the bottom of the screen.
func _toast(t: String) -> void:
	var l := _text(self, t, TS.BODY, Kit.IVORY, "serif_bold", Rect2(0, 1000, D.x, 60))
	var tw := l.create_tween()
	tw.tween_interval(1.6)
	tw.tween_property(l, "modulate:a", 0.0, 0.4)
	tw.tween_callback(l.queue_free)


func mx_left() -> float:
	return 1900.0 if L.fa() else 200.0


## While friends are still arriving the server tells only the newcomer, so
## the room asks for the table every two seconds.
func _poll_room(net: NetGame) -> void:
	while _running and net.phase() == "waiting" and is_inside_tree():
		Api.send_op(Api.OP_SYNC)
		await get_tree().create_timer(2.0).timeout
