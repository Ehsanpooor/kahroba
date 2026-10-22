class_name EmailFlow
extends RefCounted
## The recovery email, on a screen's dialogs: type the address, get a six-digit
## code by email, type it on the keypad. Purpose "link" adds the email to this
## account; "recover" brings the account of that email to this device (Api
## then holds its name, portrait and rating). on_done(data) runs on success.

const ERR := Color(0.95, 0.66, 0.45)


## Step 1: the address. The dialog sits high, clear of the phone's keyboard.
static func open(s: Screen, purpose: String, on_done: Callable) -> void:
	var box := s.dialog(Vector2(1500, 660), L.t("email_t_" + purpose))
	box.position.y = float(box.get_meta("above")) + 8.0 * s.u
	var w := s.dialog_w(box)
	var why := Kit.para(L.t("email_why_" + purpose), TS.BODY * s.u, (w - 80.0) * s.u, Kit.IVORY)
	s.in_dialog(box, why, Vector2(40, 0))
	var fw := 1000.0
	var fpos := Vector2((w - fw) * 0.5, 120)
	var field := Kit.tex("input_field")
	if field:
		s.in_dialog(box, Kit.strip(field, Vector2(fw, 130) * s.u, 0.08), fpos)
	var le := LineEdit.new()
	le.text = String(Prefs.get_v("email")) if purpose == "link" else ""
	le.placeholder_text = L.t("email_hint")
	le.max_length = 120
	le.alignment = HORIZONTAL_ALIGNMENT_CENTER
	le.text_direction = Control.TEXT_DIRECTION_LTR
	le.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_EMAIL_ADDRESS
	le.add_theme_font_override("font", Fonts.get_font("sans_bold"))
	le.add_theme_font_size_override("font_size", int(TS.LABEL * s.u))
	le.add_theme_color_override("font_color", Kit.INK_DARK)
	le.add_theme_color_override("font_placeholder_color", Color(0.45, 0.38, 0.3))
	le.add_theme_color_override("caret_color", Kit.INK_DARK)
	for st in ["normal", "focus", "read_only"]:
		le.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	s.in_dialog(box, le, fpos + Vector2(50, 12), Vector2(fw - 100, 106))
	var note := s.dialog_text(box, "", TS.BODY, ERR, "serif", Rect2(0, 262, w, 56))
	var send := Kit.button(L.t("email_send"), Vector2(520, 130) * s.u, "emerald", "", 46.0 * s.u)
	s.in_dialog(box, send, Vector2((w - 520) * 0.5, 335))
	var ok := func(t: String) -> bool: return t.strip_edges().contains("@") and t.strip_edges().length() >= 6
	Kit.set_enabled(send, ok.call(le.text))
	le.text_changed.connect(func(t: String):
		note.text = ""
		Kit.set_enabled(send, ok.call(t)))
	var go := func():
		var email := le.text.strip_edges().to_lower()
		if not ok.call(email):
			note.text = L.t("email_bad")
			return
		le.release_focus()
		Kit.set_enabled(send, false)
		note.add_theme_color_override("font_color", Kit.MUTED)
		note.text = L.t("email_sending")
		var r := await Api.email_send_code(email, purpose)
		if not is_instance_valid(note):
			return
		note.add_theme_color_override("font_color", ERR)
		Kit.set_enabled(send, true)
		if r["ok"]:
			if bool(r["data"].get("already", false)):  # it is this account's email already
				Prefs.set_v("email", email)
				s.close_dialog()
				on_done.call({"email": email})
			else:
				_code_step(s, purpose, email, on_done)
			return
		note.text = _send_error(r)
	send.pressed.connect(go)
	le.text_submitted.connect(func(_t: String): go.call())
	if not L.fa() or le.text == "":
		le.grab_focus.call_deferred()


