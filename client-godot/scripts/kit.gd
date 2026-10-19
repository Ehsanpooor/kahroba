class_name Kit
extends RefCounted
## The gem-merchant UI kit: every button, dialog and control outside the
## board (and the board's own dialogs), built on the host's button set
## (new gen/splendor_buttons_transparent_75_assets): gold-framed plates in five
## materials. Sizes are screen px. Painted parts from art/generated/ui3 are
## used when they exist; until then the parts are drawn to match.

const STYLES := ["emerald", "ivory", "sapphire", "ruby", "onyx"]
const UI := "res://assets/splendor/ui/"
const GOLD := Color("#f2d79c")
const GOLD_DEEP := Color("#c99a45")
const IVORY := Color("#f1e9d8")
const MUTED := Color("#b9ad94")
const INK_DARK := Color("#3f2209")  # text on ivory
const OUTLINE := Color("#2a1505")
const GEM_FOR := {"emerald": "green", "ivory": "white", "sapphire": "blue", "ruby": "red", "onyx": "black"}

static var _cache := {}


static func tex(name: String) -> Texture2D:
	if _cache.has(name):
		return _cache[name]
	var p := UI + name + ".png"
	var t: Texture2D = Tex.get_tex(p) if ResourceLoader.exists(p) else null
	_cache[name] = t
	return t


## The plate of a style closest to the shape asked for (s / m / l).
static func plate_tex(style: String, aspect: float) -> Texture2D:
	var best: Texture2D = null
	var best_d := INF
	for sz in ["s", "m", "l"]:
		var t := tex("btn_%s_%s" % [style, sz])
		if t == null:
			continue
		var d := absf(float(t.get_width()) / t.get_height() - aspect)
		if d < best_d:
			best_d = d
			best = t
	return best


## A plate at any width: the ends and the centre ornament keep their true
## shape; only the plain material between them stretches.
class Plate:
	extends Control
	var t: Texture2D
	var end_k := 0.62  # of the height
	var mid_k := 0.3

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		resized.connect(queue_redraw)

	func _draw() -> void:
		if t == null:
			return
		var tw := float(t.get_width())
		var th := float(t.get_height())
		var k := size.y / th
		var e := minf(end_k * th, tw * 0.3)
		var c := mid_k * th
		var de := e * k
		var dc := c * k
		var fill := size.x - 2.0 * de - dc
		if fill < 0.0:
			draw_texture_rect(t, Rect2(Vector2.ZERO, size), false)
			return
		var sf := (tw - 2.0 * e - c) * 0.5
		var h := size.y
		draw_texture_rect_region(t, Rect2(0, 0, de, h), Rect2(0, 0, e, th))
		draw_texture_rect_region(t, Rect2(de, 0, fill * 0.5, h), Rect2(e, 0, sf, th))
		draw_texture_rect_region(t, Rect2(de + fill * 0.5, 0, dc, h), Rect2(e + sf, 0, c, th))
		draw_texture_rect_region(t, Rect2(de + fill * 0.5 + dc, 0, fill * 0.5, h), Rect2(e + sf + c, 0, sf, th))
		draw_texture_rect_region(t, Rect2(size.x - de, 0, de, h), Rect2(tw - e, 0, e, th))


## A painted strip (tabs, rows, fields, slider grooves) at any width: its
## ends (`end_k` of the art's width each) keep their shape, the middle repeats.
static func strip(art: Texture2D, size: Vector2, end_k: float) -> Control:
	var holder := Control.new()
	holder.size = size
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if art == null:
		return holder
	var np := NinePatchRect.new()
	np.texture = art
	var m := int(art.get_width() * end_k)
	np.patch_margin_left = m
	np.patch_margin_right = m
	var k := size.y / float(art.get_height())
	np.size = Vector2(maxf(size.x / k, 2.0 * m + 2.0), art.get_height())
	np.scale = Vector2(k, k)
	np.mouse_filter = Control.MOUSE_FILTER_IGNORE
	np.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_TILE_FIT
	holder.add_child(np)
	return holder


## The onyx plates carry a gem hanging below their body (the body is the top
## 83 % of the art): the body fills `size` and the gem hangs below it, so
## anything centred in `size` sits in the middle of the visible plate.
const ONYX_BODY := 0.83


