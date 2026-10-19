extends Screen
## The opening: on the dark hall, the gem emblem settles in, the five gems
## catch the light one by one, the name rises in gold beneath; then the menu
## (or the first start). A tap skips it.

var _done := false


func build() -> void:
	Sfx.music(true, "menu")
	backdrop("menu_bg", 0.75)
	var logo := Kit.tex("logo_splendor")
	if logo:
		_logo_intro(logo)
		return
	var emblem := Kit.tex("logo_emblem")
	var top: Control
	if emblem:
		var r := TextureRect.new()
		r.texture = emblem
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		put(r, Vector2((D.x - 760) * 0.5, 110), Vector2(760, 560))
		top = r
	else:
		top = Kit.gem_row(900.0 * u, 120.0 * u)
		put_at(top, Vector2((D.x - 900) * 0.5, 380))
	top.pivot_offset = top.size * 0.5
	top.modulate.a = 0.0
	top.scale = Vector2.ONE * 0.85
	var name_l := text(L.t("game_title"), 170.0, Kit.GOLD, "title_bold", Rect2(0, 660, D.x, 210))
	var sm := ShaderMaterial.new()
	sm.shader = preload("res://shaders/shine.gdshader")
	name_l.material = sm
	name_l.modulate.a = 0.0
	var sub := text(L.t("game_sub"), TS.TITLE, Kit.IVORY, "title_bold", Rect2(0, 860, D.x, 70))
	sub.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_interval(0.2)
	tw.tween_property(top, "modulate:a", 1.0, 0.5)
	tw.parallel().tween_property(top, "scale", Vector2.ONE, 0.8).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(name_l, "modulate:a", 1.0, 0.45)
	tw.tween_method(func(p: float): sm.set_shader_parameter("progress", p), -0.2, 1.2, 0.9)
	tw.parallel().tween_property(sub, "modulate:a", 1.0, 0.5)
	tw.tween_interval(0.7)
	tw.tween_callback(_finish)


## With the painted logo: it settles in the middle, a band of light sweeps
## across it, the subtitle follows.
func _logo_intro(logo: Texture2D) -> void:
	var r := TextureRect.new()
	r.texture = logo
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	put(r, Vector2((D.x - 1500) * 0.5, 180), Vector2(1500, 600))
	r.pivot_offset = r.size * 0.5
	r.modulate.a = 0.0
	r.scale = Vector2.ONE * 0.9
	var sm := ShaderMaterial.new()
	sm.shader = preload("res://shaders/shine.gdshader")
	r.material = sm
	var sub := text(L.t("game_sub"), TS.TITLE, Kit.IVORY, "title_bold", Rect2(0, 800, D.x, 70))
	sub.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_interval(0.2)
	tw.tween_property(r, "modulate:a", 1.0, 0.6)
	tw.parallel().tween_property(r, "scale", Vector2.ONE, 0.9).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(p: float): sm.set_shader_parameter("progress", p), -0.2, 1.2, 1.0)
	tw.parallel().tween_property(sub, "modulate:a", 1.0, 0.5)
	tw.tween_interval(0.7)
	tw.tween_callback(_finish)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		_finish()


func _finish() -> void:
	if _done:
		return
	_done = true
	go.emit("menu" if Prefs.get_v("onboarded") else "welcome", null)
