extends Screen
## First start, three steps on painted dialogs, then the menu (which offers
## the tutorial): 0. the language, 1. your name, 2. your portrait (or your
## own photo).

var step := 0
var _name := ""
var _portrait := ""


func build() -> void:
	if arg is int and not has_meta("arg_used"):
		set_meta("arg_used", true)
		step = clampi(int(arg), 0, 2)
	if _name == "":
		_name = String(Prefs.get_v("name"))
	if _portrait == "":
		_portrait = String(Prefs.get_v("portrait"))
	backdrop("menu_bg", 0.45)
	if step == 0:
		_build_lang()
	elif step == 1:
		_build_name()
	else:
		_build_portrait()


func on_back() -> bool:
	if super.on_back():
		return true
	if step > 0:
		step -= 1
		_rebuild()
	return true  # never back out of the first start


## The very first question, asked in both languages: which one to play in.
func _build_lang() -> void:
	_logo(Rect2((D.x - 700) * 0.5, 24, 700, 250))
	var box := Rect2((D.x - 1300) * 0.5, 440, 1300, 560)
	var dlg := Kit.dialog(box.size * u, "زبان  •  Language", false)
	put_at(dlg, box.position)
	var r: Rect2 = dlg.get_meta("content")
	var cw := r.size.x / u
	var fa_q := Kit.label("زبان بازی را انتخاب کنید", TS.TITLE * u, Kit.IVORY, "serif_bold", r.size.x)
	fa_q.position = r.position + Vector2(0, 10 * u)
	dlg.add_child(fa_q)
	var en_q := Kit.label("Choose your language", TS.LABEL * u, Kit.MUTED, "serif", r.size.x)
	en_q.position = r.position + Vector2(0, 80 * u)
	dlg.add_child(en_q)
	var bw := 480.0
	var gap := 60.0
	var x0 := (cw - bw * 2 - gap) * 0.5
	for i in 2:
		var code: String = ["fa", "en"][i]
		var b := Kit.button(["فارسی", "English"][i], Vector2(bw, 150) * u, ["emerald", "sapphire"][i], "", 56.0 * u)
		b.position = r.position + Vector2(x0 + i * (bw + gap), 190) * u
		dlg.add_child(b)
		b.pressed.connect(func():
			Prefs.set_v("lang", code)
			step = 1
			_rebuild())
	var note := Kit.label(L.t("lang_later"), TS.CAPTION * u, Kit.MUTED, "serif", r.size.x)
	note.position = r.position + Vector2(0, 375 * u)
	dlg.add_child(note)


## The painted logo (or the emblem, or the gem row) in `r`.
func _logo(r: Rect2) -> void:
	var emblem := Kit.tex("logo_splendor")
	if emblem == null:
		emblem = Kit.tex("logo_emblem")
	if emblem:
		var t := TextureRect.new()
		t.texture = emblem
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		put(t, r.position, r.size)
	else:
		put_at(Kit.gem_row(700.0 * u, 90.0 * u), Vector2((D.x - 700) * 0.5, r.get_center().y - 45))


