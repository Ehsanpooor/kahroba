class_name Tutorial
extends CanvasLayer
## The first-game tutorial, played on the real table against Cosimo the Guide.
## Cosimo speaks from a painted dialog; everything is dimmed and locked except
## the one thing to tap, lit with a pulsing gold frame. Steps move on when
## the board reports the move was made. Skip at any time.

var board: Node
var shade: Shade
var bubble: Control
var target_fn := Callable()  # -> Rect2 on screen, or Rect2() for nothing lit
var allowed := Callable()  # board target -> bool
var _events: Array = []
var _next := false
var _s := 1.0  # screen px per table design px
## Test: plays itself (--tutauto), doing each lit tap after a moment.
var auto := OS.get_cmdline_user_args().has("--tutauto")
var _action := Callable()
var _action_at := 0.0


## The dimmed screen with one lit hole. Touches inside the hole go through to
## the board and buttons; everything else is held here.
class Shade:
	extends Control
	var hole := Rect2()
	var dim := 0.62
	var pass_all := false
	var t := 0.0

	func _has_point(p: Vector2) -> bool:
		if pass_all:
			return false
		return not (hole.size != Vector2.ZERO and hole.grow(4.0).has_point(p))

	func _process(delta: float) -> void:
		t += delta
		queue_redraw()

	func _draw() -> void:
		var c := Color(0.0, 0.0, 0.02, dim)
		if hole.size == Vector2.ZERO:
			draw_rect(Rect2(Vector2.ZERO, size), c)
			return
		var h := hole
		draw_rect(Rect2(0, 0, size.x, h.position.y), c)
		draw_rect(Rect2(0, h.end.y, size.x, size.y - h.end.y), c)
		draw_rect(Rect2(0, h.position.y, h.position.x, h.size.y), c)
		draw_rect(Rect2(h.end.x, h.position.y, size.x - h.end.x, h.size.y), c)
		var a := 0.6 + 0.4 * sin(t * 4.0)
		var w := maxf(size.y / 260.0, 2.0)
		draw_rect(h.grow(w), Color(0.95, 0.76, 0.36, a), false, w)
		draw_rect(h.grow(w * 3.0), Color(0.95, 0.76, 0.36, a * 0.35), false, w)


func start(b: Node) -> void:
	board = b
	Analytics.event("tutorial_start")
	layer = 7
	var vp: Vector2 = board.get_viewport().get_visible_rect().size
	_s = board.layout.s
	shade = Shade.new()
	shade.size = vp
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(shade)
	var skip := Kit.button(L.t("tut_skip"), Vector2(360, 96) * _s, "onyx", "", 34.0 * _s)
	skip.position = board.layout.screen(Vector2(board.layout.right(1850.0), 20))
	skip.pressed.connect(_finish)
	add_child(skip)
	board.tut_event.connect(func(k: String, d: Variant): _events.append([k, d]))
	board.tut_gate = func(t: Variant) -> bool: return allowed.is_valid() and allowed.call(t)
	_run()


func _process(_delta: float) -> void:
	if shade == null or not is_inside_tree() or not is_instance_valid(board) or not board.is_inside_tree():
		return
	if auto and _action.is_valid() and Time.get_ticks_msec() / 1000.0 > _action_at:
		var a := _action
		_action = Callable()
		a.call()
	shade.hole = target_fn.call() if target_fn.is_valid() else Rect2()


# ------------------------------------------------------------------ the steps

