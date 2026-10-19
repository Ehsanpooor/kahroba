class_name TurnClock
extends Control
## The turn clock, pixel for pixel the host's design (Frame 45 + selection.json):
## the clockwork frame attached to the bottom of the screen, small blurred
## green bars filling the slots of its ring and going out one by one as the
## turn runs down, the seconds in the middle. Positions are design-PNG px
## (converted with K like PlayerView); sizes and colours are the Figma values.

const K := PlayerView.K
## The frame (whole clock.png) in the design PNG.
const FRAME := Rect2(2241.4, 868.7, 349.5, 425.8)
const RING_C := Vector2(2415, 1060)
const RING_R := 125.5
## The 16 slots, clockwise from the watch; the design's 10 lit bars are the first 10.
const SLOTS := [-68.5, -49.9, -30.9, -12.8, 8.9, 25.5, 44.2, 67.2, 112.1, 133.5,
		154.5, 171.1, 192.8, 210.9, 229.9, 248.5]
const BAR := Vector2(28.5, 17.1)  # Figma 9.5 x 5.7
const BAR_BLUR := 9.0  # Figma layer blur 3
const BAR_COLOR := Color("#1ed85c")
const WARN_COLOR := Color("#ff4a3a")
const NUM_COLOR := Color("#61ef61")
const NUM_OUTLINE := Color("#4b1e05")
const SEC_COLOR := Color("#431a04")

var s := 1.0
var left := 1.0
var secs := 90.0
var _num: Label
var _unit: Label
var _ring: Control


func _pt(x: float, y: float) -> Vector2:
	return (Vector2(x, y) - FRAME.position) * K * s


func _len(v: float) -> float:
	return v * K * s


func setup(scale_px: float) -> void:
	s = scale_px
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = FRAME.size * K * s
	var path := "res://assets/splendor/hud/clock.png"
	if ResourceLoader.exists(path):
		var t := TextureRect.new()
		t.texture = Tex.get_tex(path)
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_SCALE
		t.size = size
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(t)
	_ring = Control.new()
	_ring.size = size
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.draw.connect(_draw_ring)
	add_child(_ring)
	_num = _label("", 2418, 1007, 114.0, NUM_COLOR, 700, NUM_OUTLINE, 3.0)
	_unit = _label(L.t("sec"), 2419, 1095, 36.0, SEC_COLOR, 400)
	set_time(1.0, 90.0)


func _label(text: String, centre_x: float, top: float, px_png: float, color: Color, weight: int,
		outline := Color(0, 0, 0, 0), outline_png := 0.0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", PlayerView.jfont(weight))
	l.add_theme_font_size_override("font_size", maxi(int(round(_len(px_png))), 6))
	l.add_theme_color_override("font_color", color)
	if outline.a > 0.0:
		l.add_theme_color_override("font_outline_color", outline)
		l.add_theme_constant_override("outline_size", maxi(int(round(_len(outline_png) * 2.0)), 1))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var w := _len(px_png * 4.0)
	l.size = Vector2(w, _len(px_png))
	l.position = _pt(centre_x, top) - Vector2(w * 0.5, 0)
	var fsize := maxi(int(round(_len(px_png))), 6)
	l.position.y -= PlayerView.jfont(weight).get_ascent(fsize) - fsize * 0.75
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(l)
	return l


func set_time(k: float, seconds: float) -> void:
	left = clampf(k, 0.0, 1.0)
	secs = seconds
	_num.text = str(ceili(seconds))
	_num.add_theme_color_override("font_color", WARN_COLOR if seconds <= 10.0 else NUM_COLOR)
	_ring.queue_redraw()


## Each lit slot: a small bar along the ring, blurred like the design's
## (a wide soft layer and a brighter core).
func _draw_ring() -> void:
	var lit := ceili(SLOTS.size() * left - 0.001)
	var col := WARN_COLOR if secs <= 10.0 else BAR_COLOR
	var soft := PlayerView.soft_tex()
	var c := _pt(RING_C.x, RING_C.y)
	var r := _len(RING_R)
	for i in mini(lit, SLOTS.size()):
		var a := deg_to_rad(float(SLOTS[i]))
		var p := c + Vector2(cos(a), sin(a)) * r
		_ring.draw_set_transform(p, a + PI * 0.5, Vector2.ONE)
		var blur := Vector2.ONE * _len(BAR_BLUR) * 2.0
		var outer := Vector2(_len(BAR.x), _len(BAR.y)) + blur
		_ring.draw_texture_rect(soft, Rect2(-outer * 0.5, outer), false, Color(col, 0.75))
		var core := Vector2(_len(BAR.x), _len(BAR.y)) * 0.85
		_ring.draw_texture_rect(soft, Rect2(-core * 0.5, core), false, Color(col.lightened(0.15), 0.9))
	_ring.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
