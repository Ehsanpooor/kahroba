class_name TableHud
extends Control
## The 2D layer of the table, mobile first (2400 x 1080 design px, every text
## size from TS): the opponents' seats down the left, your tray along the
## bottom (both PlayerView), the menu, the coin-taking and card buttons, and
## every dialog. The turn clock is the ring of the playing player's portrait.

signal buy_pressed
signal reserve_pressed
signal close_inspect
signal done_pressed
signal undo_pressed
signal skip_pressed
signal menu_pressed
signal time_up

const TURN_SECONDS := 90.0
## Where the design puts each player area (design PNG px x K): the seats
## attached to the left edge, your panel to the bottom, the clock beside it.
const SEAT_TOPS := [5.0, 345.0, 683.0]
const ME_POS := Vector2(0, 940)
const CLOCK_POS := Vector2(2241.4, 868.7)
const MENU := Rect2(2316.6 - 112, 14, 96, 96)
const STAGE_Y := 807.1  # between the board and your panel
## The in-game buttons, measured on the host's screenshots (design px).
const BTN_SKIP := Rect2(730, 752, 340, 92)
const BTN_UNDO := Rect2(730, 752, 300, 92)
const BTN_DONE := Rect2(1500, 752, 340, 92)
const BTN_PX := 40.0
const CENTER := Vector2(1441.3, 427.2)  # middle of the card area (design: slots centre)

const GOLD := Color(0.96, 0.78, 0.4)
const GOLD_LIGHT := Color(1.0, 0.9, 0.62)
const IVORY := Color(0.95, 0.92, 0.85)
const MUTED := Color(0.78, 0.74, 0.66)
const STYLES := {
	"panel": [Color(0.12, 0.1, 0.09, 0.95), Color(0.04, 0.035, 0.04, 0.95), Color(0.82, 0.62, 0.3, 0.9), 2.0, 0.05],
	"dark": [Color(0.24, 0.2, 0.16, 1), Color(0.09, 0.075, 0.07, 1), Color(0.9, 0.7, 0.36, 1), 2.5, 0.14],
	"gold": [Color(1.0, 0.85, 0.48, 1), Color(0.7, 0.46, 0.14, 1), Color(1.0, 0.95, 0.75, 1), 2.5, 0.3],
	"green": [Color(0.32, 0.7, 0.36, 1), Color(0.09, 0.32, 0.13, 1), Color(0.82, 0.97, 0.64, 1), 2.5, 0.24],
	"red": [Color(0.8, 0.26, 0.21, 1), Color(0.36, 0.07, 0.06, 1), Color(1.0, 0.74, 0.62, 1), 2.5, 0.2],
}
const INK := {"panel": IVORY, "dark": GOLD_LIGHT, "gold": Color(0.24, 0.13, 0.02), "green": Color(1, 1, 1),
		"red": Color(1, 1, 1)}

var lay: TLayout
var s := 1.0
var me: Dictionary = {}
var opps: Array = []
var win_points := 15
var turn := 0
var turn_started := 0.0
var timer_running := false
var round_no := 1
var modal: Control
var modal_closed_at := -10.0

var _root: Control
var me_view: PlayerView
var seats: Array[PlayerView] = []
## More than three opponents (a friends' room seats up to 6): their column
## shows three at a time and scrolls (drag, or the mouse wheel), settling on
## a whole seat; it turns to whoever is playing. Gem dots beside it show
## which seats are in view.
var _col: Control
var _col_off := 0.0
var _col_step := 0.0
var _col_max := 0.0
var _col_drag := false
var _col_tw: Tween
var _col_dots: Array[Control] = []
var clock: TurnClock
var _round: Label
var _stage := {}
var _inspect := {}
var _skip_btn: Button
var _toast: Control
var _announce: Control
var _time_up_sent := false
var _tick_sec := -1  # the last second ticked (your last 10 seconds tick)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


# ------------------------------------------------------------------ building blocks

func _box(size_d: Vector2, style: String, radius_d := 18.0, glow := 0.0) -> ColorRect:
	var pad := 14.0 * s
	var r := ColorRect.new()
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.size = size_d * s + Vector2.ONE * pad * 2.0
	r.position = -Vector2.ONE * pad
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/gui_box.gdshader")
	var st: Array = STYLES[style]
	m.set_shader_parameter("size", r.size)
	m.set_shader_parameter("pad", pad)
	m.set_shader_parameter("radius", radius_d * s)
	m.set_shader_parameter("top_col", st[0])
	m.set_shader_parameter("bottom_col", st[1])
	m.set_shader_parameter("edge_col", st[2])
	m.set_shader_parameter("edge", float(st[3]) * s)
	m.set_shader_parameter("sheen", st[4])
	m.set_shader_parameter("glow", glow)
	r.material = m
	return r


func _put(parent: Control, c: Control, pos: Vector2, size_d: Vector2) -> Control:
	c.position = pos * s
	c.size = size_d * s
	parent.add_child(c)
	return c


func _label(text: String, px: float, color: Color, kind: String, w: float,
		align := HORIZONTAL_ALIGNMENT_CENTER, outline := 0.0) -> Label:
	var l := Fonts.label2d(text, px * s, color, kind, outline * s)
	l.size = Vector2(w, px * 1.6) * s
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Fonts.fit(l, w * s, 0.85)
	return l


