class_name UI
extends RefCounted
## Building blocks for the menu screens: bronze plates,
## gold titles, small blue gems. Each block uses the newest art that exists
## (the generated ui/ batch) and falls back to the older art, or to plain
## shapes. All sizes are screen px. Text is always fitted to its area.

const GOLD := Color(0.95, 0.75, 0.36)
const GOLD_LIGHT := Color(1.0, 0.9, 0.6)
const IVORY := Color(0.93, 0.91, 0.85)
const MUTED := Color(0.66, 0.66, 0.72)
const GREEN := Color(0.45, 0.9, 0.5)
const RED := Color(0.95, 0.4, 0.35)
const BG := Color(0.03, 0.035, 0.05)

## Button plates: the new art first, then the older plates.
const PLATES := {
	"gold": ["res://assets/ui/btn_gold.png", "res://assets/ui/button_1.png"],
	"green": ["res://assets/ui/btn_green.png", "res://assets/ui/button_1.png"],
	"dark": ["res://assets/ui/btn_dark.png", "res://assets/ui/button_2.png"],
	"blue": ["res://assets/ui/btn_blue.png", "res://assets/ui/button_3.png"],
	"teal": ["res://assets/ui/button_3.png"],
	"purple": ["res://assets/ui/button_4.png"],
	"red": ["res://assets/ui/btn_red.png", "res://assets/ui/button_5.png"],
}


static func first_existing(paths: Array) -> String:
	for p in paths:
		if ResourceLoader.exists(p):
			return p
	return ""


static func has(path: String) -> bool:
	return ResourceLoader.exists(path)


static func prefs() -> Node:
	return (Engine.get_main_loop() as SceneTree).root.get_node_or_null("Prefs")


static func tex(path: String, stretch := TextureRect.STRETCH_KEEP_ASPECT_CENTERED) -> TextureRect:
	var t := TextureRect.new()
	if path != "" and Tex.exists(path):
		t.texture = Tex.get_tex(path)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = stretch
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t


## An icon from the icon set (assets/ui/icons/<name>.png), or null.
static func icon(name: String) -> Texture2D:
	var p := "res://assets/ui/icons/%s.png" % name
	return Tex.get_tex(p) if ResourceLoader.exists(p) else null


static func label(text: String, px: float, color: Color, kind: String, max_w: float, min_k := 0.7) -> Label:
	var l := Fonts.label2d(text, px, color, kind)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("shadow_offset_y", maxi(int(px * 0.06), 1))
	Fonts.fit(l, max_w, min_k)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Wrapped body text (left or centred), for explanations.
