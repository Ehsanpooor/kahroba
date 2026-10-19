class_name PlayerView
extends Control
## One player's area, pixel for pixel the host's design (new gen/Frame 45 +
## selection.json): an opponent's leather seat attached to the left edge
## ("seat") or your green leather panel attached to the bottom ("me").
## Every position below is in the design PNG's own pixels (Frame 45 exported
## at 3x: 2619 x 1221) and is converted with K; text sizes, colours, outlines,
## rotations and shadows are the Figma values (x 3 = PNG px).
## Text boxes are placed by their top, as Figma does: Josefin Sans's line is
## exactly its size tall, the baseline at 0.75 of it.

const K := 1080.0 / 1221.0  # design PNG px -> table design px
const HUD := "res://assets/splendor/hud/"
const SEAT_ORIGIN := Vector2(0, 5)
const ME_ORIGIN := Vector2(0, 940)
const SEAT_SIZE := Vector2(785, 325) * K
const ME_SIZE := Vector2(2213, 281) * K

## The design, measured (PNG px, absolute in Frame 45; the first seat).
const SEAT := {
	"bg": Rect2(-58, 8, 843, 317),
	"avatar": Vector2(84, 84), "avatar_d": 96.0,
	"name": [150.0, 39.0, 42.0], "rank": [155.0, 85.0, 30.0],
	"res_label": [468.0, 37.0, 30.0], "res_value": [512.0, 72.7, 48.0],
	"banner": Rect2(634, 8, 149, 162), "score": [709.0, 52.3, 78.0],
	"xs": [91.0, 211.0, 331.0, 454.0, 580.0, 702.0],
	"card_w": 70.0, "card_top": 160.0, "card_num_top": 164.5, "card_num": 48.0,
	"coin_y": 265.5, "coin_d": 78.0, "coin_num_top": 241.5, "coin_num": 48.0,
}
const ME := {
	"bg": Rect2(12, 955, 2201, 350),
	"avatar": Vector2(141, 1137), "avatar_d": 114.0,
	"name": [225.0, 1091.7, 48.0], "rank": [232.0, 1141.0, 30.0],
	"res_label": [893.0, 977.5, 36.0], "reserve": Rect2(878, 1118, 320, 113),
	"banner": Rect2(605, 1030, 172, 175), "score": [692.0, 1083.8, 87.0],
	"xs": [1317.0, 1474.0, 1629.0, 1785.0, 1944.0, 2098.0],
	"card_w": 92.0, "card_top": 1002.0, "card_num_top": 1012.0, "card_num": 54.0,
	"coin_y": 1126.0, "coin_d": 130.0, "coin_num_top": 1100.0, "coin_num": 60.0,
}
## Colours from selection.json.
const SEAT_INK := Color("#2a1306")
const SEAT_RANK := Color(0, 0, 0, 0.7)
const ME_INK := Color("#c5f2ce")
const SCORE_OUTLINE := Color("#5d2e11")
const ORDER := ["white", "blue", "red", "green", "black", "gold"]  # as the design
const CARD_TILT := 9.0
const RES_CARD_W := 80.0  # your reserved cards (design PNG px)
const RES_STEP := 79.0
## A colour you have none of: darker, still solid (not see-through).
const EMPTY := Color(0.38, 0.38, 0.38, 1.0)
## A panel's background while it is not that player's turn.
const RESTING := Color(0.55, 0.55, 0.55, 1.0)  # degrees, the cards behind the front one
const CARD_RATIO := 1.41  # card blank height / width

static var _fonts := {}
static var _soft: Texture2D

var s := 1.0
var mode := "me"
var p: Dictionary = {}
var active := false
var _d: Dictionary
var _origin: Vector2
var _score: Label
var _reserve_label: Label
var _glow: ColorRect
var _bg: TextureRect
var _groups := {}
var _reserve_box: Control
var _portrait_c := Vector2.ZERO
var _face: Control  ## the portrait and its ring, which pulse on this player's turn
var _pulse: Tween


func setup(player: Dictionary, view_mode: String, scale_px: float) -> void:
	p = player
	mode = view_mode
	s = scale_px
	_d = ME if mode == "me" else SEAT
	_origin = ME_ORIGIN if mode == "me" else SEAT_ORIGIN
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = (ME_SIZE if mode == "me" else SEAT_SIZE) * s
	_build()
	refresh()


# ------------------------------------------------------------------ design px -> screen

## A design-PNG point -> screen px inside this view.
func _pt(x: float, y: float) -> Vector2:
	return (Vector2(x, y) - _origin) * K * s


func _len(v: float) -> float:
	return v * K * s


func _rect(r: Rect2) -> Rect2:
	return Rect2(_pt(r.position.x, r.position.y), r.size * K * s)


