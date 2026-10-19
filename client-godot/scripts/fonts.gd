class_name Fonts
extends RefCounted
## Font kinds:
##   "num"   Roboto Slab ExtraBold - every number in the game (clear, lining)
##   "serif" EB Garamond           - names and text ("serif_bold" for weight 700)
##   "title" Cinzel                - headings ("title_bold")
## In Persian (L.code == "fa") "serif" and "title" use Vazirmatn; numbers stay
## Roboto Slab, so every number is shown with English digits.

const FILES := {
	"num": "res://assets/fonts/JosefinSans.ttf",  # the design's numbers (English digits)
	"serif": "res://assets/fonts/EBGaramond.ttf",
	"title": "res://assets/fonts/Cinzel.ttf",
	"fa": "res://assets/fonts/Vazirmatn.ttf",
	"sans": "res://assets/fonts/JosefinSans.ttf",
}
## Height of the digits / capitals as a fraction of the font size, used to
## centre numbers optically instead of on the line box.
const CAP := {"num": 0.75, "serif": 0.65, "title": 0.7, "fa": 0.74, "sans": 0.75}

static var _cache: Dictionary = {}


static func family(kind: String) -> String:
	return kind.trim_suffix("_bold")


## The font file behind a kind in the current language.
static func file_key(kind: String) -> String:
	var fam := family(kind)
	if fam != "num" and L.code == "fa":
		return "fa"
	return fam


## Drop cached fonts (the language changed).
static func clear() -> void:
	_cache.clear()


static func get_font(kind: String) -> Font:
	var key := kind + ":" + L.code
	if _cache.has(key):
		return _cache[key]
	var fam := family(kind)
	var fk := file_key(kind)
	var fv := FontVariation.new()
	fv.base_font = load(FILES[fk])
	var ts := TextServerManager.get_primary_interface()
	var weight := 500
	if fam == "num":
		weight = 650
	elif kind.ends_with("_bold"):
		weight = 700
	if fk == "fa":
		weight = 800 if fam == "title" else (700 if kind.ends_with("_bold") else 500)
	fv.variation_opentype = {ts.name_to_tag("wght"): weight}
	fv.opentype_features = {ts.name_to_tag("lnum"): 1}
	# names typed in the other script still show (Persian names in English, and so on)
	var other := FontVariation.new()
	other.base_font = load(FILES["serif" if fk == "fa" else "fa"])
	other.variation_opentype = {ts.name_to_tag("wght"): weight}
	fv.fallbacks = [other]
	_cache[key] = fv
	return fv


## How far (in font pixels) text sits below the visual centre when it is
## centred on its line box. Move it up by this much.
static func center_shift(kind: String, font_size: int) -> float:
	var f := get_font(kind)
	var asc := f.get_ascent(font_size)
	var desc := f.get_descent(font_size)
	return (asc - desc) * 0.5 - CAP[file_key(kind)] * font_size * 0.5


## Flat text lying on the table. `size` is in the parent's local units
## (mock px); rendered at 2x for crispness. Optically centred.
static func label3d(text: String, size: float, color: Color, kind := "num",
		outline := 0.0, outline_color := Color(0, 0, 0, 0.85)) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = get_font(kind)
	l.font_size = int(size * 2.0)
	l.pixel_size = 0.5
	l.modulate = color
	l.outline_size = int(outline * 2.0)
	l.outline_modulate = outline_color
	l.rotation_degrees.x = -90.0
	l.double_sided = true
	l.no_depth_test = false
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# the label lies flat, so "up on screen" is local -Y of the label = parent -Z
	l.offset = Vector2(0, center_shift(kind, l.font_size))
	return l


## Keep a label inside `max_w` screen px: shrink the font (down to `min_k` of
## its size), and if it still does not fit, cut it with "...". Text never
## leaves the area it was given.
static func fit(l: Label, max_w: float, min_k := 0.7) -> Label:
	var f := l.get_theme_font("font")
	var px := l.get_theme_font_size("font_size")
	var floor_px := maxi(int(px * min_k), 6)
	while px > floor_px and f.get_string_size(l.text, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > max_w:
		px -= 1
	l.add_theme_font_size_override("font_size", px)
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


## Screen-space label, optically centred in its rect.
static func label2d(text: String, px: float, color: Color, kind := "num", outline_px := 0.0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", get_font(kind))
	l.add_theme_font_size_override("font_size", maxi(int(px), 6))
	l.add_theme_color_override("font_color", color)
	if outline_px > 0.0:
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		l.add_theme_constant_override("outline_size", maxi(int(outline_px), 1))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.set_meta("shift", center_shift(kind, maxi(int(px), 6)))
	return l
