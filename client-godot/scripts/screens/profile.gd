extends Screen
## Your profile: on the left your portrait, name (an ivory field) and record;
## on the right the portraits to choose from, or your own photo.

const LEFT := Rect2(160, 200, 760, 840)
const RIGHT := Rect2(980, 200, 1260, 840)


func build() -> void:
	backdrop("screen_bg", 0.3)
	title_bar(L.t("profile"))
	var lx := mx(LEFT.position.x, LEFT.size.x)
	var rx := mx(RIGHT.position.x, RIGHT.size.x)
	put_at(Kit.panel(LEFT.size * u), Vector2(lx, LEFT.position.y))
	put_at(Kit.panel(RIGHT.size * u), Vector2(rx, RIGHT.position.y))
	var av := Kit.avatar(String(Prefs.get_v("portrait")), 300.0 * u)
	put_at(av, Vector2(lx + (LEFT.size.x - 300) * 0.5, LEFT.position.y + 60))
	# the name, editable, on the painted ivory field
	var fw := 600.0
	var fh := 110.0
	var fx := lx + (LEFT.size.x - fw) * 0.5
	var fy := LEFT.position.y + 400
	var field := Kit.tex("input_field")
	if field:
		put_at(Kit.strip(field, Vector2(fw, fh) * u, 0.08), Vector2(fx, fy))
	var le := LineEdit.new()
	le.text = String(Prefs.get_v("name"))
	le.max_length = 18
	le.alignment = HORIZONTAL_ALIGNMENT_CENTER
	le.add_theme_font_override("font", Fonts.get_font("sans_bold"))
	le.add_theme_font_size_override("font_size", int(TS.TITLE * u))
	le.add_theme_color_override("font_color", Kit.INK_DARK)
	le.add_theme_color_override("caret_color", Kit.INK_DARK)
	for st in ["normal", "focus", "read_only"]:
		le.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	put(le, Vector2(fx + 50, fy + 10), Vector2(fw - 100, fh - 20))
	le.text_changed.connect(func(t: String):
		if t.strip_edges().length() >= 2:
			Prefs.set_v("name", t.strip_edges()))
	# the record: three gem medallions
	var h := Prefs.history()
	var wins := h.filter(func(g): return g.get("result", "") == "win").size()
	var stats := [[L.t("col_rating"), str(int(Prefs.get_v("rating")))], [L.t("games"), str(h.size())], [L.t("wins_n"), str(wins)]]
	for i in 3:
		var sx := lx + 80 + i * 210.0
		var med := Kit.round_button("", 170.0 * u, "onyx")
		med.mouse_filter = Control.MOUSE_FILTER_IGNORE
		put_at(med, Vector2(sx, LEFT.position.y + 560))
		text(stats[i][1], TS.NUM_M, Kit.GOLD, "num", Rect2(sx, LEFT.position.y + 560, 170, 170))
		text(stats[i][0], TS.CAPTION, Kit.MUTED, "sans_bold", Rect2(sx - 20, LEFT.position.y + 735, 210, 40))
	# portraits
	var photo := Kit.button(L.t("use_photo"), Vector2(520, 116) * u, "sapphire", "person")
	put_at(photo, Vector2(rx + (RIGHT.size.x - 520) * 0.5, RIGHT.position.y + 50))
	photo.pressed.connect(func():
		PhotoPicker.pick(self, func(img: Image):
			if img:
				CropDialog.open(self, img, func(cut: Image):
					if cut:
						PhotoPicker.save(cut)
						Prefs.set_v("portrait", "custom")
						_rebuild.call_deferred())))
	text(L.t("pick_face"), TS.BODY, Kit.MUTED, "serif", Rect2(rx, RIGHT.position.y + 180, RIGHT.size.x, 50))
	var grid := scroll_area(Rect2(rx + 70, RIGHT.position.y + 250, RIGHT.size.x - 140, RIGHT.size.y - 300))
	var rating := int(Prefs.get_v("rating"))
	var faces := Portraits.all() if Portraits.available() else []
	if faces.is_empty():
		for pre in ["H", "M", "E", "D", "V"]:
			for k in 18:
				faces.append("%s-%02d" % [pre, k + 1])
	var per := 6
	var cell := (RIGHT.size.x - 140) / per
	for i in faces.size():
		var pid: String = faces[i]
		var b := portrait_tile(pid, cell - 24, pid == Portraits.resolve(String(Prefs.get_v("portrait"))), rating, func(p: String):
			Prefs.set_v("portrait", p)
			_rebuild())
		var col := i % per
		if L.fa():
			col = per - 1 - col
		add_in(grid, b, Vector2(col * cell + 12, (i / per) * cell + 12))