func _text(parent: Control, text: String, px: float, color: Color, kind: String, pos: Vector2, w: float,
		align := HORIZONTAL_ALIGNMENT_CENTER, outline := 0.0) -> Label:
	var l := _label(text, px, color, kind, w, align, outline)
	l.position = pos * s - Vector2(0, float(l.get_meta("shift")))
	parent.add_child(l)
	return l


func _para(parent: Control, text: String, px: float, color: Color, pos: Vector2, w: float) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", Fonts.get_font("serif"))
	l.add_theme_font_size_override("font_size", int(px * s))
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.position = pos * s
	l.size = Vector2(w, 10) * s
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


## A button from the gem kit. Old style names map to the host's materials:
## green -> emerald, gold -> sapphire, dark -> onyx, red -> ruby; "ivory" and
## the kit names pass through. `kind` / `ink` override the text's font and colour.
func button(text: String, size_d: Vector2, style: String, cb: Callable, px := TS.LABEL,
		kind := "title_bold", ink := Color(0, 0, 0, 0)) -> Button:
	var kit_style: String = {"green": "emerald", "gold": "sapphire", "dark": "onyx", "red": "ruby",
			"panel": "onyx"}.get(style, style)
	var b := Kit.button(text, size_d * s, kit_style, "", minf(px, size_d.y * 0.42) * s, kind, ink)
	b.pressed.connect(cb)
	return b


func _avatar(portrait: String, d: float) -> Control:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.size = Vector2(d, d) * s
	var face := TextureRect.new()
	face.texture = Tex.get_tex(Tex.CUSTOM if portrait == "custom" else "res://assets/portraits/%s.png" % portrait)
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_SCALE
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/avatar.gdshader")
	mat.set_shader_parameter("uv_rect", Tex.face_rect(portrait))
	face.material = mat
	face.size = holder.size * 0.86
	face.position = holder.size * 0.07
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(face)
	var frame := Gems.path_if("ui/portrait_frame.png")
	if frame != "":
		var f := TextureRect.new()
		f.texture = Tex.get_tex(frame)
		f.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		f.stretch_mode = TextureRect.STRETCH_SCALE
		# the frame's opening is 70 % of its radius: it rings the face exactly
		f.size = holder.size * 0.86 / 0.7
		f.position = holder.size * 0.5 - f.size * 0.5
		f.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(f)
	return holder


func _mx(x: float, item_w: float, w: float) -> float:
	return w - x - item_w if L.fa() else x


func _start() -> int:
	return HORIZONTAL_ALIGNMENT_RIGHT if L.fa() else HORIZONTAL_ALIGNMENT_LEFT


func _cx() -> float:
	return lay.mid(CENTER.x)


# ------------------------------------------------------------------ build

func build(layout: TLayout, me_p: Dictionary, opponents: Array, win: int) -> void:
	lay = layout
	s = lay.s
	me = me_p
	opps = opponents
	win_points = win
	if _root:
		_root.queue_free()
	_root = Control.new()
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.position = lay.origin
	_root.size = lay.size * s
	add_child(_root)
	move_child(_root, 0)
	seats.clear()
	_col = null
	_col_dots.clear()
	var parent := _root
	if opps.size() > SEAT_TOPS.size():
		_build_column()
		parent = _col
	for i in opps.size():
		var v := PlayerView.new()
		v.setup(opps[i], "seat", s)
		parent.add_child(v)
		if _col:
			v.position = Vector2(0, i * _col_step - _col_off)
		else:
			v.position = Vector2(0, float(SEAT_TOPS[mini(i, 2)])) * PlayerView.K * s
		seats.append(v)
	if _col:
		_col_set(_col_off)
	# your panel and the turn clock sit on the screen's bottom edge, the other
	# players on its left edge, whatever the screen's shape (the table between
	# them is fitted whole and centred, which can leave a band at the edges)
	var to_bottom := lay.origin.y
	var to_left := -lay.origin.x
	if not _col:  # (in the scrolling column the column itself moves)
		for v in seats:
			v.position.x += to_left
	if _col:
		_col.position.x += to_left
		for d in _col_dots:
			d.position.x += to_left
	me_view = PlayerView.new()
	me_view.setup(me, "me", s)
	_root.add_child(me_view)
	me_view.position = ME_POS * PlayerView.K * s + Vector2(0, to_bottom)
	clock = TurnClock.new()
	clock.setup(s)
	_root.add_child(clock)
	clock.position = CLOCK_POS * PlayerView.K * s + Vector2(0, to_bottom)
	_build_top()
	_build_stage()
	_build_inspect()
	_show_turn()


func _build_column() -> void:
	_col_step = (SEAT_TOPS[1] - SEAT_TOPS[0]) * PlayerView.K * s
	_col_max = _col_step * (opps.size() - SEAT_TOPS.size())
	_col_off = clampf(_col_off, 0.0, _col_max)
	_col = Control.new()
	_col.clip_contents = true
	_col.mouse_filter = Control.MOUSE_FILTER_PASS  # taps still reach the board
	_col.position = Vector2(0, SEAT_TOPS[0]) * PlayerView.K * s
	_col.size = Vector2(PlayerView.SEAT_SIZE.x * s,
			(SEAT_TOPS[2] - SEAT_TOPS[0]) * PlayerView.K * s + PlayerView.SEAT_SIZE.y * s)
	_root.add_child(_col)
	_col.gui_input.connect(_col_input)
	# one gem per opponent beside the column: bright for the seats in view
	var d := 40.0 * s
	var gap := 18.0 * s
	var total := opps.size() * d + (opps.size() - 1) * gap
	for i in opps.size():
		var g := Kit.gem("green", d)
		g.position = Vector2(_col.size.x + 10.0 * s, _col.position.y + (_col.size.y - total) * 0.5 + i * (d + gap))
		g.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(g)
		_col_dots.append(g)


