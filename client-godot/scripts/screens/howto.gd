extends Screen
## How to play, for someone who has never seen the game: eight pages on a
## painted dialog, each with a picture made from the real game pieces and
## three points, every point a row with a gem bullet (wrapped lines stay
## aligned). Arrows and page gems beneath; swipe works too.

const PAGES := 8
const BOX := Rect2(200, 175, 2000, 740)
const PIC_W := 560.0

var page := 0
var _press := Vector2.ZERO


func build() -> void:
	backdrop("screen_bg", 0.3)
	var bb := Kit.back_button(130.0 * u)
	put_at(bb, Vector2(mx(36, 130), 26))
	bb.pressed.connect(func(): back.emit())
	var key := "h%d" % (page + 1)
	put_at(Kit.panel(BOX.size * u), BOX.position)
	var hd := Kit.header(1000.0 * u, L.t(key + "_t"), 0.0)
	var plaque: Rect2 = hd.get_meta("plaque")
	put_at(hd, Vector2((D.x - 1000.0) * 0.5, BOX.position.y - (plaque.position.y + plaque.size.y * 0.35) / u))
	# the picture on one side
	var pic := Rect2(mx(BOX.position.x + 80, PIC_W), BOX.position.y + 130, PIC_W, 520)
	_picture(page, pic)
	# the three points on the other: a gem, then the wrapped line; the text
	# size steps down until all three fit the panel
	var tw := 1240.0
	var tx := mx(BOX.position.x + 680, tw)
	var text_w := tw - 76
	var font := Fonts.get_font("serif")
	var top := BOX.position.y + 140
	var room := BOX.end.y - 70 - top
	var gap := 34.0
	var lines: Array = []
	for k in 3:
		lines.append(L.t("%s_%d" % [key, k + 1]))
	var px := TS.LABEL
	var hs: Array = []
	while true:
		hs.clear()
		var total := gap * 2
		for line in lines:
			var h: float = font.get_multiline_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, text_w * u, int(px * u)).y / u
			hs.append(h)
			total += h
		if total <= room or px <= TS.CAPTION:
			break
		px -= 2.0
	var y := top
	var gems := ["green", "blue", "red"]
	for k in 3:
		var g := Kit.gem(gems[k], 42.0 * u)
		put_at(g, Vector2(tx + tw - 42 if L.fa() else tx, y + px * 0.18))
		var l := Kit.para(lines[k], px * u, text_w * u, Kit.IVORY, start_align())
		put_at(l, Vector2(tx if L.fa() else tx + 76, y - px * 0.12))
		y += float(hs[k]) + gap
	# arrows and page gems
	var prev := Kit.arrow_button(-1, 150.0 * u)
	var next := Kit.arrow_button(1, 150.0 * u)
	put_at(prev, Vector2(mx(560, 150), 920))
	put_at(next, Vector2(mx(1690, 150), 920))
	prev.pressed.connect(func(): _go(page - 1))
	next.pressed.connect(func(): _go(page + 1))
	Kit.set_enabled(prev, page > 0)
	for i in PAGES:
		var on := i == page
		var d := 54.0
		var x := D.x * 0.5 + (i - (PAGES - 1) * 0.5) * 80.0 - d * 0.5
		if L.fa():
			x = D.x - x - d
		var dot := Kit.tex("page_dot_on" if on else "page_dot_off")
		var r := TextureRect.new()
		r.texture = dot if dot else Gems.gem_tex("green" if on else "black")
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		put(r, Vector2(x, 968), Vector2(d, d))


# ------------------------------------------------------------------ pictures from the real pieces

