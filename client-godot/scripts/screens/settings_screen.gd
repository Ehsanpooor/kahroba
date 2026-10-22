extends Screen
## Settings, saved on the device, on one painted dialog panel: the game and
## display on the left, sound on the right, help along the bottom. Every
## change applies at once.

const PANEL := Rect2(170, 210, 2060, 800)
const ROW_H := 120.0


func build() -> void:
	backdrop("screen_bg", 0.3)
	title_bar(L.t("settings"))
	put_at(Kit.panel(PANEL.size * u), PANEL.position)
	var col_w := 860.0
	var left := mx(PANEL.position.x + 110, col_w)
	var right := mx(PANEL.end.x - 110 - col_w, col_w)
	var y0 := PANEL.position.y + 90

	# left column: language, confirmations, brightness
	_label(L.t("language"), left, y0, col_w - 650)
	var lang := Kit.tabs(["فارسی", "English"], 0 if L.fa() else 1, Vector2(300, 100) * u, 20.0 * u, func(i: int):
		Prefs.set_v("lang", "fa" if i == 0 else "en")
		_rebuild.call_deferred())
	put_at(lang, Vector2(left + col_w - 620 if not L.fa() else left, y0 + 10))
	_toggle_row(L.t("set_confirm"), bool(Prefs.get_v("confirm_moves")), left, y0 + 1 * 170, col_w,
			func(on: bool): Prefs.set_v("confirm_moves", on))
	_slider_row(L.t("set_brightness"), float(Prefs.get_v("brightness")), 0.6, 1.4, left, y0 + 2 * 170, col_w,
			func(v: float): Prefs.set_v("brightness", v))

	# right column: music, sounds, vibration
	_slider_row(L.t("set_music"), float(Prefs.get_v("music")), 0.0, 1.0, right, y0, col_w,
			func(v: float): Prefs.set_v("music", v))
	_slider_row(L.t("set_sounds"), float(Prefs.get_v("sound")), 0.0, 1.0, right, y0 + 170, col_w,
			func(v: float): Prefs.set_v("sound", v))
	_toggle_row(L.t("set_vibration"), bool(Prefs.get_v("vibration")), right, y0 + 2 * 170, col_w,
			func(on: bool): Prefs.set_v("vibration", on))

	# help and the account along the bottom
	var items := [[L.t("how_to"), "onyx", "book", func(): go.emit("howto", null)],
			[L.t("set_tutorial"), "sapphire", "", func(): play.emit({"mode": "tutorial", "players": 2, "difficulty": "easy"})],
			[L.t("account"), "emerald", "person", _account],
			[L.t("set_reset"), "ruby", "", _ask_reset]]
	if L.fa():
		items.reverse()
	var bw := 460.0
	var gap := 40.0
	var bx := PANEL.position.x + (PANEL.size.x - items.size() * bw - (items.size() - 1) * gap) * 0.5
	for i in items.size():
		var it: Array = items[i]
		var b := Kit.button(it[0], Vector2(bw, 124) * u, it[1], it[2], 40.0 * u)
		put_at(b, Vector2(bx + i * (bw + gap), PANEL.end.y - 230))
		b.pressed.connect(it[3])
	var ver := String(ProjectSettings.get_setting("application/config/version", "0.9.0"))
	text("%s  •  %s %s  •  %s" % [L.t("game_title"), L.t("version"), ver, L.t("credits_line")], TS.CAPTION, Kit.MUTED, "serif",
			Rect2(PANEL.position.x, PANEL.end.y - 92, PANEL.size.x, 40))


func _label(t: String, x: float, y: float, w: float) -> void:
	text(t, TS.TITLE, Kit.IVORY, "serif_bold", Rect2(x if not L.fa() else x + 860 - w, y, w, ROW_H), start_align())


func _toggle_row(t: String, value: bool, x: float, y: float, w: float, on_change: Callable) -> void:
	_label(t, x, y, w - 300)
	var tg := Kit.toggle(value, Vector2(270, 102) * u, on_change)
	put_at(tg, Vector2(x + w - 270 if not L.fa() else x, y + 9))


func _slider_row(t: String, value: float, lo: float, hi: float, x: float, y: float, w: float, on_change: Callable) -> void:
	_label(t, x, y, 330)
	var s := Kit.slider(value, Vector2(500, 40) * u, on_change, lo, hi)
	put_at(s, Vector2(x + w - 500 if not L.fa() else x, y + 40))


## The account: its recovery email (add or change it), and recovering
## another account onto this device.
func _account() -> void:
	var email := String(Prefs.get_v("email"))
	var box := dialog(Vector2(1400, 640), L.t("account"))
	var w := dialog_w(box)
	dialog_text(box, L.t("email_is", email) if email != "" else L.t("email_none"), TS.LABEL,
			Kit.GOLD if email != "" else Color(0.95, 0.66, 0.45), "sans_bold", Rect2(0, 0, w, 80))
	var why := Kit.para(L.t("email_why_link"), TS.BODY * u, (w - 120.0) * u, Kit.IVORY)
	in_dialog(box, why, Vector2(60, 100))
	var bw := 500.0
	var gap := 60.0
	var x0 := (w - bw * 2 - gap) * 0.5
	var add := Kit.button(L.t("email_change") if email != "" else L.t("email_add"), Vector2(bw, 130) * u, "emerald", "", 44.0 * u)
	var rec := Kit.button(L.t("recover_btn"), Vector2(bw, 130) * u, "sapphire", "", 44.0 * u)
	in_dialog(box, add, Vector2(x0 + (bw + gap if L.fa() else 0.0), 300))
	in_dialog(box, rec, Vector2(x0 + (0.0 if L.fa() else bw + gap), 300))
	add.pressed.connect(func():
		if _need_server():
			EmailFlow.open(self, "link", func(_d: Dictionary): note(L.t("email_saved"))))
	rec.pressed.connect(func():
		if not _need_server():
			return
		if email != "":  # this device is already an account with its own email
			message(L.t("email_t_recover"), L.t("email_own"), [[L.t("ok"), "onyx", func(): pass]])
			return
		message(L.t("email_t_recover"), L.t("recover_q", int(Prefs.get_v("rating"))), [
			[L.t("cancel"), "onyx", func(): pass],
			[L.t("continue"), "sapphire", func():
				EmailFlow.open(self, "recover", func(_d: Dictionary):
					SavedGame.clear()
					_rebuild()
					note(L.t("email_recovered", Prefs.display_name())))],
		]))


func _need_server() -> bool:
	if Net.online:
		return true
	message(L.t("no_server_t"), L.t("no_server_body"), [[L.t("ok"), "onyx", func(): pass]])
	return false


## Forget this device's profile, settings and games, and begin again.
func _ask_reset() -> void:
	message(L.t("set_reset_q"), L.t("set_reset_body"), [
		[L.t("cancel"), "onyx", func(): pass],
		[L.t("set_reset"), "ruby", func():
			Prefs.reset_all()
			go.emit("splash", null)],
	])
