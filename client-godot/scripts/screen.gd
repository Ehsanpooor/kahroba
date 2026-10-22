class_name Screen
extends Control
## One full-screen page outside the board, landscape and mobile first: the
## design is 2400 x 1080 "design px" (a 20:9 phone), fitted whole into the
## window and centred. Everything is drawn with the gem kit (Kit). Subclasses
## draw themselves in build(), which runs again when the window changes size.

signal go(screen: String, arg: Variant)  ## open another screen
signal back  ## return to the previous screen
signal play(game: Dictionary)  ## start a game

const D := Vector2(2400, 1080)

var u := 1.0  # screen px per design px
var vp := Vector2.ZERO
var origin := Vector2.ZERO
var arg: Variant = null  # what the opener passed
var _dialog: Control
var _note: Control
var _pin_key := Callable()  ## a hardware key, while a dialog with a keypad is open


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	get_viewport().size_changed.connect(_rebuild)
	_rebuild()


func _rebuild() -> void:
	vp = get_viewport().get_visible_rect().size
	position = Vector2.ZERO
	size = vp
	u = minf(vp.x / D.x, vp.y / D.y)
	origin = (vp - D * u) * 0.5
	for c in get_children():
		c.queue_free()
	_dialog = null
	build()


## Draw the screen. Overridden.
func build() -> void:
	pass


## Back button / Escape: closes an open dialog first. True when handled.
func on_back() -> bool:
	if _dialog and is_instance_valid(_dialog):
		close_dialog()
		return true
	return false


# ------------------------------------------------------------------ placing (design px)

func px(p: Vector2) -> Vector2:
	return origin + p * u


## Place `c` with its top-left at design `pos`, `sz` in design px.
func put(c: Control, pos: Vector2, sz: Vector2, parent: Node = null) -> Control:
	c.position = px(pos) if parent == null or parent == self else pos * u
	c.size = sz * u
	(parent if parent else self).add_child(c)
	return c


## Place an already-sized control with its top-left at design `pos`.
func put_at(c: Control, pos: Vector2, parent: Node = null) -> Control:
	c.position = px(pos) if parent == null or parent == self else pos * u
	(parent if parent else self).add_child(c)
	return c


## A label in a design-px box (Kit look), optically centred vertically.
func text(t: String, px_: float, color: Color, kind: String, box: Rect2, align := HORIZONTAL_ALIGNMENT_CENTER,
		parent: Node = null) -> Label:
	var l := Kit.label(t, px_ * u, color, kind, box.size.x * u, align)
	var at := px(box.position) if parent == null or parent == self else box.position * u
	l.size = box.size * u
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.position = at - Vector2(0, float(l.get_meta("shift", 0.0)))
	(parent if parent else self).add_child(l)
	return l


func start_align() -> int:
	return HORIZONTAL_ALIGNMENT_RIGHT if L.fa() else HORIZONTAL_ALIGNMENT_LEFT


## Mirror a design x for right-to-left (a box of width `w` inside [0, total]).
func mx(x: float, w: float, total := D.x) -> float:
	return total - x - w if L.fa() else x


# ------------------------------------------------------------------ backdrop + title

## The backdrop: the painted menu hall or the plain leather screen, covering
## the whole window, darkened by `dim`.
## The screen's painted background. `mirror` flips it left to right (the
## menu in Persian, whose buttons sit on the other side).
func backdrop(name := "screen_bg", dim := 0.0, mirror := false) -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.04, 0.035)
	bg.size = vp
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var t := Kit.tex(name)
	if t == null:
		var hall := Kit.tex("menu_bg")
		t = hall if hall else _fallback_bg(name)
	if t:
		var tr := TextureRect.new()
		tr.texture = t
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr.size = vp
		tr.flip_h = mirror
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(tr)
	if dim > 0.0:
		var sh := ColorRect.new()
		sh.color = Color(0.0, 0.01, 0.0, dim)
		sh.size = vp
		sh.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(sh)


## Until the painted backdrops exist: the table's leather, or the old hall.
func _fallback_bg(name: String) -> Texture2D:
	var p := "res://assets/splendor/hud/table.png" if name == "screen_bg" else "res://assets/ui/menu_bg.jpg"
	return Tex.get_tex(p) if ResourceLoader.exists(p) else null