static func para(text: String, px: float, color: Color, w: float, center := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", Fonts.get_font("serif"))
	l.add_theme_font_size_override("font_size", maxi(int(px), 8))
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_y", maxi(int(px * 0.05), 1))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if center else HORIZONTAL_ALIGNMENT_LEFT
	l.custom_minimum_size.x = w
	l.size.x = w
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A plate image at any width: its ends keep their shape (nine-slice drawn at
## the plate's own height, then scaled down to `size`).
static func plate(path: String, size: Vector2, edge := 0.16) -> Control:
	var t := Tex.get_tex(path)
	var k := size.y / float(t.get_height())
	var m := int(t.get_width() * edge)
	var np := NinePatchRect.new()
	np.texture = t
	np.patch_margin_left = m
	np.patch_margin_right = m
	np.size = Vector2(maxf(size.x / k, 2.0 * m + 2.0), t.get_height())
	np.scale = Vector2(k, k)
	np.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# a holder of the real on-screen size, so it can be placed like any control
	var holder := Control.new()
	holder.size = size
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(np)
	holder.set_meta("np", np)
	return holder


static func _empty_styles(b: BaseButton) -> void:
	for st in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())


## Press feedback shared by every button: shrink a little, buzz.
static func _press_fx(b: Control) -> void:
	b.pivot_offset = b.size * 0.5
	(b as BaseButton).button_down.connect(func():
		b.create_tween().tween_property(b, "scale", Vector2.ONE * 0.95, 0.06))
	(b as BaseButton).button_up.connect(func():
		b.create_tween().tween_property(b, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT))
	(b as BaseButton).pressed.connect(func():
		var p := prefs()
		if p:
			p.buzz(20))


## A plate button with a centred title (and an icon on its left, when the icon
## set has it). `kind`: gold | green | dark | blue | teal | purple | red.
static func button(text: String, size: Vector2, kind := "dark", icon_name := "") -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	_empty_styles(b)
	b.size = size
	b.custom_minimum_size = size
	var path := first_existing(PLATES.get(kind, PLATES["dark"]))
	if path != "":
		b.add_child(plate(path, size))
	else:
		var p := Panel.new()
		p.add_theme_stylebox_override("panel", box_style(Color(0.08, 0.08, 0.1), GOLD, size.y * 0.12))
		p.size = size
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(p)
	if kind == "gold" and not ResourceLoader.exists("res://assets/ui/btn_gold.png"):
		# the older green plate stands in for gold: warm it up
		b.get_child(0).modulate = Color(1.0, 1.0, 0.9)
	var inset := maxf(size.y * 0.42, size.x * 0.14)  # the plates' angled ends and gems
	var area := Rect2(inset, size.y * 0.14, size.x - 2.0 * inset, size.y * 0.72)
	var ic := icon(icon_name) if icon_name != "" else null
	var color := GOLD_LIGHT if kind in ["green", "red", "blue", "teal", "purple"] else GOLD
	var gold_art := kind == "gold" and ResourceLoader.exists("res://assets/ui/btn_gold.png")
	if gold_art:
		color = Color(0.2, 0.11, 0.03)  # dark letters on the gold plate
	var px := size.y * (0.36 if size.y < 140 else 0.33)
	var l := label(text, px, color, "title_bold", area.size.x - (area.size.y if ic else 0.0), 0.6)
	if ic:
		var t := TextureRect.new()
		t.texture = ic
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var isz := area.size.y * 0.8
		var tw := l.get_theme_font("font").get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
				l.get_theme_font_size("font_size")).x
		var total := isz + area.size.y * 0.2 + minf(tw, area.size.x - area.size.y)
		var x0 := area.position.x + (area.size.x - total) * 0.5
		t.size = Vector2(isz, isz)
		t.position = Vector2(x0, area.position.y + (area.size.y - isz) * 0.5)
		b.add_child(t)
		l.size = Vector2(total - isz - area.size.y * 0.2, area.size.y)
		l.position = Vector2(x0 + isz + area.size.y * 0.2, area.position.y - float(l.get_meta("shift")))
	else:
		l.size = area.size
		l.position = area.position - Vector2(0, float(l.get_meta("shift")))
	if gold_art:
		l.add_theme_color_override("font_shadow_color", Color(1.0, 0.9, 0.6, 0.45))
		if b.get_child_count() > 1 and b.get_child(1) is TextureRect:
			(b.get_child(1) as TextureRect).modulate = Color(0.25, 0.14, 0.04)
	b.add_child(l)
	b.set_meta("label", l)
	_press_fx(b)
	return b


## A round icon button (back, menu, close, arrows). Uses the medallion art when
## it exists; the glyph is the icon set's, or `glyph` text until then.
static func round_button(icon_name: String, glyph: String, d: float, flip := false) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	_empty_styles(b)
	b.size = Vector2(d, d)
	b.custom_minimum_size = b.size
	if ResourceLoader.exists("res://assets/ui/medallion.png"):
		var m := tex("res://assets/ui/medallion.png")
		m.size = b.size
		b.add_child(m)
	else:
		var p := Panel.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.07, 0.075, 0.1, 0.95)
		sb.border_color = Color(0.85, 0.66, 0.28)
		sb.set_border_width_all(maxi(int(d * 0.05), 2))
		sb.set_corner_radius_all(999)
		sb.shadow_color = Color(0, 0, 0, 0.5)
		sb.shadow_size = int(d * 0.1)
		sb.anti_aliasing = true
		p.add_theme_stylebox_override("panel", sb)
		p.size = b.size
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(p)
	var ic := icon(icon_name)
	if ic:
		var t := TextureRect.new()
		t.texture = ic
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		t.size = b.size * 0.52
		t.position = b.size * 0.24
		t.flip_h = flip
		b.add_child(t)
	else:
		var l := Fonts.label2d(glyph, d * 0.46, GOLD, "num")
		l.size = b.size
		l.position.y = -float(l.get_meta("shift"))
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(l)
	_press_fx(b)
	return b