static func plate(style: String, size: Vector2) -> Control:
	var p := Plate.new()
	var balanced := tex("btn_onyx_plate") if style == "onyx" else null
	if balanced:  # the new symmetric onyx plate: the body fills the size
		p.t = balanced
		p.end_k = 1.05
		p.mid_k = 0.0
		p.size = size
		return p
	var h := size.y / ONYX_BODY if style == "onyx" else size.y
	p.t = plate_tex(style, size.x / h)
	p.size = Vector2(size.x, h)
	return p


# ------------------------------------------------------------------ text

static func _font(kind: String) -> Font:
	return Fonts.get_font(kind)


## A label in the kit's look: engraved gold by default (dark outline, soft
## drop shadow). Fitted into `w` (shrinks, then "...").
static func label(text: String, px: float, color := GOLD, kind := "title_bold", w := 0.0,
		align := HORIZONTAL_ALIGNMENT_CENTER, outline := -1.0) -> Label:
	var l := Fonts.label2d(text, px, color, kind)
	var ol := px * 0.07 if outline < 0.0 else outline
	if ol > 0.0:
		l.add_theme_color_override("font_outline_color", OUTLINE)
		l.add_theme_constant_override("outline_size", maxi(int(ol), 1))
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("shadow_offset_y", maxi(int(px * 0.06), 1))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if w > 0.0:
		l.size = Vector2(w, px * 1.5)
		Fonts.fit(l, w, 0.7)
	return l


## Wrapped body text.
static func para(text: String, px: float, w: float, color := IVORY, align := HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", _font("serif"))
	l.add_theme_font_size_override("font_size", maxi(int(px), 8))
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	l.add_theme_constant_override("shadow_offset_y", maxi(int(px * 0.05), 1))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.horizontal_alignment = align
	l.size = Vector2(w, px * 1.4)
	l.custom_minimum_size.x = w
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Place a label centred in a box (top-left `pos`, size `box`), optically.
static func put_label(parent: Control, l: Label, pos: Vector2, box: Vector2) -> Label:
	l.size = box
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.position = pos - Vector2(0, float(l.get_meta("shift", 0.0)))
	parent.add_child(l)
	return l


# ------------------------------------------------------------------ buttons

static func _empty_styles(b: BaseButton) -> void:
	for st in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())


## Press feedback: a small press-in and a buzz; hover brightens a little.
static func feedback(b: BaseButton) -> void:
	b.pivot_offset = b.size * 0.5
	b.resized.connect(func(): b.pivot_offset = b.size * 0.5)
	b.button_down.connect(func():
		b.create_tween().tween_property(b, "scale", Vector2.ONE * 0.95, 0.06)
		Sfx.play("button_tap")
		Prefs.buzz(15))
	b.button_up.connect(func():
		b.create_tween().tween_property(b, "scale", Vector2.ONE, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT))
	b.mouse_entered.connect(func():
		if not b.disabled:
			b.self_modulate = Color(1.08, 1.06, 1.02))
	b.mouse_exited.connect(func(): b.self_modulate = Color.WHITE)


## A plate button with its title (and an icon on the left, when given).
## style: emerald (main action), ivory, sapphire, ruby (cancel / leave), onyx.
static func button(text: String, size: Vector2, style := "onyx", icon := "", px := -1.0,
		kind := "title_bold", ink_override := Color(0, 0, 0, 0)) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	_empty_styles(b)
	b.size = size
	b.custom_minimum_size = size
	b.add_child(plate(style, size))
	var fpx := size.y * 0.34 if px < 0.0 else px
	var ink := INK_DARK if style == "ivory" else GOLD
	if ink_override.a > 0.0:
		ink = ink_override
	var tx := size.x * 0.12
	var tw := size.x * 0.76
	var ic := icon_tex(icon) if icon != "" else null
	if ic:
		var d := size.y * 0.42
		var ir := TextureRect.new()
		ir.texture = ic
		ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ir.size = Vector2(d, d)
		ir.position = Vector2(size.x * 0.15, (size.y - d) * 0.5)
		ir.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if style == "ivory":
			ir.modulate = Color(0.45, 0.28, 0.1)
		b.add_child(ir)
		tx = size.x * 0.15 + d + size.y * 0.1
		tw = size.x * 0.85 - tx
	var l := label(text, fpx, ink, kind, tw, HORIZONTAL_ALIGNMENT_CENTER, 0.0 if style == "ivory" else -1.0)
	if style == "ivory":
		l.add_theme_color_override("font_shadow_color", Color(1, 1, 1, 0.45))
	put_label(b, l, Vector2(tx, 0), Vector2(tw, size.y * 0.96))
	b.set_meta("label", l)
	feedback(b)
	return b