func _picture(p: int, r: Rect2) -> void:
	var c := r.get_center()
	match p:
		0:  # the goal: the crown over a prestige medal
			_img(Kit.tex("icon_crown"), Rect2(c.x - 170, r.position.y, 340, 300))
			_img(Kit.tex("medal_1"), Rect2(c.x - 120, r.position.y + 290, 240, 240))
		1:  # your turn: three different gems, or two alike, or a card
			_tokens(["red", "blue", "green"], Vector2(c.x, r.position.y + 80), 140.0)
			_tokens(["white", "white"], Vector2(c.x, r.position.y + 240), 140.0)
			_card("blue", 1, 1, [["white", 1], ["red", 2]], Rect2(c.x - 170, r.position.y + 330, 340, 248))
		2:  # tokens: the five gems and gold
			_tokens(["white", "blue", "green"], Vector2(c.x, r.position.y + 110), 170.0)
			_tokens(["red", "black", "gold"], Vector2(c.x, r.position.y + 320), 170.0)
		3:  # a card
			_card("red", 2, 3, [["white", 2], ["blue", 3], ["black", 2]], Rect2(c.x - 300, r.position.y + 40, 600, 438))
		4:  # bonuses: three red cards pay a ruby cost
			for k in 3:
				_card("red", 1, 0, [["green", 1]], Rect2(c.x - 310 + k * 50, r.position.y + k * 40, 380, 277))
			_card("green", 2, 2, [["red", 3]], Rect2(c.x - 50, r.position.y + 240, 380, 277))
		5:  # reserving: the three deck backs and a gold token
			for k in 3:
				var bp := "res://assets/splendor/hud/back_%d.png" % (k + 1)
				_img(Tex.get_tex(bp) if ResourceLoader.exists(bp) else null, Rect2(c.x - 300 + k * 130, r.position.y + 40 + k * 30, 340, 250))
			_tokens(["gold"], Vector2(c.x + 150, r.position.y + 430), 170.0)
		6:  # nobles
			_img(Gems.noble_tex("N-07"), Rect2(c.x - 230, r.position.y, 460, 460))
			_tokens(["blue", "green"], Vector2(c.x, r.position.y + 470), 110.0)
		7:  # tips: the clock
			var cp := "res://assets/splendor/hud/clock.png"
			if ResourceLoader.exists(cp):
				_img(Tex.get_tex(cp), Rect2(c.x - 200, r.position.y, 400, 490))
				text("90", 110.0, Color("#61ef61"), "num", Rect2(c.x - 200, r.position.y + 170, 400, 170))


func _img(t: Texture2D, r: Rect2) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = t
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	put(tr, r.position, r.size)
	return tr


func _tokens(cols: Array, centre: Vector2, d: float) -> void:
	for i in cols.size():
		var x := centre.x + (i - (cols.size() - 1) * 0.5) * (d + 20) - d * 0.5
		_img(Gems.token_tex(cols[i]), Rect2(x, centre.y - d * 0.5, d, d))


## A card drawn the way the table shows it: the painting in a pearl border,
## points top left, the gem top right, the costs along the bottom.
func _card(col: String, tier: int, points: int, costs: Array, r: Rect2) -> void:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	put(holder, r.position, r.size)
	var border := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.95, 0.92, 0.86)
	sb.set_corner_radius_all(int(r.size.y * 0.06 * u))
	sb.border_color = Color(0.78, 0.6, 0.3)
	sb.set_border_width_all(maxi(int(2 * u), 1))
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = int(8 * u)
	border.add_theme_stylebox_override("panel", sb)
	border.size = holder.size
	border.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(border)
	var b := r.size.x * 0.035
	var art := TextureRect.new()
	art.texture = Gems.card_art(col, tier)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.clip_contents = true
	art.position = Vector2(b, b) * u
	art.size = (r.size - Vector2(b, b) * 2.0) * u
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(art)
	var gd := r.size.y * 0.5
	var gem := Kit.gem(col, gd * u)
	gem.position = Vector2(r.size.x * 0.85 - gd * 0.5, r.size.y * 0.24 - gd * 0.5) * u
	holder.add_child(gem)
	if points > 0:
		text(str(points), r.size.y * 0.32, Color.WHITE, "num", Rect2(r.size.x * 0.04, r.size.y * 0.04, r.size.x * 0.2, r.size.y * 0.3),
				HORIZONTAL_ALIGNMENT_CENTER, holder)
	var pd := r.size.y * 0.3
	for i in costs.size():
		var cst: Array = costs[i]
		var pip := TextureRect.new()
		pip.texture = Gems.pip_tex(cst[0])
		pip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		pip.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var pos := Vector2(r.size.x * 0.06 + i * pd * 1.06, r.size.y * 0.82 - pd * 0.5)
		pip.position = pos * u
		pip.size = Vector2(pd, pd) * u
		holder.add_child(pip)
		text(str(cst[1]), pd * 0.62, Gems.INK[cst[0]], "num", Rect2(pos, Vector2(pd, pd)), HORIZONTAL_ALIGNMENT_CENTER, holder)


func _go(i: int) -> void:
	if i >= PAGES:
		back.emit()
		return
	if i < 0 or i == page:
		return
	page = i
	_rebuild()


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and (e as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := e as InputEventMouseButton
		if mb.pressed:
			_press = mb.position
		else:
			var dx := mb.position.x - _press.x
			if absf(dx) > 120.0 * u:
				var forward := dx < 0.0
				if L.fa():
					forward = not forward
				_go(page + (1 if forward else -1))