## Josefin Sans at a weight (the design's font), Persian falling back to Vazirmatn.
static func jfont(weight: int) -> Font:
	var key := "%d:%s" % [weight, L.code]
	if _fonts.has(key):
		return _fonts[key]
	var ts := TextServerManager.get_primary_interface()
	var fv := FontVariation.new()
	fv.base_font = load("res://assets/fonts/JosefinSans.ttf")
	fv.variation_opentype = {ts.name_to_tag("wght"): weight}
	var fa := FontVariation.new()
	fa.base_font = load("res://assets/fonts/Vazirmatn.ttf")
	fa.variation_opentype = {ts.name_to_tag("wght"): weight}
	fv.fallbacks = [fa]
	_fonts[key] = fv
	return fv


## A soft blurred rounded rectangle, for the design's drop shadows and glows.
static func soft_tex() -> Texture2D:
	if _soft:
		return _soft
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var q := (Vector2(x + 0.5, y + 0.5) / n * 2.0 - Vector2.ONE).abs() - Vector2(0.45, 0.45)
			var d := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length()
			var a := exp(-d * d * 18.0)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_soft = ImageTexture.create_from_image(img)
	return _soft


## Text placed like Figma: `left`/`top` of the text box in design-PNG px, size in PNG px.
## centre_x >= 0 centres the box on that x instead.
func _text(text: String, left: float, top: float, px_png: float, color: Color, weight := 400,
		centre_x := -1.0, outline := Color(0, 0, 0, 0), outline_png := 0.0, parent: Control = self) -> Label:
	var l := Label.new()
	l.text = text
	var fsize := maxi(int(round(_len(px_png))), 6)
	l.add_theme_font_override("font", jfont(weight))
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("line_spacing", 0)
	if outline.a > 0.0:
		l.add_theme_color_override("font_outline_color", outline)
		l.add_theme_constant_override("outline_size", maxi(int(round(_len(outline_png) * 2.0)), 1))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lift := jfont(weight).get_ascent(fsize) - fsize * 0.75
	var w := _len(px_png * 6.0)
	if centre_x >= 0.0:
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.position = _pt(centre_x, top) - Vector2(w * 0.5, 0)
	else:
		l.position = _pt(left, top)
	l.size = Vector2(w, _len(px_png))
	l.position.y -= lift
	if parent != self:
		l.position -= parent.position
	parent.add_child(l)
	return l


func _image(tex: Texture2D, r: Rect2, parent: Control = self) -> TextureRect:
	var t := TextureRect.new()
	t.texture = tex
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	t.stretch_mode = TextureRect.STRETCH_SCALE
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	t.position = r.position
	t.size = r.size
	parent.add_child(t)
	return t


static func _hud(name: String) -> Texture2D:
	var path := HUD + name + ".png"
	return Tex.get_tex(path) if ResourceLoader.exists(path) else null


# ------------------------------------------------------------------ build

func _build() -> void:
	var bg := _rect(_d["bg"])
	# the turn glow behind the panel
	_glow = ColorRect.new()
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var pad := 26.0 * s
	_glow.size = bg.size + Vector2.ONE * pad * 2.0
	_glow.position = bg.position - Vector2.ONE * pad
	var gm := ShaderMaterial.new()
	gm.shader = preload("res://shaders/gui_box.gdshader")
	gm.set_shader_parameter("size", _glow.size)
	gm.set_shader_parameter("pad", pad)
	gm.set_shader_parameter("radius", 26.0 * s)
	gm.set_shader_parameter("top_col", Color(0, 0, 0, 0))
	gm.set_shader_parameter("bottom_col", Color(0, 0, 0, 0))
	gm.set_shader_parameter("edge_col", Color(1.0, 0.85, 0.45, 0.0))
	gm.set_shader_parameter("glow", 1.0)
	gm.set_shader_parameter("glow_col", Color(1.0, 0.82, 0.4, 1.0))
	_glow.material = gm
	_glow.visible = false  # the host does not want light around the panels; kept off
	add_child(_glow)
	var panel := _hud("panel_me" if mode == "me" else "panel_seat")
	if panel:
		_bg = _image(panel, bg)
		_bg.modulate = RESTING
	_avatar()
	var me_ := mode == "me"
	var ink := ME_INK if me_ else SEAT_INK
	var nm: Array = _d["name"]
	var rk: Array = _d["rank"]
	var rl: Array = _d["res_label"]
	_text(L.t("you") if me_ else String(p["name"]), nm[0], nm[1], nm[2], ink)
	_text(L.t("rank", int(p.get("rating", 0))), rk[0], rk[1], rk[2], ME_INK if me_ else SEAT_RANK)
	_text(L.t("reserves") + ":", rl[0], rl[1], rl[2], Color.WHITE if me_ else SEAT_INK)
	if me_:
		_reserve_box = Control.new()
		_reserve_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var rr := _rect(_d["reserve"])
		_reserve_box.position = rr.position
		_reserve_box.size = rr.size
		add_child(_reserve_box)
	else:
		var rv: Array = _d["res_value"]
		_reserve_label = _text("0/3", rv[0], rv[1], rv[2], SEAT_INK)
	var banner := _hud("banner_me" if me_ else "banner_seat")
	if banner:
		_image(banner, _rect(_d["banner"]))
	var sc: Array = _d["score"]
	_score = _text("0", 0, sc[1], sc[2], Color.WHITE, 400, sc[0], SCORE_OUTLINE, 3.0)
	var xs: Array = _d["xs"]
	for k in 6:
		_group(ORDER[k], float(xs[k]))