## Grey a button out (still visible, not pressable).
static func set_enabled(b: BaseButton, on: bool) -> void:
	b.disabled = not on
	b.modulate = Color.WHITE if on else Color(0.55, 0.55, 0.55, 0.9)


static func icon_tex(name: String) -> Texture2D:
	var t := tex("icon_" + name)
	if t:
		return t
	var p := "res://assets/ui/icons/%s.png" % name
	return Tex.get_tex(p) if ResourceLoader.exists(p) else null


## A round gold-framed button with an icon (settings, profile...): the
## painted onyx or emerald button, the icon on its plain centre.
static func round_button(icon: String, d: float, style := "onyx", flip := false) -> Button:
	if icon == "arrow":
		return arrow_button(-1 if flip else 1, d)
	var b := _art_button(tex("btn_round_emerald" if style == "emerald" else "btn_round_onyx"), d)
	if b.get_child_count() == 0:
		b.add_child(_drawn_round(d, style))
	var ic := icon_tex(icon)
	if ic:
		var ir := TextureRect.new()
		ir.texture = ic
		ir.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ir.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ir.size = b.size * 0.48
		ir.position = b.size * 0.26
		ir.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ir.flip_h = flip
		b.add_child(ir)
	return b


## A complete painted button (no stretching): the art fills a d x d square.
static func _art_button(art: Texture2D, d: float) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	_empty_styles(b)
	b.size = Vector2(d, d)
	b.custom_minimum_size = b.size
	if art:
		var r := TextureRect.new()
		r.texture = art
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		r.size = b.size
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(r)
	feedback(b)
	return b


## Previous (-1) / next (+1): the painted arrow buttons. In Persian the
## arrows point the other way (reading from the right).
static func arrow_button(dir: int, d: float) -> Button:
	var left := dir < 0
	if L.fa():
		left = not left
	return _art_button(tex("btn_arrow_left" if left else "btn_arrow_right"), d)


## The back button for the top of every screen.
static func back_button(d: float) -> Button:
	var b := _art_button(tex("btn_back"), d)
	if L.fa() and b.get_child_count() > 0:
		(b.get_child(0) as TextureRect).flip_h = true
	return b


## Until the painted round button exists: a gold ring around an onyx disc.
static func _drawn_round(d: float, style: String) -> Control:
	var c := Control.new()
	c.size = Vector2(d, d)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := {"onyx": Color(0.07, 0.07, 0.07), "emerald": Color(0.06, 0.3, 0.14),
			"ruby": Color(0.42, 0.04, 0.05), "sapphire": Color(0.06, 0.14, 0.42), "ivory": Color(0.92, 0.88, 0.8)}
	c.draw.connect(func():
		var r := d * 0.5
		c.draw_circle(Vector2(r, r + d * 0.03), r, Color(0, 0, 0, 0.45))
		c.draw_circle(Vector2(r, r), r, Color("#8a5a1c"))
		c.draw_circle(Vector2(r, r), r * 0.94, Color("#e8c470"))
		c.draw_circle(Vector2(r, r), r * 0.84, Color("#a8742a"))
		c.draw_circle(Vector2(r, r), r * 0.8, fill.get(style, fill["onyx"]))
		c.draw_arc(Vector2(r, r), r * 0.72, PI * 1.1, PI * 1.6, 24, Color(1, 1, 1, 0.12), d * 0.05, true))
	return c