## Step 2: the code from the email, on the game's keypad.
static func _code_step(s: Screen, purpose: String, email: String, on_done: Callable) -> void:
	var box := s.dialog(Vector2(1640, 780), L.t("email_t_" + purpose))
	var w := s.dialog_w(box)
	var left_w := 820.0
	var lx := 0.0 if not L.fa() else w - left_w
	var kx := left_w + 40.0 if not L.fa() else 0.0
	var told := Kit.para(L.t("email_code_sent", email), TS.CAPTION * s.u, left_w * s.u, Kit.IVORY)
	s.in_dialog(box, told, Vector2(lx, 0))
	var note := s.dialog_text(box, "", TS.BODY, ERR, "serif", Rect2(lx, 300, left_w, 50))
	var confirm := Kit.button(L.t("email_confirm"), Vector2(460, 124) * s.u, "emerald", "", 46.0 * s.u)
	s.in_dialog(box, confirm, Vector2(lx + (left_w - 460) * 0.5, 365))
	var again := Kit.button(L.t("email_resend"), Vector2(460, 104) * s.u, "onyx", "", 36.0 * s.u)
	s.in_dialog(box, again, Vector2(lx + (left_w - 460) * 0.5, 510))
	var pad := {}
	var check := func(code: String):
		if code.length() != 6:
			return
		Kit.set_enabled(confirm, false)
		note.text = ""
		var r := await Api.email_verify(email, code, purpose)
		if not is_instance_valid(note):
			return
		if r["ok"]:
			s.close_dialog()
			on_done.call(r["data"])
			return
		match int(r["code"]):
			3:
				var left := String(r["message"]).get_slice("=", 1)
				note.text = L.t("email_wrong", left if left.is_valid_int() else "?")
			4:
				note.text = L.t("email_expired")
			6:
				note.text = L.t("email_taken")
			9:
				s.close_dialog()
				s.message(L.t("email_t_recover"), L.t("email_own"), [[L.t("ok"), "onyx", func(): pass]])
				return
			_:
				note.text = L.t("no_server_body") if int(r["code"]) == 0 else L.t("email_unavailable")
		pad["code"] = ""
		pad["show"].call()
	pad = s.pin_pad(box, Rect2(lx + (left_w - 700) * 0.5, 150, 700, 130), kx, w - left_w - 40.0,
			func(code: String, msg: String):
				note.text = msg
				Kit.set_enabled(confirm, code.length() == 6)
				if code.length() == 6 and msg == "":
					check.call(code),
			check)
	Kit.set_enabled(confirm, false)
	confirm.pressed.connect(func(): check.call(pad["code"]))
	# "send again" wakes after a minute
	var wait := [60]
	var tick := func():
		while is_instance_valid(again) and wait[0] > 0:
			(again.get_meta("label") as Label).text = L.t("email_resend_in", wait[0]) if again.has_meta("label") else ""
			Kit.set_enabled(again, false)
			await s.get_tree().create_timer(1.0).timeout
			wait[0] -= 1
		if is_instance_valid(again):
			if again.has_meta("label"):
				(again.get_meta("label") as Label).text = L.t("email_resend")
			Kit.set_enabled(again, true)
	tick.call()
	again.pressed.connect(func():
		Kit.set_enabled(again, false)
		var r := await Api.email_send_code(email, purpose)
		if not is_instance_valid(note):
			return
		if r["ok"]:
			note.add_theme_color_override("font_color", Kit.MUTED)
			note.text = L.t("email_code_sent", email).get_slice("\n", 0)
			wait[0] = 60
			tick.call()
		else:
			note.add_theme_color_override("font_color", ERR)
			note.text = _send_error(r)
			Kit.set_enabled(again, true))


static func _send_error(r: Dictionary) -> String:
	match int(r["code"]):
		0:
			return L.t("no_server_body")
		3:
			return L.t("email_bad")
		5:
			return L.t("email_unknown")
		6:
			return L.t("email_taken")
		8:
			var secs := String(r["message"]).get_slice("=", 1).to_int()
			return L.t("email_today") if secs >= 3600 else L.t("email_wait", maxi(secs, 1))
	return L.t("email_unavailable")