func _avatar() -> void:
	var c: Vector2 = _d["avatar"]
	var dd: float = _d["avatar_d"]
	_portrait_c = c
	var face := TextureRect.new()
	var portrait := String(p["portrait"])
	face.texture = Tex.get_tex(Tex.CUSTOM if portrait == "custom" else "res://assets/portraits/%s.png" % portrait)
	face.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	face.stretch_mode = TextureRect.STRETCH_SCALE
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/avatar.gdshader")
	mat.set_shader_parameter("uv_rect", Tex.face_rect(portrait))
	mat.set_shader_parameter("back", Color(0.95, 0.86, 0.8))
	face.material = mat
	face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face = Control.new()
	_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.position = _pt(c.x - dd * 0.5, c.y - dd * 0.5)
	_face.size = Vector2.ONE * _len(dd)
	_face.pivot_offset = _face.size * 0.5
	add_child(_face)
	face.size = _face.size
	_face.add_child(face)
	var ring := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Color(0.86, 0.68, 0.4)
	sb.set_border_width_all(maxi(int(round(_len(3.0))), 1))
	sb.set_corner_radius_all(int(face.size.x))
	sb.anti_aliasing = true
	ring.add_theme_stylebox_override("panel", sb)
	ring.size = face.size
	ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.add_child(ring)
	if active:
		_start_pulse()


## One colour: the card stack (front card with the count, cards behind it
## tilted 9 degrees) and the token below it with its cost circle and count.
func _group(col: String, cx: float) -> void:
	var g := {}
	var ink := Color.BLACK if col == "white" else Color.WHITE
	if col != "gold":
		var w: float = _d["card_w"]
		var h := w * CARD_RATIO
		var holder := Control.new()
		holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.position = _pt(cx - w * 0.5, float(_d["card_top"]))
		holder.size = Vector2(_len(w), _len(h))
		add_child(holder)
		g["card"] = holder
		g["card_label"] = null
		g["card_ink"] = ink
	var dd: float = _d["coin_d"]
	var cy: float = _d["coin_y"]
	var coin := Control.new()
	coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	coin.position = _pt(cx - dd * 0.5, cy - dd * 0.5)
	coin.size = Vector2.ONE * _len(dd)
	coin.pivot_offset = coin.size * 0.5
	add_child(coin)
	# the design's coin shadow (15 px blur, 1 px down, black 39 %)
	var sh := _image(soft_tex(), Rect2(Vector2(-0.22, -0.16) * coin.size, coin.size * 1.44), coin)
	sh.modulate = Color(0, 0, 0, 0.45)
	var tok := Gems.num_tex(col)  # the plain token: its middle carries the number
	if tok:
		_image(tok, Rect2(Vector2.ZERO, coin.size), coin)
	g["coin"] = coin
	g["coin_label"] = _text("0", 0, float(_d["coin_num_top"]), float(_d["coin_num"]), ink, 400, cx, Color(0, 0, 0, 0), 0.0, coin)
	_groups[col] = g


## 1 card; 2: one more behind on the left; 3 or more: on both sides.
func _draw_stack(col: String, n: int) -> void:
	var g: Dictionary = _groups[col]
	var holder: Control = g["card"]
	for c in holder.get_children():
		c.queue_free()
	var t := _hud("card_" + col)
	var sz := holder.size
	var behind := []
	if n >= 2:
		behind.append(-1)
	if n >= 3:
		behind.append(1)
	for side in behind:
		var tr := _image(t, Rect2(Vector2(side * 3.0 * s, 0), sz), holder)
		tr.pivot_offset = Vector2(sz.x * 0.5, sz.y)
		tr.rotation = deg_to_rad(CARD_TILT) * side
		tr.modulate = Color(0.82, 0.82, 0.82)
	# the front card's drop shadow (6 px blur, black 60 %)
	var sh := _image(soft_tex(), Rect2(-sz * 0.2, sz * 1.4), holder)
	sh.modulate = Color(0, 0, 0, 0.6)
	_image(t, Rect2(Vector2.ZERO, sz), holder)
	var cx := (holder.position.x + sz.x * 0.5) / (K * s) + _origin.x
	g["card_label"] = _text(str(n), 0, float(_d["card_num_top"]), float(_d["card_num"]), g["card_ink"], 400, cx,
			Color(0, 0, 0, 0), 0.0, holder)
	holder.modulate = Color.WHITE if n > 0 else EMPTY