func _run() -> void:
	while is_inside_tree() and (board.intro_running or board.turn != 0):
		await get_tree().process_frame
	await _say(L.t("t_hello"), L.t("tut_next"))
	await _say(L.t("t_board"), L.t("tut_next"))

	# 1. three different gems
	for col in ["white", "blue", "red"]:
		_say(L.t("t_take3", L.gem(col)))
		_light(func(): return _pile_rect(col), func(t): return t is ChipStack and (t as ChipStack).color == col,
				func(): board.take_coin(col))
		await _event("coin")
	_say(L.t("t_done"))
	_light(func(): return _btn(board.hud._stage["done"]), Callable(), func(): board.done_picking())
	await _event("coins_done")
	if not is_inside_tree():
		return
	await _orin_turn(L.t("t_orin1"))

	# 2. two of a kind
	for k in 2:
		_say(L.t("t_take2", L.gem("green"), "" if k == 0 else L.t("t_again")))
		_light(func(): return _pile_rect("green"), func(t): return t is ChipStack and (t as ChipStack).color == "green",
				func(): board.take_coin("green"))
		await _event("coin")
	_say(L.t("t_done"))
	_light(func(): return _btn(board.hud._stage["done"]), Callable(), func(): board.done_picking())
	await _event("coins_done")
	if not is_inside_tree():
		return
	await _orin_turn(L.t("t_orin2"))

	# 3. buy a card
	var card := func() -> Node: return board.cards[0]
	while is_inside_tree():  # skipping frees the tutorial: stop then
		_say(L.t("t_card"))
		_light(func(): return _card_rect(card.call()), func(t): return t == card.call(),
				func(): board.open_inspect(card.call()))
		await _event("inspect")
		_say(L.t("t_buy"))
		_light(func(): return _btn(board.hud._inspect["buy"]), Callable(), func(): board._on_buy_pressed())
		if await _event_or_closed("bought"):
			break
	if not is_inside_tree():
		return
	await _say(L.t("t_bonus"), L.t("tut_next"))
	await _orin_turn(L.t("t_orin3"))

	# 4. reserve
	while is_inside_tree():  # skipping frees the tutorial: stop then
		_say(L.t("t_any"))
		_light(func(): return _cards_rect(), func(t): return t is SCard, func(): board.open_inspect(board.cards[5]))
		await _event("inspect")
		_say(L.t("t_reserve"))
		_light(func(): return _btn(board.hud._inspect["reserve"]), Callable(), func(): board._on_reserve_pressed())
		if await _event_or_closed("reserved"):
			break
	if not is_inside_tree():
		return
	await _orin_turn(L.t("t_orin4"))

	if not is_inside_tree():
		return
	# 5. nobles
	_say(L.t("t_noble"))
	_light(func(): return _nobles_rect(), func(t): return t is NobleTile, func(): board._show_noble(0))
	await _event("noble_shown")
	_say(L.t("t_noble2"))
	target_fn = Callable()
	allowed = Callable()
	shade.pass_all = true
	shade.dim = 0.0
	if bubble:
		bubble.visible = false
	if auto:
		get_tree().create_timer(2.0).timeout.connect(func(): board.hud.close_modal())
	while is_inside_tree() and board.hud.is_modal():
		await get_tree().process_frame
	if not is_inside_tree():
		return
	shade.pass_all = false
	shade.dim = 0.62
	await _say(L.t("t_end"), L.t("tut_finish"))
	_finish(true)


func _orin_turn(text: String) -> void:
	_say(text)
	target_fn = Callable()
	allowed = Callable()
	shade.dim = 0.0  # watch the table; touches are still held
	await _event("turn", 0)
	shade.dim = 0.62


## Leave the tutorial: played to the end (`completed`), or skipped.
func _finish(completed := false) -> void:
	if completed:
		Analytics.event("tutorial_done")
	Prefs.set_v("tutorial_done", true)
	board.tut_gate = Callable()
	board._to_menu()


# ------------------------------------------------------------------ helpers

func _light(rect_fn: Callable, allow: Callable, action := Callable()) -> void:
	target_fn = rect_fn
	allowed = allow
	_action = action
	_action_at = Time.get_ticks_msec() / 1000.0 + 1.2
	_place_bubble.call_deferred()


func _event(kind: String, data: Variant = null) -> Variant:
	while is_inside_tree():
		for k in _events.size():
			var e: Array = _events[k]
			if e[0] == kind and (data == null or e[1] == data):
				_events = _events.slice(k + 1)
				return e[1]
		await get_tree().process_frame
	return null


## Wait for an event, or for the inspected card to be put back (false).
func _event_or_closed(kind: String) -> bool:
	_events.clear()
	while is_inside_tree():
		for e in _events:
			if e[0] == kind:
				_events.clear()
				return true
		if board.inspecting == null and board._busy == 0:
			return false
		await get_tree().process_frame
	return false


func _screen(p: Vector3) -> Vector2:
	return board.cam.unproject_position(p) if board.cam.is_inside_tree() else Vector2.ZERO


func _pile_rect(col: String) -> Rect2:
	var c := _screen((board.bank[col] as Node3D).global_position)
	var d := 110.0 * _s
	return Rect2(c - Vector2(d, d) * 0.5, Vector2(d, d))