## The close button of a dialog: the painted ruby, with a gold X on it.
static func close_button(d: float) -> Button:
	var b := _art_button(tex("btn_close"), d)
	if b.get_child_count() == 0:
		b.add_child(_drawn_round(d, "ruby"))
	var x := Control.new()
	x.size = b.size
	x.mouse_filter = Control.MOUSE_FILTER_IGNORE
	x.draw.connect(func():
		var c := d * 0.5
		var a := d * 0.13
		for k in 2:
			var w := d * (0.09 if k == 0 else 0.05)
			var col := Color(0.25, 0.04, 0.02, 0.7) if k == 0 else Color("#f6dfa6")
			x.draw_line(Vector2(c - a, c - a), Vector2(c + a, c + a), col, w, true)
			x.draw_line(Vector2(c + a, c - a), Vector2(c - a, c + a), col, w, true))
	b.add_child(x)
	return b


# ------------------------------------------------------------------ gems

static func gem(col: String, d: float) -> TextureRect:
	var r := TextureRect.new()
	r.texture = Gems.gem_tex(col)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.size = Vector2(d, d)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


# ------------------------------------------------------------------ panels + dialogs

## A dialog body: the painted onyx-leather panel as a 9-slice (its filigree
## corners keep their shape at any size). No glow.
static func panel(size: Vector2, _corner_gems := true) -> Control:
	var holder := Control.new()
	holder.size = size
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var art := tex("dialog_body")
	if art == null:
		return holder
	var np := NinePatchRect.new()
	np.texture = art
	var m := int(art.get_width() * 0.167)  # the corner filigree (measured on the art)
	np.patch_margin_left = m
	np.patch_margin_right = m
	np.patch_margin_top = m
	np.patch_margin_bottom = m
	# corners about 15 % of the dialog's short side
	var k := clampf(minf(size.x, size.y) * 0.15 / m, 0.12, 1.0)
	np.size = size / k
	np.scale = Vector2.ONE * k
	np.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(np)
	return holder


## The dialog's crest (painted): gilded wings, a ruby, and the sapphire
## plaque that carries the title. `h` is ignored when the art exists (its
## height follows its width).
const HEADER_ASPECT := 1600.0 / 423.0
const PLAQUE := Rect2(0.235, 0.6, 0.53, 0.22)  # the title plaque, measured on the art


static func header(width: float, title: String, h: float) -> Control:
	var art := tex("dialog_header")
	var hh := width / HEADER_ASPECT if art else h
	var c := Control.new()
	c.size = Vector2(width, hh)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if art:
		var r := TextureRect.new()
		r.texture = art
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_SCALE
		r.size = c.size
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(r)
	var box := Rect2(PLAQUE.position * c.size, PLAQUE.size * c.size)
	var l := label(title, box.size.y * 0.62, GOLD, "title_bold", box.size.x)
	put_label(c, l, box.position, box.size)
	c.set_meta("title", l)
	c.set_meta("plaque", box)
	return c


## The ornament along a dialog's bottom edge (painted).
const FOOTER_ASPECT := 1600.0 / 208.0