# ------------------------------------------------------------------ state

func refresh(pop := false) -> void:
	_set_label(_score, int(p["prestige"]), pop)
	for col in Gems.ALL:
		var g: Dictionary = _groups[col]
		var n := int(p["coins"][col])
		_set_label(g["coin_label"], n, pop)
		(g["coin"] as Control).modulate = Color.WHITE if n > 0 else EMPTY
		if g.has("card"):
			var b := int(p["cards"][col])
			var old: Label = g["card_label"]
			if old == null or old.text != str(b):
				_draw_stack(col, b)
	var res: Array = p["reserved"]
	if _reserve_label:
		_reserve_label.text = "%d/3" % res.size()
	if _reserve_box:
		_draw_reserve(res)


## Your reserved cards as the design shows them: just a card of each one's
## gem colour, side by side under "Reserves:", running off the bottom edge.
func _draw_reserve(res: Array) -> void:
	for c in _reserve_box.get_children():
		c.queue_free()
	var w := _len(RES_CARD_W)
	var h := w * CARD_RATIO
	for k in res.size():
		var t := _hud("card_" + String(res[k]["element"]))
		if t:
			_image(t, Rect2(Vector2(k * _len(RES_STEP), 0), Vector2(w, h)), _reserve_box)


func _set_label(l: Label, n: int, pop: bool) -> void:
	if l == null:
		return
	var changed := l.text != str(n)
	l.text = str(n)
	if changed and pop:
		l.pivot_offset = l.size * 0.5
		l.scale = Vector2.ONE * 1.6
		var tw := l.create_tween()
		tw.tween_property(l, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


## Only the leather background shows the turn: dimmed while waiting, full
## brightness on its player's turn. The cards, tokens and text never change.
func set_active(on: bool) -> void:
	if on == active and _bg and _bg.modulate == (Color.WHITE if on else RESTING):
		return
	active = on
	if _bg:
		var tw := _bg.create_tween()
		tw.tween_property(_bg, "modulate", Color.WHITE if on else RESTING, 0.35)
	if on:
		_start_pulse()
	else:
		_stop_pulse()


## The player on turn: their portrait beats gently, like a heart, until the
## turn passes.
func _start_pulse() -> void:
	if _face == null:
		return
	_stop_pulse()
	_pulse = _face.create_tween().set_loops()
	_pulse.tween_property(_face, "scale", Vector2.ONE * 1.12, 0.45).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_pulse.tween_property(_face, "scale", Vector2.ONE, 0.55).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_pulse.tween_interval(0.35)


func _stop_pulse() -> void:
	if _pulse and _pulse.is_valid():
		_pulse.kill()
	_pulse = null
	if _face:
		var tw := _face.create_tween()
		tw.tween_property(_face, "scale", Vector2.ONE, 0.2)


func pop_token(col: String) -> void:
	_pop(_groups[col]["coin"])


func pop_card(col: String) -> void:
	if _groups[col].has("card"):
		_pop(_groups[col]["card"])


func _pop(c: Control) -> void:
	c.pivot_offset = c.size * 0.5
	c.scale = Vector2.ONE * 1.25
	var tw := c.create_tween()
	tw.tween_property(c, "scale", Vector2.ONE, 0.4).set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


# ------------------------------------------------------------------ anchors (screen px)

func token_point(col: String) -> Vector2:
	var b: Control = _groups[col]["coin"]
	return b.global_position + b.size * 0.5


func card_point(col: String) -> Vector2:
	var b: Control = _groups[col]["card"] if _groups[col].has("card") else _groups[col]["coin"]
	return b.global_position + b.size * 0.5


func reserve_point() -> Vector2:
	if _reserve_box:
		return _reserve_box.global_position + _reserve_box.size * 0.5
	return _reserve_label.global_position + _reserve_label.size * 0.5


func reserve_rect() -> Rect2:
	if _reserve_box:
		return Rect2(_reserve_box.global_position - Vector2(0, _len(60.0)), _reserve_box.size + Vector2(0, _len(60.0)))
	return Rect2()


func portrait_point() -> Vector2:
	return global_position + _pt(_portrait_c.x, _portrait_c.y)


func score_point() -> Vector2:
	return _score.global_position + _score.size * 0.5
