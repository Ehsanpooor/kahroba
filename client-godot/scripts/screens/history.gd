extends Screen
## Your finished games, newest first, on painted rows: a win or loss badge,
## the kind of game and when, the other players, your prestige and rating
## change. The newest three keep every move: REPLAY opens them. Before the
## first game: a short word that the games will gather here, and Play.

const LIST := Rect2(260, 330, 1880, 720)
const ROW := Vector2(1880, 170)

var _filter := 0  # 0 all, 1 online, 2 computer
var _games: Array = []


func build() -> void:
	backdrop("screen_bg", 0.3)
	title_bar(L.t("history"))
	_games = Prefs.history()
	if _games.is_empty():
		_empty()
		return
	var tabs := Kit.tabs([L.t("all"), L.t("mode_online"), L.t("computer")], _filter, Vector2(300, 96) * u, 24.0 * u,
			func(i: int):
				_filter = i
				_rebuild.call_deferred())
	put_at(tabs, Vector2((D.x - tabs.size.x / u) * 0.5, 220))
	var content := scroll_area(LIST)
	var y := 0.0
	for g in _games:
		var mode := String(g.get("mode", "ai"))
		if (_filter == 1 and mode != "online") or (_filter == 2 and mode != "ai"):
			continue
		_row(content, g, y)
		y += ROW.y + 16
	if y == 0.0:
		text(L.t("no_games"), TS.TITLE, Kit.MUTED, "serif", Rect2(0, 500, D.x, 80))


func _row(content: Control, g: Dictionary, y: float) -> void:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_in(content, holder, Vector2(0, y), ROW)
	holder.add_child(Kit.row(holder.size, false))
	var win := String(g.get("result", "loss")) == "win"
	# result badge
	var badge := Kit.tex("badge_win" if win else "badge_loss")
	var bx := mx(90, 220, ROW.x)
	if badge:
		var b := TextureRect.new()
		b.texture = badge
		b.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		b.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.position = Vector2(bx, 30) * u
		b.size = Vector2(220, 110) * u
		holder.add_child(b)
	else:
		var p := Kit.plate("emerald" if win else "ruby", Vector2(220, 96) * u)
		p.position = Vector2(bx, 37) * u
		holder.add_child(p)
	text(L.t("win") if win else L.t("loss"), TS.LABEL, Kit.GOLD, "title_bold", Rect2(bx + 20, 30, 180, 110),
			HORIZONTAL_ALIGNMENT_CENTER, holder)
	# what kind of game, and when
	var mode := String(g.get("mode", "ai"))
	var title := L.t("rated_game") if mode == "online" else (L.t("friends_game") if mode == "friends"
			else L.t("ai_game", L.t(String(g.get("difficulty", "normal")))))
	text(title, TS.LABEL, Kit.IVORY, "sans_bold", Rect2(mx(350, 520, ROW.x), 28, 520, 60), start_align(), holder)
	text(_ago(int(g.get("played_at", 0))), TS.BODY, Kit.MUTED, "sans", Rect2(mx(350, 520, ROW.x), 86, 520, 54),
			start_align(), holder)
	# the other players
	var seats: Array = g.get("seats", [])
	for k in range(1, seats.size()):
		var av := Kit.avatar(String(seats[k].get("portrait", "H-01")), 100.0 * u)
		av.position = Vector2(mx(900 + (k - 1) * 90.0, 100, ROW.x), 35) * u
		holder.add_child(av)
	# prestige (and the rating change online)
	text(str(int(g.get("power", 0))), TS.NUM_L, Kit.GOLD, "num", Rect2(mx(1260, 160, ROW.x), 18, 160, 90),
			HORIZONTAL_ALIGNMENT_CENTER, holder)
	text(L.t("prestige"), TS.CAPTION, Kit.MUTED, "sans", Rect2(mx(1260, 160, ROW.x), 104, 160, 40),
			HORIZONTAL_ALIGNMENT_CENTER, holder)
	if mode == "online":
		var d := int(g.get("rating_delta", 0))
		text(("+%d" % d) if d >= 0 else str(d), TS.NUM_S, Color(0.55, 0.95, 0.55) if d >= 0 else Color(1.0, 0.5, 0.45),
				"num", Rect2(mx(1430, 120, ROW.x), 0, 120, ROW.y), HORIZONTAL_ALIGNMENT_CENTER, holder)
	if g.has("moves"):
		var rb := Kit.button(L.t("replay"), Vector2(260, 100) * u, "sapphire", "", 34.0 * u)
		rb.position = Vector2(mx(1560, 260, ROW.x), 35) * u
		holder.add_child(rb)
		rb.pressed.connect(func(): go.emit("replay", g))


func _ago(t: int) -> String:
	if t <= 0:
		return ""
	var d := int(Time.get_unix_time_from_system()) - t
	if d < 3600:
		return L.t("min_ago", maxi(d / 60, 1))
	if d < 86400:
		return L.t("h_ago", d / 3600)
	var dt := Time.get_datetime_dict_from_unix_time(t)
	return "%d/%02d/%02d" % [dt["year"], dt["month"], dt["day"]]


## No game played yet: three gems resting, the word, and the way to a game.
func _empty() -> void:
	put_at(Kit.gem_row(520.0 * u, 70.0 * u), Vector2((D.x - 520) * 0.5, 330))
	text(L.t("no_games"), TS.TITLE, Kit.GOLD, "title_bold", Rect2(0, 440, D.x, 90))
	text(L.t("no_games_sub"), TS.BODY, Kit.IVORY, "serif", Rect2(0, 540, D.x, 60))
	var b := Kit.button(L.t("play"), Vector2(560, 140) * u, "emerald", "", 56.0 * u)
	put_at(b, Vector2((D.x - 560) * 0.5, 680))
	b.pressed.connect(func(): go.emit("play", null))