static func footer(width: float, _h := 0.0) -> Control:
	var art := tex("dialog_footer")
	var c := Control.new()
	c.size = Vector2(width, width / FOOTER_ASPECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if art:
		var r := TextureRect.new()
		r.texture = art
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_SCALE
		r.size = c.size
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		c.add_child(r)
	return c


## A full dialog: the leather body, the crest across its top edge with the
## title on its plaque, the footer ornament on its bottom edge, and (when
## `closable`) the ruby close button. Content goes inside
## box.get_meta("content") (screen px, relative to the box).
static func dialog(size: Vector2, title: String, closable := true) -> Control:
	var box := Control.new()
	box.size = size
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	box.set_meta("above", 0.0)
	box.tree_entered.connect(func(): Sfx.play("dialog_open"), CONNECT_ONE_SHOT)
	box.add_child(panel(size))
	var top := minf(size.y, size.x) * 0.06
	if title != "":
		var hw := minf(size.x * 0.86, maxf(size.x * 0.6, 900.0 * size.y / 600.0))
		var hd := header(hw, title, 0.0)
		var plaque: Rect2 = hd.get_meta("plaque")
		# the plaque straddles the top rim: its centre a little below the edge
		hd.position = Vector2((size.x - hw) * 0.5, -(plaque.position.y + plaque.size.y * 0.35))
		box.add_child(hd)
		box.set_meta("title", hd.get_meta("title"))
		top = hd.position.y + plaque.end.y + size.y * 0.04
		box.set_meta("above", -hd.position.y)
	var fw := size.x * 0.62
	var ft := footer(fw)
	ft.position = Vector2((size.x - fw) * 0.5, size.y - ft.size.y * 0.55)
	box.add_child(ft)
	if closable:
		var cd := clampf(minf(size.x, size.y) * 0.13, 70.0, 140.0)
		var cb := close_button(cd)
		cb.position = Vector2(size.x - cd * 0.72, -cd * 0.28)
		box.add_child(cb)
		box.set_meta("close_button", cb)
	var side := size.x * 0.06
	box.set_meta("content", Rect2(Vector2(side, top), Vector2(size.x - side * 2.0, size.y - top - ft.size.y * 0.6)))
	return box


# ------------------------------------------------------------------ controls

## A row of choices: the painted ivory tab for the chosen one, onyx for the
## others (until the tab art exists, the host's small plates). on_pick(i).
static func tabs(options: Array, selected: int, chip: Vector2, gap: float, on_pick: Callable) -> Control:
	var row_ := Control.new()
	row_.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row_.size = Vector2(options.size() * chip.x + (options.size() - 1) * gap, chip.y)
	for i in options.size():
		var on := i == selected
		var b: Button
		var art := tex("tab_on" if on else "tab_off")
		if art:
			b = Button.new()
			b.focus_mode = Control.FOCUS_NONE
			_empty_styles(b)
			b.size = chip
			b.add_child(strip(art, chip, 0.18))
			var l := label(String(options[i]), chip.y * 0.42, INK_DARK if on else GOLD, "sans_bold", chip.x * 0.72,
					HORIZONTAL_ALIGNMENT_CENTER, 0.0 if on else -1.0)
			put_label(b, l, Vector2(chip.x * 0.14, 0), Vector2(chip.x * 0.72, chip.y))
			feedback(b)
		else:
			b = button(String(options[i]), chip, "ivory" if on else "onyx", "", chip.y * 0.36, "sans_bold")
		b.position = Vector2(i * (chip.x + gap), 0)
		row_.add_child(b)
		b.pressed.connect(func():
			on_pick.call(i)
			var parent := row_.get_parent()
			var fresh := tabs(options, i, chip, gap, on_pick)
			fresh.position = row_.position
			parent.add_child(fresh)
			parent.move_child(fresh, row_.get_index())
			row_.queue_free())
	return row_


## An on / off switch.
static func toggle(value: bool, size: Vector2, on_change: Callable) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	_empty_styles(b)
	b.size = size
	var art_on := tex("toggle_on")
	var art_off := tex("toggle_off")
	var face := Control.new()
	face.size = size
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(face)
	var state := [value]
	var paint := func() -> void:
		for ch in face.get_children():
			ch.queue_free()
		if art_on and art_off:
			var r := TextureRect.new()
			r.texture = art_on if state[0] else art_off
			r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			r.stretch_mode = TextureRect.STRETCH_SCALE
			r.size = size
			r.mouse_filter = Control.MOUSE_FILTER_IGNORE
			face.add_child(r)
		else:
			var p := plate("emerald" if state[0] else "onyx", size)
			face.add_child(p)
			var kd := size.y * 0.78
			var knob := gem("green" if state[0] else "white", kd)
			knob.position = Vector2(size.x - kd - size.y * 0.16 if state[0] else size.y * 0.16, (size.y - kd) * 0.5)
			face.add_child(knob)
	paint.call()
	b.pressed.connect(func():
		state[0] = not state[0]
		paint.call()
		on_change.call(state[0]))
	feedback(b)
	return b


## A slider: the painted onyx groove filling with green enamel, an emerald
## knob (drawn stand-ins until the art exists).
static func slider(value: float, size: Vector2, on_change: Callable, lo := 0.0, hi := 1.0) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 0.01
	s.value = value
	s.size = size
	s.focus_mode = Control.FOCUS_NONE
	var track := tex("slider_track")
	var fill_art := tex("slider_fill")
	if track and fill_art:
		for pair in [["slider", track], ["grabber_area", fill_art], ["grabber_area_highlight", fill_art]]:
			var sb := StyleBoxTexture.new()
			var t: Texture2D = pair[1]
			sb.texture = t
			var m := t.get_width() * 0.06
			sb.texture_margin_left = m
			sb.texture_margin_right = m
			sb.content_margin_top = size.y * 0.5
			sb.content_margin_bottom = size.y * 0.5
			s.add_theme_stylebox_override(pair[0], sb)
	else:
		var groove := StyleBoxFlat.new()
		groove.bg_color = Color(0.05, 0.05, 0.05)
		groove.border_color = Color("#c99a45")
		groove.set_border_width_all(maxi(int(size.y * 0.06), 2))
		groove.set_corner_radius_all(int(size.y * 0.25))
		groove.content_margin_top = size.y * 0.22
		groove.content_margin_bottom = size.y * 0.22
		var fill := groove.duplicate() as StyleBoxFlat
		fill.bg_color = Color(0.12, 0.62, 0.3)
		s.add_theme_stylebox_override("slider", groove)
		s.add_theme_stylebox_override("grabber_area", fill)
		s.add_theme_stylebox_override("grabber_area_highlight", fill)
	var kd := int(size.y * 2.1)
	var knob_tex: Texture2D = tex("slider_knob")
	if knob_tex == null:
		knob_tex = Gems.gem_tex("green")
	if knob_tex:
		var img := knob_tex.get_image()
		if img.is_compressed():
			img.decompress()
		img.resize(kd, kd, Image.INTERPOLATE_LANCZOS)
		var kt := ImageTexture.create_from_image(img)
		s.add_theme_icon_override("grabber", kt)
		s.add_theme_icon_override("grabber_highlight", kt)
	s.value_changed.connect(on_change)
	return s


## A list row: the painted onyx row, or ivory for your own.
static func row(size: Vector2, mine := false) -> Control:
	var art := tex("row_ivory" if mine else "row_onyx")
	if art:
		return strip(art, size, 0.07)
	return plate("ivory" if mine else "onyx", size)


## A cut gem row as a divider ornament (white, blue, green, red, black).
static func gem_row(width: float, d: float) -> Control:
	var c := Control.new()
	c.size = Vector2(width, d)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cols := ["white", "blue", "green", "red", "black"]
	var line := Control.new()
	line.size = c.size
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.draw.connect(func():
		line.draw_line(Vector2(0, d * 0.5), Vector2(width, d * 0.5), Color("#7a4f17"), d * 0.12, true)
		line.draw_line(Vector2(0, d * 0.47), Vector2(width, d * 0.47), Color("#e9c675"), d * 0.05, true))
	c.add_child(line)
	for k in 5:
		var g := gem(cols[k], d)
		g.position = Vector2(width * 0.5 + (k - 2) * d * 1.25 - d * 0.5, 0)
		c.add_child(g)
	return c


## A portrait in a round gold frame.
static func avatar(portrait: String, d: float) -> Control:
	var holder := Control.new()
	holder.size = Vector2(d, d)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var face := TextureRect.new()
	face.texture = Tex.get_tex(Tex.CUSTOM if portrait == "custom" else "res://assets/portraits/%s.png" % portrait)
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_SCALE
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/avatar.gdshader")
	mat.set_shader_parameter("uv_rect", Tex.face_rect(portrait))
	face.material = mat
	face.size = holder.size * 0.88
	face.position = holder.size * 0.06
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(face)
	var frame := tex("avatar_frame")
	if frame:
		# the painted frame: its window is about 76 % of its width
		face.size = holder.size * 0.78
		face.position = holder.size * 0.11
		var fr := TextureRect.new()
		fr.texture = frame
		fr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		fr.stretch_mode = TextureRect.STRETCH_SCALE
		fr.size = holder.size
		fr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(fr)
		return holder
	var ring := Control.new()
	ring.size = holder.size
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ring.draw.connect(func():
		var r := d * 0.5
		ring.draw_arc(Vector2(r, r), r * 0.95, 0, TAU, 64, Color("#7a4f17"), d * 0.07, true)
		ring.draw_arc(Vector2(r, r), r * 0.95, 0, TAU, 64, Color("#e9c675"), d * 0.035, true))
	holder.add_child(ring)
	return holder