## The standard top: the painted back button, and the title on the sapphire
## ribbon (or the dialog crest's plaque until the ribbon exists).
func title_bar(title: String) -> void:
	var b := Kit.back_button(130.0 * u)
	put_at(b, Vector2(mx(36, 130), 26))
	b.pressed.connect(func(): back.emit())
	var ribbon := Kit.tex("title_ribbon")
	if ribbon:
		var w := 1100.0
		var h := w * ribbon.get_height() / ribbon.get_width()
		var r := TextureRect.new()
		r.texture = ribbon
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_SCALE
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		put(r, Vector2((D.x - w) * 0.5, 10), Vector2(w, h))
		text(title, TS.BANNER, Kit.GOLD, "title_bold", Rect2((D.x - w * 0.6) * 0.5, 10, w * 0.6, h * 0.86))
	else:
		var hd := Kit.header(1100.0 * u, title, 0.0)
		put_at(hd, Vector2((D.x - 1100.0) * 0.5, -60))


# ------------------------------------------------------------------ dialogs

## A modal dialog over the screen. Returns the dialog box; its content rect
## (screen px, relative to the box) is box.get_meta("content").
func dialog(sz: Vector2, title: String, closable := true) -> Control:
	close_dialog()
	var cover := Control.new()
	cover.size = vp
	cover.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(cover)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0.01, 0.66)
	shade.size = vp
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover.add_child(shade)
	var box := Kit.dialog(sz * u, title, closable)
	box.position = px(D * 0.5 + Vector2(0, 30)) - box.size * 0.5
	box.position.y = maxf(box.position.y, float(box.get_meta("above")) + 8.0 * u)
	cover.add_child(box)
	if closable:
		(box.get_meta("close_button") as Button).pressed.connect(close_dialog)
		cover.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and not (e as InputEventMouseButton).pressed \
					and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				close_dialog())
	_dialog = cover
	cover.modulate.a = 0.0
	box.pivot_offset = box.size * 0.5
	box.scale = Vector2.ONE * 0.92
	var tw := cover.create_tween().set_parallel(true)
	tw.tween_property(cover, "modulate:a", 1.0, 0.16)
	tw.tween_property(box, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	return box


func close_dialog() -> void:
	_pin_key = Callable()
	if _dialog and is_instance_valid(_dialog):
		var d := _dialog
		_dialog = null
		d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tw := d.create_tween()
		tw.tween_property(d, "modulate:a", 0.0, 0.14)
		tw.tween_callback(d.queue_free)


## A dialog with a message and buttons ([text, style, callable] each), sized
## to fit its text: nothing ever runs under the buttons.
func message(title: String, body: String, buttons: Array, width := 1300.0) -> Control:
	var px := TS.LABEL
	var text_w := width * 0.8
	var font := Fonts.get_font("serif")
	var th: float = font.get_multiline_string_size(body, HORIZONTAL_ALIGNMENT_CENTER, text_w * u, int(px * u)).y / u
	var bh := 128.0
	# crest overlap + text + gap + buttons + footer room
	var h := 150.0 + th + 70.0 + bh + 90.0
	var box := dialog(Vector2(width, h), title)
	var r: Rect2 = box.get_meta("content")
	var p := Kit.para(body, px * u, text_w * u)
	p.position = Vector2((box.size.x - text_w * u) * 0.5, r.position.y + 10.0 * u)
	box.add_child(p)
	var bw := 460.0
	var gap := 50.0
	var total := buttons.size() * bw + (buttons.size() - 1) * gap
	var order := buttons.duplicate()
	if L.fa():
		order.reverse()
	for i in order.size():
		var it: Array = order[i]
		var b := Kit.button(it[0], Vector2(bw, bh) * u, it[1], "", 44.0 * u)
		b.position = Vector2((box.size.x / u - total) * 0.5 + i * (bw + gap), r.position.y / u + th + 80.0) * u
		var cb: Callable = it[2]
		b.pressed.connect(func():
			close_dialog()
			cb.call())
		box.add_child(b)
	return box


## Put a control into a dialog box at design `pos` (relative to the content rect).
func in_dialog(box: Control, c: Control, pos: Vector2, sz := Vector2.ZERO) -> Control:
	var r: Rect2 = box.get_meta("content")
	if sz != Vector2.ZERO:
		c.size = sz * u
	c.position = r.position + pos * u
	box.add_child(c)
	return c


func dialog_text(box: Control, t: String, px_: float, color: Color, kind: String, rect: Rect2,
		align := HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := Kit.label(t, px_ * u, color, kind, rect.size.x * u, align)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	in_dialog(box, l, rect.position, rect.size)
	l.position.y -= float(l.get_meta("shift", 0.0))
	return l


## The content width of a dialog, in design px.
func dialog_w(box: Control) -> float:
	return (box.get_meta("content") as Rect2).size.x / u


## A six-digit code typed on keys drawn in the dialog (the phone's keyboard
## would cover it): six places on an ivory plate at `slots` (design px in the
## content rect), the keypad 1-9, Paste, 0, Delete in the column at `key_x`
## (`key_w` wide). Digits always read left to right; an empty place shows a
## faint dot. A hardware keyboard types too. `on_change(code, note)` runs
## after every change (note: a line to show, or ""), `on_enter(code)` on
## Enter. Returns the state: read and set "code", then call ["show"].
func pin_pad(box: Control, slots_at: Rect2, key_x: float, key_w: float, on_change: Callable,
		on_enter: Callable) -> Dictionary:
	var st := {"code": ""}
	var field := Kit.tex("input_field")
	if field:
		in_dialog(box, Kit.strip(field, slots_at.size * u, 0.08), slots_at.position)
	var slots: Array[Label] = []
	var cell := 78.0
	var inner := cell * 6 + 40.0
	for k in 6:
		var x := slots_at.position.x + (slots_at.size.x - inner) * 0.5 + k * cell + (40.0 if k >= 3 else 0.0)
		slots.append(dialog_text(box, "", TS.NUM_L, Kit.INK_DARK, "num", Rect2(x, slots_at.position.y, cell, slots_at.size.y)))
	var show := func():
		var c: String = st["code"]
		for k in 6:
			var has: bool = k < c.length()
			slots[k].text = c[k] if has else "·"
			slots[k].modulate.a = 1.0 if has else 0.35
	st["show"] = show
	var fa_digits := "۰۱۲۳۴۵۶۷۸۹"
	var add_text := func(t: String):
		for ch in t:
			if String(st["code"]).length() >= 6:
				break
			if ch >= "0" and ch <= "9":
				st["code"] += ch
			elif fa_digits.contains(ch):
				st["code"] += str(fa_digits.find(ch))
		show.call()
		on_change.call(st["code"], "")
	var press := func(key: String):
		match key:
			"del":
				var c: String = st["code"]
				st["code"] = c.left(maxi(c.length() - 1, 0))
				show.call()
				on_change.call(st["code"], "")
			"paste":
				st["code"] = ""
				add_text.call(DisplayServer.clipboard_get())
				if String(st["code"]).is_empty():
					on_change.call("", L.t("paste_none"))
			"enter":
				on_enter.call(st["code"])
			_:
				add_text.call(key)
	var key := Vector2(164, 124)
	var gap := Vector2(22, 14)
	var keys := ["1", "2", "3", "4", "5", "6", "7", "8", "9", "paste", "0", "del"]
	var kw := key.x * 3 + gap.x * 2
	var kx0 := key_x + (key_w - kw) * 0.5
	for k in keys.size():
		var kname: String = keys[k]
		var pos := Vector2(kx0 + (k % 3) * (key.x + gap.x), 10 + (k / 3) * (key.y + gap.y))
		var b: Button
		if kname == "del":
			b = Kit._art_button(Kit.tex("btn_arrow_left"), key.y * u)
			in_dialog(box, b, pos + Vector2((key.x - key.y) * 0.5, 0))
		else:
			b = Button.new()
			b.focus_mode = Control.FOCUS_NONE
			Kit._empty_styles(b)
			b.size = key * u
			var art := Kit.tex("btn_square_onyx")
			if art:
				var tr := TextureRect.new()
				tr.texture = art
				tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tr.stretch_mode = TextureRect.STRETCH_SCALE
				tr.size = b.size
				tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
				b.add_child(tr)
			var paste := kname == "paste"
			var lab := Kit.label(L.t("paste") if paste else kname, (TS.BODY if paste else TS.NUM_L) * u, Kit.GOLD,
					"sans_bold" if paste else "num", b.size.x)
			lab.size = b.size
			lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			lab.position.y -= float(lab.get_meta("shift", 0.0))
			b.add_child(lab)
			Kit.feedback(b)
			in_dialog(box, b, pos)
		b.pressed.connect(press.bind(kname))
	show.call()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pin="):  # test: type a code on the keypad
			for ch in a.get_slice("=", 1):
				press.call(ch)
	_pin_key = func(e: InputEventKey):
		if e.keycode == KEY_BACKSPACE:
			press.call("del")
		elif e.keycode == KEY_ENTER or e.keycode == KEY_KP_ENTER:
			press.call("enter")
		elif e.keycode == KEY_V and e.ctrl_pressed:
			press.call("paste")
		elif e.unicode > 0:
			add_text.call(char(e.unicode))
	return st


func _unhandled_key_input(e: InputEvent) -> void:
	if _pin_key.is_valid() and e is InputEventKey and (e as InputEventKey).pressed and _dialog != null:
		_pin_key.call(e)
		get_viewport().set_input_as_handled()


# ------------------------------------------------------------------ scrolling lists

## A vertical scroll area over a design-px rect; add children with add_in().
func scroll_area(r: Rect2) -> Control:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	sc.position = px(r.position)
	sc.size = r.size * u
	sc.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(sc)
	var content := Control.new()
	content.mouse_filter = Control.MOUSE_FILTER_PASS
	content.custom_minimum_size = Vector2(r.size.x * u, 10)
	sc.add_child(content)
	return content


## Put a control into scroll content at design `pos` (top-left).
func add_in(content: Control, c: Control, pos: Vector2, sz := Vector2.ZERO) -> Control:
	if sz != Vector2.ZERO:
		c.size = sz * u
	c.position = pos * u
	content.add_child(c)
	content.custom_minimum_size.y = maxf(content.custom_minimum_size.y, c.position.y + c.size.y + 30.0 * u)
	_pass_touches(c)
	return c


func _pass_touches(c: Control) -> void:
	if c.mouse_filter == Control.MOUSE_FILTER_STOP and not (c is BaseButton) and not (c is Range):
		c.mouse_filter = Control.MOUSE_FILTER_PASS
	for ch in c.get_children():
		if ch is Control:
			_pass_touches(ch)


# ------------------------------------------------------------------ small parts

## One portrait to choose: chosen bright in its gold ring, others dimmed; one
## the rating has not opened yet is darker, with the rating that opens it.
func portrait_tile(pid: String, d: float, chosen: bool, rating: int, on_pick: Callable) -> Button:
	var open := Portraits.is_open(pid, rating)
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	Kit._empty_styles(b)
	var av := Kit.avatar(pid, d * u)
	b.size = av.size
	b.add_child(av)
	if chosen:
		var g := Kit.gem("green", d * 0.3 * u)
		g.position = Vector2(av.size.x - g.size.x * 0.9, av.size.y - g.size.y * 0.9)
		b.add_child(g)
	else:
		av.modulate = Color(0.6, 0.6, 0.62) if open else Color(0.22, 0.22, 0.24)
	if not open:
		var need := Portraits.rating_for(int(pid.substr(2)))
		var l := Kit.label(str(need), TS.NUM_S * u, Kit.GOLD, "num", d * u)
		l.size = av.size
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.position.y -= float(l.get_meta("shift", 0.0))
		b.add_child(l)
	Kit.feedback(b)
	b.pressed.connect(func():
		if open:
			on_pick.call(pid)
		else:
			note(L.t("unlock_at", Portraits.rating_for(int(pid.substr(2))))))
	return b


## A short message near the bottom that fades away.
func note(t: String) -> void:
	if _note and is_instance_valid(_note):
		_note.queue_free()
	var w := 1200.0
	var h := 110.0
	var c := Control.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	put(c, Vector2((D.x - w) * 0.5, D.y - h - 40), Vector2(w, h))
	c.add_child(Kit.plate("onyx", c.size))
	text(t, TS.BODY, Kit.GOLD, "serif_bold", Rect2(w * 0.12, 0, w * 0.76, h), HORIZONTAL_ALIGNMENT_CENTER, c)
	_note = c
	var tw := c.create_tween()
	tw.tween_interval(2.0)
	tw.tween_property(c, "modulate:a", 0.0, 0.4)
	tw.tween_callback(c.queue_free)