func _card_rect(card: Node3D) -> Rect2:
	if card == null or not is_instance_valid(card) or not card.is_inside_tree():
		return Rect2()
	var c := _screen(card.global_position)
	var sz := Vector2(236, 172) * _s
	return Rect2(c - sz * 0.5, sz)


func _cards_rect() -> Rect2:
	var r := Rect2()
	for c in board.cards:
		if is_instance_valid(c) and c.visible:
			var cr := _card_rect(c)
			r = cr if r.size == Vector2.ZERO else r.merge(cr)
	return r


func _nobles_rect() -> Rect2:
	var r := Rect2()
	for n in board.nobles:
		if is_instance_valid(n) and n.visible:
			var c := _screen(n.global_position)
			var nr := Rect2(c - Vector2(85, 30) * _s, Vector2(170, 120) * _s)
			r = nr if r.size == Vector2.ZERO else r.merge(nr)
	return r


func _btn(c: Control) -> Rect2:
	if c == null or not is_instance_valid(c) or not c.is_visible_in_tree():
		return Rect2()
	return c.get_global_rect()


## Cosimo's words in a painted dialog: his portrait, the line, and a button
## when the step waits for a tap on it. Kept clear of what is lit.
func _say(text: String, button := "") -> void:
	if not is_inside_tree():
		return
	if bubble and is_instance_valid(bubble):
		bubble.queue_free()
	_next = false
	var w := 1180.0 * _s
	var px := TS.LABEL * _s
	var text_w := w - 300.0 * _s
	var text_h := Fonts.get_font("serif").get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT,
			text_w, int(px)).y
	var h := maxf(text_h + (230.0 if button != "" else 120.0) * _s, 280.0 * _s)
	bubble = Kit.dialog(Vector2(w, h), L.t("guide_name"), false)
	var r: Rect2 = bubble.get_meta("content")
	var av := Kit.avatar(Portraits.guide(), 200.0 * _s)
	av.position = Vector2(w - 230.0 * _s if L.fa() else 30.0 * _s, (h - 200.0 * _s) * 0.5)
	bubble.add_child(av)
	var p := Kit.para(text, px, text_w, Kit.IVORY, HORIZONTAL_ALIGNMENT_RIGHT if L.fa() else HORIZONTAL_ALIGNMENT_LEFT)
	p.position = Vector2(30.0 * _s if L.fa() else 250.0 * _s, r.position.y)
	bubble.add_child(p)
	if button != "":
		var b := Kit.button(button, Vector2(340, 104) * _s, "emerald", "", 38.0 * _s)
		b.position = Vector2(30.0 * _s if L.fa() else w - 370.0 * _s, h - 150.0 * _s)
		b.pressed.connect(func(): _next = true)
		bubble.add_child(b)
		if auto:
			get_tree().create_timer(1.6).timeout.connect(func(): _next = true)
	add_child(bubble)
	_place_bubble()
	bubble.modulate.a = 0.0
	bubble.create_tween().tween_property(bubble, "modulate:a", 1.0, 0.2)
	if button != "":
		target_fn = Callable()
		allowed = Callable()
		_place_bubble()
		while not _next and is_inside_tree():
			await get_tree().process_frame


## Centre of the table, or the half of the screen the lit thing is not on.
func _place_bubble() -> void:
	if bubble == null or not is_instance_valid(bubble) or not is_inside_tree():
		return
	var vp: Vector2 = board.get_viewport().get_visible_rect().size
	var r: Rect2 = target_fn.call() if target_fn.is_valid() else Rect2()
	var x: float = board.layout.screen(Vector2(board.layout.mid(1441.0), 0)).x - bubble.size.x * 0.5
	var above: float = bubble.get_meta("above")
	var y := (vp.y - bubble.size.y) * 0.5
	if r.size != Vector2.ZERO:
		y = above + 20.0 * _s if r.get_center().y > vp.y * 0.5 else vp.y - bubble.size.y - 40.0 * _s
		if r.intersects(Rect2(Vector2(x, y), bubble.size)):
			y = above + 20.0 * _s if y > vp.y * 0.4 else vp.y - bubble.size.y - 40.0 * _s
	bubble.position = Vector2(x, y)