func _col_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and ((e as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT):
		var dy := (e as InputEventMouseMotion).relative.y
		if _col_drag or absf(dy) > 2.0:
			_col_drag = true
			if _col_tw:
				_col_tw.kill()
			_col_set(clampf(_col_off - dy, 0.0, _col_max))
	elif e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_col_scroll(_col_off + _col_step)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_col_scroll(_col_off - _col_step)
		elif not mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT and _col_drag:
			_col_drag = false
			_col_scroll(roundf(_col_off / _col_step) * _col_step)  # settle on a whole seat


func _col_scroll(off: float) -> void:
	if _col == null:
		return
	off = clampf(off, 0.0, _col_max)
	if _col_tw:
		_col_tw.kill()
	_col_tw = _col.create_tween()
	_col_tw.tween_method(_col_set, _col_off, off, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _col_set(off: float) -> void:
	_col_off = off
	for i in seats.size():
		seats[i].position.y = i * _col_step - off
	var first := roundi(off / _col_step)
	for i in _col_dots.size():
		var on := i >= first and i < first + SEAT_TOPS.size()
		_col_dots[i].modulate = Color.WHITE if on else Color(0.4, 0.4, 0.4, 0.75)


## Turn the column so opponent i is in view.
func show_seat(i: int) -> void:
	if _col == null or i < 0 or i >= seats.size():
		return
	var first := roundi(_col_off / _col_step)
	if i < first:
		_col_scroll(i * _col_step)
	elif i >= first + SEAT_TOPS.size():
		_col_scroll((i - SEAT_TOPS.size() + 1) * _col_step)


## A point on an opponent's seat, kept inside the column when it is scrolled away.
func _seat_pt(p: Vector2) -> Vector2:
	if _col == null:
		return p
	var r := _col.get_global_rect()
	return Vector2(p.x, clampf(p.y, r.position.y + 30.0 * s, r.end.y - 30.0 * s))


func _build_top() -> void:
	var menu := Kit.round_button("menu", MENU.size.x * s)
	menu.pressed.connect(func(): menu_pressed.emit())
	_put(_root, menu, Vector2(lay.right(MENU.position.x), MENU.position.y), MENU.size)
	_round = _text(_root, "", TS.CAPTION, MUTED, "serif_bold", Vector2(lay.right(1970), 38), 220.0,
			HORIZONTAL_ALIGNMENT_RIGHT, 3.0)


func _build_stage() -> void:
	# all centred under the cards
	var cx := _cx()
	var lbl := _text(_root, "", TS.LABEL, GOLD_LIGHT, "title_bold", Vector2(cx - 300, STAGE_Y - 46), 600.0,
			HORIZONTAL_ALIGNMENT_CENTER, 3.0)
	# the host's design: Skip (onyx) and Undo (emerald) under the board's left
	# edge, Done (ivory, dark green letters) on the right; Josefin Sans
	var undo := button(L.t("undo"), BTN_UNDO.size, "emerald", func(): undo_pressed.emit(), BTN_PX,
			"sans_bold", Color("#b9e3a2"))
	_put(_root, undo, Vector2(lay.mid(BTN_UNDO.position.x), BTN_UNDO.position.y), BTN_UNDO.size)
	var done := button(L.t("done"), BTN_DONE.size, "ivory", func(): done_pressed.emit(), BTN_PX,
			"sans_bold", Color("#1f5a2b"))
	_put(_root, done, Vector2(lay.mid(BTN_DONE.position.x), BTN_DONE.position.y), BTN_DONE.size)
	_skip_btn = button(L.t("skip"), BTN_SKIP.size, "onyx", func(): skip_pressed.emit(), BTN_PX,
			"sans_bold", Color("#d9b46a"))
	_put(_root, _skip_btn, Vector2(lay.mid(BTN_SKIP.position.x), BTN_SKIP.position.y), BTN_SKIP.size)
	_stage = {"label": lbl, "undo": undo, "done": done}
	set_stage("", false)


func set_stage(text: String, mine: bool, full := false) -> void:
	if _stage.is_empty():
		return
	(_stage["label"] as Label).text = "" if mine else text  # your own taking needs no words, the buttons say it
	(_stage["undo"] as Control).visible = mine
	(_stage["done"] as Control).visible = mine
	(_stage["done"] as Control).self_modulate = Color(1.1, 1.08, 1.0) if full else Color.WHITE


func show_skip(on: bool) -> void:
	if _skip_btn:
		_skip_btn.visible = on


func _build_inspect() -> void:
	var box := Control.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_put(_root, box, Vector2.ZERO, lay.size)
	var note := _text(box, "", TS.BODY, Color(1.0, 0.64, 0.56), "serif_bold", Vector2(_cx() - 600, 610), 1200.0,
			HORIZONTAL_ALIGNMENT_CENTER, 3.0)
	var gold := _text(box, "", TS.BODY, GOLD_LIGHT, "serif", Vector2(_cx() - 600, 656), 1200.0,
			HORIZONTAL_ALIGNMENT_CENTER, 3.0)
	# as the host's examples: BUY ivory, RESERVE sapphire, close onyx
	var buy := button(L.t("buy"), Vector2(420, 126), "ivory", func(): buy_pressed.emit(), TS.TITLE)
	var res := button(L.t("reserve"), Vector2(460, 126), "sapphire", func(): reserve_pressed.emit(), TS.TITLE)
	var close := button(L.t("close"), Vector2(360, 108), "onyx", func(): close_inspect.emit(), TS.LABEL)
	box.add_child(buy)
	box.add_child(res)
	box.add_child(close)
	_inspect = {"box": box, "note": note, "gold": gold, "buy": buy, "reserve": res, "close": close}
	box.visible = false


func show_inspect(on: bool, can_buy := true, can_reserve := true, note := "", gold_note := "",
		show_reserve := true) -> void:
	var box: Control = _inspect["box"]
	if not on:
		if box.visible:
			var tw := box.create_tween()
			tw.tween_property(box, "modulate:a", 0.0, 0.15)
			tw.tween_callback(func(): box.visible = false)
		return
	(_inspect["note"] as Label).text = note
	(_inspect["gold"] as Label).text = gold_note
	var buy: Button = _inspect["buy"]
	var res: Button = _inspect["reserve"]
	var close: Button = _inspect["close"]
	res.visible = show_reserve
	var items: Array[Control] = [buy]
	if show_reserve:
		items.append(res)
	items.append(close)
	if L.fa():
		items.reverse()
	var total := 0.0
	for it in items:
		total += it.size.x / s + 28.0
	var x := _cx() - (total - 28.0) * 0.5
	for it in items:
		it.position = Vector2(x, 716 + (126.0 - it.size.y / s) * 0.5) * s
		x += it.size.x / s + 28.0
	buy.modulate = Color(1, 1, 1, 1) if can_buy else Color(0.6, 0.6, 0.6, 0.85)
	res.modulate = Color(1, 1, 1, 1) if can_reserve else Color(0.6, 0.6, 0.6, 0.85)
	box.visible = true
	box.modulate.a = 0.0
	var tw := box.create_tween()
	tw.tween_property(box, "modulate:a", 1.0, 0.2).set_delay(0.12)


# ------------------------------------------------------------------ players

## The players' places come to the table: the others slide in from the left
## edge one after another, your panel and the turn clock rise from the bottom.
func arrive() -> void:
	modulate.a = 1.0
	var tw := create_tween().set_parallel(true)
	for i in seats.size():
		var v := seats[i]
		var x := v.position.x
		v.position.x = x - v.size.x - 60.0 * s
		tw.tween_property(v, "position:x", x, 0.5).set_delay(i * 0.09).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	for c in [me_view, clock]:
		var y: float = c.position.y
		c.position.y = y + c.size.y + 120.0 * s
		tw.tween_property(c, "position:y", y, 0.55).set_delay(0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	await tw.finished


func update_opponent(i: int) -> void:
	if i >= 0 and i < seats.size():
		seats[i].refresh(true)


func update_me() -> void:
	if me_view:
		me_view.refresh(true)


# ------------------------------------------------------------------ turn + clock

func set_turn(t: int, run := true) -> void:
	turn = t
	turn_started = Time.get_ticks_msec() / 1000.0
	timer_running = run
	_time_up_sent = false
	_tick_sec = -1
	_show_turn()


func stop_timer() -> void:
	timer_running = false


func _show_turn() -> void:
	if me_view == null:
		return
	me_view.set_active(turn == 0)
	for i in seats.size():
		seats[i].set_active(turn == i + 1)
	show_seat(turn - 1)
	if _round:
		_round.text = L.t("round", round_no)
	_stop_after_round()


func _process(_delta: float) -> void:
	if not timer_running or me_view == null:
		return
	var t := Time.get_ticks_msec() / 1000.0
	var left := maxf(TURN_SECONDS - (t - turn_started), 0.0)
	if clock:
		clock.set_time(left / TURN_SECONDS, left)
	var sec := ceili(left)
	if turn == 0 and sec > 0 and sec <= 10 and sec != _tick_sec:
		_tick_sec = sec
		Sfx.play("clock_tick")
	if left <= 0.0 and not _time_up_sent:
		_time_up_sent = true
		time_up.emit()


# ------------------------------------------------------------------ anchors (screen px)

func opponent_anchor(i: int) -> Vector2:
	return _seat_pt(seats[i].portrait_point()) if i >= 0 and i < seats.size() else lay.screen(Vector2(300, 540))


func me_anchor() -> Vector2:
	return me_view.portrait_point()


func me_score_anchor() -> Vector2:
	return me_view.score_point()


func me_token_anchor(col: String) -> Vector2:
	return me_view.token_point(col)


func me_card_anchor(col: String) -> Vector2:
	return me_view.card_point(col)


func me_reserve_anchor() -> Vector2:
	return me_view.reserve_point()


func seat_token_anchor(i: int, col: String) -> Vector2:
	return _seat_pt(seats[i].token_point(col)) if i >= 0 and i < seats.size() else opponent_anchor(i)


func seat_card_anchor(i: int, col: String) -> Vector2:
	return _seat_pt(seats[i].card_point(col)) if i >= 0 and i < seats.size() else opponent_anchor(i)


func seat_reserve_anchor(i: int) -> Vector2:
	return _seat_pt(seats[i].reserve_point()) if i >= 0 and i < seats.size() else opponent_anchor(i)


func opponent_at(sp: Vector2) -> int:
	if _col and not _col.get_global_rect().has_point(sp):
		return -1  # outside the column: no seat scrolled out of view answers
	for i in seats.size():
		if Rect2(seats[i].global_position, seats[i].size).has_point(sp):
			return i
	return -1


## Your portrait / score: your sheet. The reserve stack: your reserved cards.
func me_at(sp: Vector2) -> bool:
	return Rect2(me_view.global_position + Vector2(0, 90) * s, Vector2(700, 160) * s).has_point(sp)


func reserve_at(sp: Vector2) -> bool:
	return me_view.reserve_rect().has_point(sp)


func is_modal() -> bool:
	return (modal != null and is_instance_valid(modal)) or Time.get_ticks_msec() / 1000.0 - modal_closed_at < 0.15


func set_dim(a: float) -> void:
	var k := 1.0 - a * 0.55
	for v in seats:
		v.modulate = Color(k, k, k)
	if me_view:
		me_view.modulate = Color(k, k, k)


# ------------------------------------------------------------------ messages

func toast(text: String) -> void:
	if _toast and is_instance_valid(_toast):
		_toast.queue_free()
	var w := 1100.0
	var h := 100.0
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_put(_root, c, Vector2(_cx() - w * 0.5, 120), Vector2(w, h))
	c.add_child(Kit.plate("onyx", c.size))
	_text(c, text, TS.BODY, Kit.GOLD, "serif_bold", Vector2(w * 0.12, (h - TS.BODY * 1.6) * 0.5), w * 0.76)
	_toast = c
	c.modulate.a = 0.0
	var tw := c.create_tween()
	tw.tween_property(c, "modulate:a", 1.0, 0.15)
	tw.tween_interval(2.0)
	tw.tween_property(c, "modulate:a", 0.0, 0.35)
	tw.tween_callback(c.queue_free)


## A big line across the middle ("Your turn"): your turns on an emerald
## plate, the others on onyx.
func banner(text: String, mine: bool) -> void:
	var w := 980.0
	var h := 180.0
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_put(_root, c, Vector2(_cx(), CENTER.y) - Vector2(w, h) * 0.5, Vector2(w, h))
	c.add_child(Kit.plate("emerald" if mine else "onyx", c.size))
	_text(c, text, TS.BANNER, Kit.GOLD, "title_bold", Vector2(w * 0.1, (h - TS.BANNER * 1.6) * 0.5),
			w * 0.8, HORIZONTAL_ALIGNMENT_CENTER, 4.0)
	c.pivot_offset = c.size * 0.5
	c.scale = Vector2(0.6, 0.6)
	c.modulate.a = 0.0
	var tw := c.create_tween()
	tw.set_parallel(true)
	tw.tween_property(c, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(c, "modulate:a", 1.0, 0.2)
	tw.chain().tween_interval(0.9)
	tw.chain().tween_property(c, "modulate:a", 0.0, 0.3)
	tw.chain().tween_callback(c.queue_free)


## Who did what, on a sapphire plate while a card passes through the middle.
func announce(line1: String, line2: String, mine: bool, dur := 1.6) -> void:
	if _announce and is_instance_valid(_announce):
		_announce.queue_free()
	# the plate's frame takes about 30 px top and bottom: both lines sit inside its band
	var w := 1120.0
	var h := 236.0
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_put(_root, c, Vector2(_cx() - w * 0.5, 90), Vector2(w, h))
	c.add_child(Kit.plate("emerald" if mine else "sapphire", c.size))
	_text(c, line1, TS.BODY, Kit.IVORY, "serif_bold", Vector2(w * 0.12, 40), w * 0.76)
	_text(c, line2, TS.TITLE * 0.92, Kit.GOLD, "title_bold", Vector2(w * 0.12, 94), w * 0.76, HORIZONTAL_ALIGNMENT_CENTER, 3.0)
	_announce = c
	c.modulate.a = 0.0
	c.position.y -= 20.0 * s
	var tw := c.create_tween()
	tw.set_parallel(true)
	tw.tween_property(c, "modulate:a", 1.0, 0.2)
	tw.tween_property(c, "position:y", c.position.y + 20.0 * s, 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(dur)
	tw.chain().tween_property(c, "modulate:a", 0.0, 0.3)
	tw.chain().tween_callback(c.queue_free)


# ------------------------------------------------------------------ dialogs

func _open_modal(size_d: Vector2, closable := true, title := "") -> Control:
	close_modal()
	var cover := Control.new()
	cover.set_anchors_preset(Control.PRESET_FULL_RECT)
	cover.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(cover)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0.02, 0.62)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover.add_child(shade)
	var box := Kit.dialog(size_d * s, title, closable)
	box.position = lay.screen(Vector2(lay.size.x * 0.5, 560)) - box.size * 0.5
	box.position.y = maxf(box.position.y, float(box.get_meta("above")) + 8.0 * s)
	if closable:
		(box.get_meta("close_button") as Button).pressed.connect(close_modal)
	cover.add_child(box)
	if closable:
		cover.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and not (e as InputEventMouseButton).pressed \
					and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				close_modal())
	modal = cover
	cover.modulate.a = 0.0
	box.pivot_offset = box.size * 0.5
	box.scale = Vector2.ONE * 0.92
	var tw := cover.create_tween().set_parallel(true)
	tw.tween_property(cover, "modulate:a", 1.0, 0.16)
	tw.tween_property(box, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return box


## The space under a dialog's crest: content is placed in this (design px).
const HEAD := 80.0


func _content(box: Control) -> Control:
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.position = Vector2(0, HEAD * s)
	c.size = box.size - Vector2(0, HEAD * s)
	box.add_child(c)
	return c


func close_modal() -> void:
	if modal and is_instance_valid(modal):
		var m := modal
		modal = null
		modal_closed_at = Time.get_ticks_msec() / 1000.0
		m.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tw := m.create_tween()
		tw.tween_property(m, "modulate:a", 0.0, 0.14)
		tw.tween_callback(m.queue_free)


## The server is not answering: a dialog that cannot be closed, a gem that
## turns while the game tries again, and a way out that keeps your seat.
func connection_lost(on_leave: Callable) -> void:
	var size_d := Vector2(1100, 560)
	var dlg := _open_modal(size_d + Vector2(0, HEAD), false, L.t("conn_lost"))
	modal.process_mode = Node.PROCESS_MODE_ALWAYS  # the table is paused underneath
	var box := _content(dlg)
	var gem := Kit.gem("blue", 110.0 * s)
	gem.pivot_offset = gem.size * 0.5
	_put(box, gem, Vector2((size_d.x - 110.0) * 0.5, 30), Vector2(110, 110))
	var spin := gem.create_tween().set_loops()
	spin.tween_property(gem, "rotation", TAU, 1.6).from(0.0)
	var l := _para(box, L.t("conn_lost_body"), TS.BODY, IVORY, Vector2(70, 170), size_d.x - 140.0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var leave := button(L.t("conn_leave"), Vector2(440, 116), "onyx", func():
		close_modal()
		on_leave.call())
	_put(box, leave, Vector2((size_d.x - 440.0) * 0.5, size_d.y - 156.0), Vector2(440, 116))


## A game against the computer is paused: the table stands still underneath,
## a dialog that only Resume closes (a gem rests on it).
func pause_overlay(on_resume: Callable) -> void:
	var size_d := Vector2(1000, 520)
	var dlg := _open_modal(size_d + Vector2(0, HEAD), false, L.t("paused_t"))
	modal.process_mode = Node.PROCESS_MODE_ALWAYS  # the table is paused underneath
	var box := _content(dlg)
	_put(box, Kit.gem("green", 110.0 * s), Vector2((size_d.x - 110.0) * 0.5, 30), Vector2(110, 110))
	var l := _para(box, L.t("paused_body"), TS.BODY, IVORY, Vector2(70, 170), size_d.x - 140.0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var go := button(L.t("resume_btn"), Vector2(440, 124), "emerald", func():
		close_modal()
		on_resume.call(), 44.0)
	_put(box, go, Vector2((size_d.x - 440.0) * 0.5, size_d.y - 166.0), Vector2(440, 124))


func confirm(title: String, body: String, yes_text: String, on_yes: Callable) -> void:
	var size_d := Vector2(1100, 470)
	var box := _content(_open_modal(size_d + Vector2(0, HEAD), true, title))
	_para(box, body, TS.BODY, IVORY, Vector2(70, 50), size_d.x - 140.0)
	var yes := button(yes_text, Vector2(320, 116), "onyx", func():
		close_modal()
		on_yes.call())
	var no := button(L.t("cancel"), Vector2(280, 116), "ruby", close_modal)
	var x0 := (size_d.x - 320.0 - 280.0 - 40.0) * 0.5
	var y := size_d.y - 156.0
	if L.fa():
		_put(box, yes, Vector2(x0 + 320, y), Vector2(320, 116))
		_put(box, no, Vector2(x0, y), Vector2(280, 116))
	else:
		_put(box, yes, Vector2(x0, y), Vector2(320, 116))
		_put(box, no, Vector2(x0 + 360, y), Vector2(280, 116))


func show_menu(items: Array) -> void:
	var size_d := Vector2(820, 90 + items.size() * 132.0)
	var box := _content(_open_modal(size_d + Vector2(0, HEAD), true, L.t("menu")))
	for k in items.size():
		var it: Array = items[k]
		var cb: Callable = it[2]
		var b := button(String(it[0]), Vector2(660, 112), String(it[1]), func():
			close_modal()
			cb.call())
		_put(box, b, Vector2(80, 30 + k * 132.0), Vector2(660, 112))


func show_sheet(p: Dictionary, is_me: bool, nav := Callable()) -> void:
	var size_d := Vector2(1400, 640)
	var who := String(p["name"]) + ("  (%s)" % L.t("you") if is_me else "")
	var box := _content(_open_modal(size_d + Vector2(0, HEAD), true, who))
	var w := size_d.x
	var av := _avatar(String(p["portrait"]), 170.0)
	av.position = Vector2(_mx(60, 170, w), 40) * s
	box.add_child(av)
	_text(box, "%s: %d   ·   %s: %d" % [L.t("nobles"), int(p.get("nobles", 0)), L.t("reserved"), (p["reserved"] as Array).size()],
			TS.BODY, MUTED, "serif", Vector2(_mx(260, 640, w), 136), 640.0, _start())
	_text(box, str(int(p["prestige"])), TS.NUM_XL, GOLD, "num", Vector2(_mx(1040, 300, w), 48), 300.0,
			HORIZONTAL_ALIGNMENT_CENTER, 4.0)
	_text(box, L.t("prestige"), TS.BODY, MUTED, "serif", Vector2(_mx(1040, 300, w), 170), 300.0)
	for k in 6:
		var col: String = Gems.ALL[k]
		var x := 80.0 + k * 210.0
		_text(box, L.gem(col), TS.CAPTION, MUTED, "serif_bold", Vector2(x - 20, 262), 200.0)
		var tok := Gems.token_tex(col)
		if tok:
			var tr := TextureRect.new()
			tr.texture = tok
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_SCALE
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_put(box, tr, Vector2(x, 320), Vector2(96, 96))
		_text(box, str(int(p["coins"][col])), TS.NUM_M, IVORY, "num", Vector2(x + 100, 344), 70.0,
				HORIZONTAL_ALIGNMENT_LEFT, 5.0)
		if k < 5:
			var g := Gems.gem_tex(col)
			if g:
				var gr := TextureRect.new()
				gr.texture = g
				gr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				gr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
				gr.mouse_filter = Control.MOUSE_FILTER_IGNORE
				_put(box, gr, Vector2(x + 8, 440), Vector2(80, 80))
			_text(box, str(int(p["cards"][col])), TS.NUM_M, GOLD_LIGHT, "num", Vector2(x + 100, 456), 70.0,
					HORIZONTAL_ALIGNMENT_LEFT, 5.0)
	if nav.is_valid():
		_nav_arrows(box, size_d, nav)


## Several nobles would visit you at once: their portraits side by side,
## tap the one you want (Splendor: one per turn, the player chooses; the
## others may come on a later turn). Cannot be closed without a choice.
signal noble_chosen(index: int)


func choose_noble(list: Array) -> void:
	var cell := 380.0
	var size_d := Vector2(maxf(cell * list.size() + 120.0, 1000.0), 640)
	var box := _content(_open_modal(size_d + Vector2(0, HEAD), false, L.t("choose_noble")))
	_text(box, L.t("choose_noble_sub"), TS.BODY, MUTED, "serif", Vector2(60, 20), size_d.x - 120.0)
	var x0 := (size_d.x - cell * list.size()) * 0.5
	for k in list.size():
		var nd: Dictionary = list[k]
		var i := list.size() - 1 - k if L.fa() else k
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		Kit._empty_styles(b)
		_put(box, b, Vector2(x0 + i * cell + 20, 90), Vector2(cell - 40, 470))
		var t := Gems.noble_tex(String(nd["id"]))
		if t:
			var tr := TextureRect.new()
			tr.texture = t
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			tr.size = Vector2(cell - 40, cell - 40) * s
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			b.add_child(tr)
		_text(b, L.t("noble_" + String(nd["id"])), TS.LABEL, GOLD, "serif_bold", Vector2(0, cell - 30), cell - 40.0)
		_text(b, "+3 %s" % L.t("prestige"), TS.BODY, IVORY, "serif", Vector2(0, cell + 20), cell - 40.0)
		Kit.feedback(b)
		var idx := k
		b.pressed.connect(func():
			close_modal()
			noble_chosen.emit(idx))


func _nav_arrows(box: Control, size_d: Vector2, nav: Callable) -> void:
	var d := 100.0 * s
	var prev := Kit.round_button("arrow", d, "onyx", true)
	var next := Kit.round_button("arrow", d)
	prev.pressed.connect(func(): nav.call(-1))
	next.pressed.connect(func(): nav.call(1))
	prev.position = Vector2(30, size_d.y - 130) * s
	next.position = Vector2(size_d.x - 130, size_d.y - 130) * s
	box.add_child(prev)
	box.add_child(next)


func show_noble(nd: Dictionary, have: Dictionary, owner: String, nav := Callable()) -> void:
	var size_d := Vector2(1300, 600)
	var box := _content(_open_modal(size_d + Vector2(0, HEAD), true, L.t("noble_" + String(nd["id"]))))
	var w := size_d.x
	var pic := Control.new()
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_put(box, pic, Vector2(_mx(46, 420, w), 46), Vector2(420, 420))
	var t := Gems.noble_tex(String(nd["id"]))
	if t:
		var tr := TextureRect.new()
		tr.texture = t
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr.size = pic.size
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pic.add_child(tr)
	var tx := _mx(510, 740, w)
	_text(box, "+3 %s" % L.t("prestige"), TS.LABEL, GOLD, "serif_bold", Vector2(tx, 128), 740.0, _start())
	_text(box, L.t("noble_needs", int(nd["need"])), TS.BODY, MUTED, "serif", Vector2(tx, 190), 740.0, _start())
	var reqs: Array = nd["reqs"]
	for k in reqs.size():
		var col: String = reqs[k]
		var x := _mx(510 + k * 240.0, 220, w)
		var got := int(have.get(col, 0))
		var need := int(nd["need"])
		var g := Gems.gem_tex(col)
		if g:
			var gr := TextureRect.new()
			gr.texture = g
			gr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			gr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			gr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_put(box, gr, Vector2(x, 260), Vector2(96, 96))
			if got < need:
				gr.modulate = Color(0.7, 0.7, 0.7, 0.85)
		_text(box, "%d/%d" % [mini(got, need), need], TS.NUM_M, IVORY if got < need else Color(0.6, 1.0, 0.6), "num",
				Vector2(x + 100, 282), 120.0, HORIZONTAL_ALIGNMENT_LEFT, 5.0)
	_text(box, L.t("noble_with", owner) if owner != "" else L.t("noble_free"), TS.LABEL, IVORY, "serif_bold",
			Vector2(tx, 400), 740.0, _start())
	if nav.is_valid():
		_nav_arrows(box, size_d, nav)


func show_results(rows: Array, title: String, mine_won: bool, on_again: Callable, on_menu: Callable) -> void:
	# one row per player on the painted row art: everything sits inside its
	# dark band, between the gem caps at the ends; the column titles are
	# written once, above the rows
	# five or six players (a friends' room): smaller rows, the same height as four
	var k5: float = 1.0 if rows.size() <= 4 else (0.75 if rows.size() == 5 else 0.66)
	var row_h := 112.0 * k5
	var step := 128.0 * k5
	var size_d := Vector2(1500, 250 + rows.size() * step)
	var box := _content(_open_modal(size_d + Vector2(0, HEAD), false, title))
	var w := size_d.x
	var rw := w - 120.0
	var cap := row_h / 127.0 * 118.0  # the gem cap at each end of the row art
	var col_pts := rw - cap - 330.0
	var col_cards := rw - cap - 170.0
	var num_px := TS.NUM_M * k5
	var name_px := TS.LABEL * (1.0 if k5 == 1.0 else 0.85)
	_text(box, L.t("results_power"), TS.CAPTION, MUTED, "serif_bold", Vector2(60 + _mx(col_pts, 150, rw), 24), 150.0)
	_text(box, L.t("results_cards"), TS.CAPTION, MUTED, "serif_bold", Vector2(60 + _mx(col_cards, 150, rw), 24), 150.0)
	for k in rows.size():
		var r: Dictionary = rows[k]
		var mine: bool = r.get("me", false)
		var row := Control.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_put(box, row, Vector2(60, 70 + k * step), Vector2(rw, row_h))
		row.add_child(Kit.row(Vector2(rw, row_h) * s, mine))
		var ink: Color = Kit.INK_DARK if mine else IVORY
		var mid := row_h * 0.5
		# place: a medal for the first three, else the number
		var medal := Kit.tex("medal_%d" % (k + 1)) if k < 3 else null
		var rx := cap + 6.0
		if medal:
			var m := TextureRect.new()
			m.texture = medal
			m.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			m.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			m.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_put(row, m, Vector2(_mx(rx, 76, rw), mid - 38 * k5), Vector2(76, 76) * k5)
		else:
			_text(row, str(k + 1), num_px, ink, "num", Vector2(_mx(rx, 76, rw), mid - num_px * 0.8), 76.0)
		var ad := 80.0 * k5
		var av := _avatar(String(r["portrait"]), ad)
		av.position = Vector2(_mx(rx + 90, ad, rw), mid - ad * 0.5) * s
		row.add_child(av)
		var nx := rx + 190.0
		var nw := col_pts - nx - 20.0
		_text(row, String(r["name"]), name_px, ink, "serif_bold", Vector2(_mx(nx, nw, rw), mid - name_px * 0.8), nw, _start())
		_text(row, "%d" % int(r["power"]), num_px, GOLD if not mine else ink, "num",
				Vector2(_mx(col_pts, 150, rw), mid - num_px * 0.8), 150.0)
		_text(row, "%d" % int(r["cards"]), num_px, ink, "num", Vector2(_mx(col_cards, 150, rw), mid - num_px * 0.8), 150.0)
	var again := button(L.t("play_again"), Vector2(380, 116), "emerald", func():
		close_modal()
		on_again.call())
	var menu := button(L.t("menu"), Vector2(300, 116), "dark", func():
		close_modal()
		on_menu.call())
	var y2 := size_d.y - 140.0
	var x0 := (w - 380.0 - 300.0 - 40.0) * 0.5
	_put(box, again, Vector2(x0 + (340.0 if L.fa() else 0.0), y2), Vector2(380, 116))
	_put(box, menu, Vector2(x0 + (0.0 if L.fa() else 420.0), y2), Vector2(300, 116))


## Test (store videos): `--stop-after-round=N` closes the app a moment after
## round N is over, so a recording ends there.
var _stopping := false

func _stop_after_round() -> void:
	if _stopping:
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--stop-after-round=") and round_no > int(a.get_slice("=", 1)):
			_stopping = true
			print("VIDEOMARK round %d frame=%d" % [round_no, Engine.get_frames_drawn()])
			await get_tree().create_timer(2.5).timeout
			SavedGame.clear()  # the next recording starts clean
			get_tree().quit()