## A dark rounded box with a gold edge (StyleBox for panels and fallbacks).
static func box_style(fill: Color, edge: Color, radius: float, border := 2.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.border_color = edge
	sb.set_border_width_all(maxi(int(border), 1))
	sb.set_corner_radius_all(int(radius))
	sb.anti_aliasing = true
	return sb


## A framed panel: dark inside, the gold 9-slice frame (with its gem) around.
## `corner` is how wide a frame corner shows, in px.
static func panel(size: Vector2, corner: float, fill := Color(0.05, 0.055, 0.075, 0.94)) -> Control:
	var holder := Control.new()
	holder.size = size
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var back := Panel.new()
	back.add_theme_stylebox_override("panel", box_style(fill, Color(0, 0, 0, 0), corner * 0.2, 0))
	back.size = size
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(back)
	var path := "res://assets/frames/panel_frame_9.png"
	if not ResourceLoader.exists(path):
		back.add_theme_stylebox_override("panel", box_style(fill, GOLD, corner * 0.2, corner * 0.05))
		return holder
	var t := Tex.get_tex(path)
	var tw := float(t.get_width())
	var th := float(t.get_height())
	# the frame's lines sit inside transparent margins
	var pad_tl := Vector2(0.0134 * tw, 0.116 * th)
	var pad_br := Vector2(0.0144 * tw, 0.052 * th)
	var k := corner / (0.1 * tw)
	var np := NinePatchRect.new()
	np.texture = t
	np.patch_margin_left = int(0.1 * tw)
	np.patch_margin_right = int(0.1 * tw)
	np.patch_margin_top = int(0.26 * th)
	np.patch_margin_bottom = int(0.26 * th)
	np.mouse_filter = Control.MOUSE_FILTER_IGNORE
	np.position = -pad_tl * k
	np.size = (size + (pad_tl + pad_br) * k) / k
	np.scale = Vector2(k, k)
	holder.add_child(np)
	var gem_path := "res://assets/frames/panel_gem.png"
	if ResourceLoader.exists(gem_path):
		var gt := Tex.get_tex(gem_path)
		var gem := tex(gem_path)
		var gw := corner * 2.4
		gem.size = Vector2(gw, gw * gt.get_height() / gt.get_width())
		gem.position = Vector2((size.x - gw) * 0.5, -gem.size.y * 0.55)
		holder.add_child(gem)
	return holder


## A screen title on its plaque. Returns the plaque; the text stays inside
## the plaque's dark middle.
static func title_plaque(text: String, w: float) -> Control:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var path := "res://assets/ui/title_plaque.png"
	var area: Rect2
	var t: Texture2D
	if ResourceLoader.exists(path):
		t = Tex.get_tex(path)
		area = Rect2(0.12, 0.3, 0.76, 0.56)  # below the gem, inside the bevel
	else:
		path = "res://assets/ui/turn_banner.png"
		t = Tex.get_tex(path)
		area = Rect2(215.0 / 1200.0, 52.0 / 246.0, 770.0 / 1200.0, 142.0 / 246.0)
	var h := w * t.get_height() / t.get_width()
	holder.size = Vector2(w, h)
	var img := tex(path, TextureRect.STRETCH_SCALE)
	img.size = holder.size
	holder.add_child(img)
	var r := Rect2(area.position * holder.size, area.size * holder.size)
	var l := label(text, r.size.y * 0.62, GOLD_LIGHT, "title_bold", r.size.x, 0.6)
	l.size = r.size
	l.position = r.position - Vector2(0, float(l.get_meta("shift")))
	holder.add_child(l)
	return holder


## A row background for lists (leaderboard, history, settings).
static func row_plate(size: Vector2, highlight := false) -> Control:
	var path := "res://assets/ui/row_plate.png"
	if ResourceLoader.exists(path):
		var p := plate(path, size, 0.08)
		if highlight:
			p.modulate = Color(1.25, 1.12, 0.85)
		return p
	var back := Panel.new()
	back.add_theme_stylebox_override("panel", box_style(
			Color(0.1, 0.085, 0.05, 0.92) if highlight else Color(0.055, 0.06, 0.08, 0.9),
			GOLD if highlight else Color(0.55, 0.43, 0.22, 0.8), size.y * 0.16, maxf(size.y * 0.025, 1.5)))
	back.size = size
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return back


## A row of option chips (one chosen). Calls `on_pick(index)` on change.
static func chips(options: Array, selected: int, chip: Vector2, gap: float, on_pick: Callable) -> Control:
	var holder := Control.new()
	holder.size = Vector2(options.size() * chip.x + (options.size() - 1) * gap, chip.y)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var buttons: Array[Button] = []
	var paint := func(sel: int) -> void:
		for i in buttons.size():
			var on := i == sel
			var b := buttons[i]
			var bg: Control = b.get_child(0)
			var l: Label = b.get_meta("label")
			if bg is Panel:
				(bg as Panel).add_theme_stylebox_override("panel", box_style(
						Color(0.16, 0.12, 0.05, 0.96) if on else Color(0.05, 0.055, 0.075, 0.9),
						GOLD if on else Color(0.45, 0.37, 0.22), chip.y * 0.22, maxf(chip.y * (0.05 if on else 0.03), 1.5)))
			elif bg.has_meta("np"):
				(bg.get_meta("np") as NinePatchRect).texture = Tex.get_tex("res://assets/ui/chip_on.png" if on else "res://assets/ui/chip.png")
			l.add_theme_color_override("font_color", GOLD_LIGHT if on else MUTED)
	for i in options.size():
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		_empty_styles(b)
		b.size = chip
		b.position = Vector2(i * (chip.x + gap), 0)
		var art := ResourceLoader.exists("res://assets/ui/chip.png") and ResourceLoader.exists("res://assets/ui/chip_on.png")
		var bg: Control
		if art:
			bg = plate("res://assets/ui/chip.png", chip, 0.14)
		else:
			bg = Panel.new()
			bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
			bg.size = chip
		b.add_child(bg)
		var l := label(str(options[i]), chip.y * 0.42, MUTED, "title_bold", chip.x * 0.84, 0.6)
		l.size = chip
		l.position.y = -float(l.get_meta("shift"))
		b.add_child(l)
		b.set_meta("label", l)
		_press_fx(b)
		b.pressed.connect(func():
			paint.call(i)
			on_pick.call(i))
		holder.add_child(b)
		buttons.append(b)
	paint.call(selected)
	return holder


## An on/off switch. Calls `on_change(bool)`.
static func toggle(value: bool, size: Vector2, on_change: Callable) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	_empty_styles(b)
	b.size = size
	b.set_meta("on", value)
	var art := ResourceLoader.exists("res://assets/ui/toggle_on.png") and ResourceLoader.exists("res://assets/ui/toggle_off.png")
	var track: Control
	var knob := Panel.new()
	if art:
		track = tex("", TextureRect.STRETCH_KEEP_ASPECT_CENTERED)
	else:
		track = Panel.new()
		track.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ks := StyleBoxFlat.new()
		ks.set_corner_radius_all(999)
		ks.anti_aliasing = true
		ks.border_color = Color(0.85, 0.66, 0.28)
		ks.set_border_width_all(maxi(int(size.y * 0.06), 1))
		knob.add_theme_stylebox_override("panel", ks)
		knob.size = Vector2(size.y, size.y) * 0.78
		knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.size = size
	b.add_child(track)
	if not art:
		b.add_child(knob)
	var paint := func(on: bool, animate: bool) -> void:
		if art:
			(track as TextureRect).texture = Tex.get_tex("res://assets/ui/toggle_on.png" if on else "res://assets/ui/toggle_off.png")
			return
		(track as Panel).add_theme_stylebox_override("panel", box_style(
				Color(0.1, 0.3, 0.14, 0.95) if on else Color(0.07, 0.07, 0.09, 0.95),
				GOLD if on else Color(0.42, 0.36, 0.24), size.y * 0.5, maxf(size.y * 0.06, 1.0)))
		var ks: StyleBoxFlat = knob.get_theme_stylebox("panel")
		ks.bg_color = Color(0.5, 1.0, 0.55) if on else Color(0.45, 0.45, 0.5)
		var x := size.x - size.y * 0.89 if on else size.y * 0.11
		var p := Vector2(x, size.y * 0.11)
		if animate:
			knob.create_tween().tween_property(knob, "position", p, 0.15).set_trans(Tween.TRANS_CUBIC)
		else:
			knob.position = p
	b.pressed.connect(func():
		var on := not bool(b.get_meta("on"))
		b.set_meta("on", on)
		paint.call(on, true)
		var pr := prefs()
		if pr:
			pr.buzz(20)
		on_change.call(on))
	paint.call(value, false)
	return b


## A gold slider, 0..1. Calls `on_change(value)` while dragging.
static func slider(value: float, size: Vector2, on_change: Callable, lo := 0.0, hi := 1.0) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 0.01
	s.value = value
	s.size = size
	s.focus_mode = Control.FOCUS_NONE
	var track := box_style(Color(0.04, 0.04, 0.06, 0.95), Color(0.55, 0.43, 0.22), size.y * 0.2, 1.5)
	track.content_margin_top = size.y * 0.14
	track.content_margin_bottom = size.y * 0.14
	var fill := box_style(Color(0.85, 0.62, 0.25), Color(1.0, 0.85, 0.5), size.y * 0.2, 1.0)
	fill.content_margin_top = size.y * 0.14
	fill.content_margin_bottom = size.y * 0.14
	if ResourceLoader.exists("res://assets/ui/slider_track.png"):
		var st := StyleBoxTexture.new()
		st.texture = Tex.get_tex("res://assets/ui/slider_track.png")
		st.texture_margin_left = 60
		st.texture_margin_right = 60
		st.content_margin_top = size.y * 0.16
		st.content_margin_bottom = size.y * 0.16
		s.add_theme_stylebox_override("slider", st)
		fill.bg_color = Color(0.85, 0.62, 0.25, 0.75)
		fill.content_margin_top = size.y * 0.1
		fill.content_margin_bottom = size.y * 0.1
	else:
		s.add_theme_stylebox_override("slider", track)
	s.add_theme_stylebox_override("grabber_area", fill)
	s.add_theme_stylebox_override("grabber_area_highlight", fill)
	var knob := _knob_texture(int(size.y * 1.1))
	s.add_theme_icon_override("grabber", knob)
	s.add_theme_icon_override("grabber_highlight", knob)
	s.value_changed.connect(on_change)
	return s


static func _knob_texture(d: int) -> Texture2D:
	var path := "res://assets/ui/slider_knob.png"
	if ResourceLoader.exists(path):
		var img := Tex.get_tex(path).get_image()
		img.resize(d, d, Image.INTERPOLATE_LANCZOS)
		return ImageTexture.create_from_image(img)
	# a gold ring around a blue gem
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var c := Vector2(d, d) * 0.5
	for y in d:
		for x in d:
			var r := Vector2(x + 0.5, y + 0.5).distance_to(c) / (d * 0.5)
			var col := Color(0, 0, 0, 0)
			if r < 0.62:
				col = Color(0.25, 0.6, 1.0).lerp(Color(0.75, 0.9, 1.0), clampf(0.62 - r, 0.0, 0.62))
			elif r < 0.95:
				col = Color(0.95, 0.75, 0.36).lerp(Color(0.6, 0.42, 0.16), (r - 0.62) / 0.33)
			elif r < 1.0:
				col = Color(0.3, 0.2, 0.08, (1.0 - r) / 0.05)
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


## A round portrait in the gold avatar ring. `d` is the ring's width.
static func avatar(portrait: String, d: float) -> Control:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# avatar_ring.png is 384 x 347 with its hole centred at (191, 149), 179 across
	var k := d / 384.0
	holder.size = Vector2(384, 347) * k
	var hole_d := 179.0 * k + 4.0
	var face := tex("res://assets/portraits/%s.png" % portrait, TextureRect.STRETCH_SCALE)
	var fm := ShaderMaterial.new()
	fm.shader = preload("res://shaders/avatar.gdshader")
	fm.set_shader_parameter("uv_rect", Tex.face_rect(portrait))
	face.material = fm
	face.size = Vector2(hole_d, hole_d)
	face.position = Vector2(191, 149) * k - face.size * 0.5
	holder.add_child(face)
	var ring := tex("res://assets/frames/avatar_ring.png", TextureRect.STRETCH_SCALE)
	ring.size = holder.size
	holder.add_child(ring)
	return holder


## The divider line with its centre gem.
static func divider(w: float) -> TextureRect:
	var t := tex("res://assets/frames/divider.png", TextureRect.STRETCH_SCALE)
	t.size = Vector2(w, w * 74.0 / 1024.0)
	return t


## Gold sparks drifting up from a strip (ambient, loops).
static func embers(w: float, h: float, unit: float) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.amount = 26
	p.lifetime = 5.0
	p.preprocess = 5.0
	p.texture = Tex.dot()
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	p.emission_rect_extents = Vector2(w * 0.5, h * 0.5)
	p.direction = Vector2(0, -1)
	p.spread = 25.0
	p.gravity = Vector2.ZERO
	p.initial_velocity_min = 18.0 * unit
	p.initial_velocity_max = 50.0 * unit
	p.scale_amount_min = 0.08 * unit
	p.scale_amount_max = 0.22 * unit
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.8, 0.4, 0.0))
	g.add_point(0.2, Color(1.0, 0.8, 0.4, 0.8))
	g.set_color(g.get_point_count() - 1, Color(1.0, 0.6, 0.2, 0.0))
	p.color_ramp = g
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	p.material = mat
	return p