func _build_name() -> void:
	var emblem := Kit.tex("logo_splendor")
	if emblem == null:
		emblem = Kit.tex("logo_emblem")
	if emblem:
		var r := TextureRect.new()
		r.texture = emblem
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		put(r, Vector2((D.x - 420) * 0.5, 20), Vector2(420, 300))
	else:
		put_at(Kit.gem_row(700.0 * u, 90.0 * u), Vector2((D.x - 700) * 0.5, 150))
	var box := Rect2((D.x - 1300) * 0.5, 330, 1300, 660)
	var dlg := Kit.dialog(box.size * u, L.t("welcome_title"), false)
	put_at(dlg, box.position)
	var r: Rect2 = dlg.get_meta("content")
	var cw := r.size.x / u
	var q := Kit.label(L.t("welcome_name"), TS.TITLE * u, Kit.IVORY, "serif_bold", r.size.x)
	q.position = r.position + Vector2(0, 20 * u)
	dlg.add_child(q)
	var fw := 900.0
	var fh := 140.0
	var field := Kit.tex("input_field")
	var fpos := r.position + Vector2((cw - fw) * 0.5, 120) * u
	if field:
		var f := Kit.strip(field, Vector2(fw, fh) * u, 0.08)
		f.position = fpos
		dlg.add_child(f)
	var le := LineEdit.new()
	le.text = _name
	le.placeholder_text = L.t("your_name")
	le.max_length = 18
	le.alignment = HORIZONTAL_ALIGNMENT_CENTER
	le.add_theme_font_override("font", Fonts.get_font("sans_bold"))
	le.add_theme_font_size_override("font_size", int(TS.BANNER * u))
	le.add_theme_color_override("font_color", Kit.INK_DARK)
	le.add_theme_color_override("font_placeholder_color", Color(0.45, 0.38, 0.3))
	le.add_theme_color_override("caret_color", Kit.INK_DARK)
	for st in ["normal", "focus", "read_only"]:
		le.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	le.position = fpos + Vector2(60, 12) * u
	le.size = Vector2(fw - 120, fh - 24) * u
	dlg.add_child(le)
	var hint := Kit.label(L.t("name_hint"), TS.BODY * u, Kit.MUTED, "serif", r.size.x)
	hint.position = r.position + Vector2(0, 280 * u)
	dlg.add_child(hint)
	var next := Kit.button(L.t("next"), Vector2(520, 136) * u, "emerald")
	next.position = r.position + Vector2((cw - 520) * 0.5, 360) * u
	dlg.add_child(next)
	var ok := func(t: String) -> bool: return t.strip_edges().length() >= 2
	Kit.set_enabled(next, ok.call(le.text))
	le.text_changed.connect(func(t: String):
		_name = t
		Kit.set_enabled(next, ok.call(t)))
	var go_next := func():
		if ok.call(le.text):
			_name = le.text.strip_edges()
			step = 2
			_rebuild()
	next.pressed.connect(go_next)
	le.text_submitted.connect(func(_t: String): go_next.call())


func _build_portrait() -> void:
	var back_b := Kit.back_button(130.0 * u)
	put_at(back_b, Vector2(mx(36, 130), 26))
	back_b.pressed.connect(func():
		step = 1
		_rebuild())
	var box := Rect2(160, 150, 2080, 900)
	var dlg := Kit.dialog(box.size * u, L.t("choose_portrait"), false)
	put_at(dlg, box.position)
	var r: Rect2 = dlg.get_meta("content")
	# you, big, on one side
	var side := Rect2(mx(60, 520, box.size.x), r.position.y / u + 30, 520, 600)
	var av := Kit.avatar(_portrait, 400.0 * u)
	av.position = Vector2(side.position.x + 60, side.position.y) * u
	dlg.add_child(av)
	var nm := Kit.label(_name, TS.TITLE * u, Kit.GOLD, "sans_bold", 520.0 * u)
	nm.position = Vector2(side.position.x, side.position.y + 420) * u
	dlg.add_child(nm)
	var photo := Kit.button(L.t("use_photo"), Vector2(460, 112) * u, "sapphire", "person")
	photo.position = Vector2(side.position.x + 30, side.position.y + 500) * u
	dlg.add_child(photo)
	photo.pressed.connect(func():
		PhotoPicker.pick(self, func(img: Image):
			if img:
				CropDialog.open(self, img, func(cut: Image):
					if cut:
						PhotoPicker.save(cut)
						_portrait = "custom"
						_rebuild.call_deferred())))
	var start := Kit.button(L.t("start"), Vector2(520, 136) * u, "emerald")
	put_at(start, Vector2((D.x - 520) * 0.5, box.end.y - 90))
	start.pressed.connect(_finish)
	# the portraits that are open at the start
	var gx := mx(700, 1250, box.size.x)
	var grid := scroll_area(Rect2(box.position.x + gx, box.position.y + r.position.y / u + 20, 1250, 600))
	var rating := int(Prefs.get_v("rating"))
	var faces := Portraits.all() if Portraits.available() else []
	if faces.is_empty():
		for pre in ["H", "M", "E", "D", "V"]:
			for k in 18:
				faces.append("%s-%02d" % [pre, k + 1])
	var per := 6
	var cell := 1250.0 / per
	for i in faces.size():
		var pid: String = faces[i]
		var b := portrait_tile(pid, cell - 24, pid == Portraits.resolve(_portrait), rating, func(p: String):
			_portrait = p
			_rebuild())
		var col := i % per
		if L.fa():
			col = per - 1 - col
		add_in(grid, b, Vector2(col * cell + 12, (i / per) * cell + 12))


func _finish() -> void:
	Prefs.set_v("name", _name.strip_edges())
	Prefs.set_v("portrait", _portrait if _portrait != "" else "M-04")
	Prefs.set_v("onboarded", true)
	go.emit("menu", null)
