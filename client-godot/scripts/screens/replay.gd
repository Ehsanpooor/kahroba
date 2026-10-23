extends Screen
## Every move of one finished game, in order, on painted rows: who took
## which gems, who bought or reserved what, which noble visited whom. The
## final standing on top; tabs to follow one player.

const LIST := Rect2(300, 470, 1800, 590)
const ROW := Vector2(1800, 118)

var _who := -1  # -1 everyone, else a seat


func build() -> void:
	backdrop("screen_bg", 0.3)
	title_bar(L.t("replay"))
	var g: Dictionary = arg if arg is Dictionary else {}
	var seats: Array = g.get("seats", [])
	var n := seats.size()
	var best := -1
	for s in seats:
		best = maxi(best, int(s.get("power", 0)))
	for k in n:
		var s: Dictionary = seats[k]
		var x := D.x * 0.5 + (k - (n - 1) * 0.5) * 300.0
		var av := Kit.avatar(String(s.get("portrait", "H-01")), 120.0 * u)
		put_at(av, Vector2(x - 150, 200))
		text(String(s.get("name", "")).get_slice(" ", 0), TS.BODY, Kit.GOLD if k == 0 else Kit.IVORY, "sans_bold",
				Rect2(x - 20, 200, 180, 60), start_align())
		text(str(int(s.get("power", 0))), TS.NUM_M, Kit.GOLD if int(s.get("power", 0)) == best else Kit.MUTED, "num",
				Rect2(x - 20, 258, 180, 60), start_align())
	var names := [L.t("all")]
	for s in seats:
		names.append(String(s.get("name", "")).get_slice(" ", 0))
	var cw := minf(300.0, 1700.0 / names.size() - 20.0)
	var tabs := Kit.tabs(names, _who + 1, Vector2(cw, 90) * u, 20.0 * u, func(i: int):
		_who = i - 1
		_rebuild.call_deferred())
	put_at(tabs, Vector2((D.x - tabs.size.x / u) * 0.5, 350))
	var content := scroll_area(LIST)
	var moves: Array = g.get("moves", [])
	var y := 0.0
	for m in moves:
		var seat := int(m.get("seat", 0))
		if _who >= 0 and seat != _who:
			continue
		_move_row(content, m, seats[seat] if seat < n else {}, y, seat == 0)
		y += ROW.y + 12
	if moves.is_empty():
		text(L.t("no_moves"), TS.TITLE, Kit.MUTED, "serif", Rect2(0, 650, D.x, 80))


func _move_row(content: Control, m: Dictionary, s: Dictionary, y: float, mine: bool) -> void:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_in(content, holder, Vector2(0, y), ROW)
	holder.add_child(Kit.row(holder.size, mine))
	var ink := Kit.INK_DARK if mine else Kit.IVORY
	text(str(int(m.get("turn", 0))), TS.NUM_S, Kit.MUTED if not mine else ink, "num", Rect2(mx(70, 100, ROW.x), 0, 100, ROW.y),
			HORIZONTAL_ALIGNMENT_CENTER, holder)
	var av := Kit.avatar(String(s.get("portrait", "H-01")), 94.0 * u)
	av.position = Vector2(mx(190, 94, ROW.x), 12) * u
	holder.add_child(av)
	var who := String(s.get("name", "")).get_slice(" ", 0)
	var kind := String(m.get("kind", ""))
	var what: String = {
		"coins": L.t("mv_coins", who), "buy": L.t("mv_buy", who), "buy_reserved": L.t("mv_buy_res", who),
		"reserve": L.t("mv_reserve", who), "reserve_blind": L.t("mv_reserve_blind", who, int(m.get("tier", 1))),
		"noble": L.t("mv_noble", who), "skip": L.t("mv_skip", who), "timeout": L.t("mv_timeout", who),
		"return": L.t("mv_return", who),
	}.get(kind, "%s: %s" % [who, kind])
	text(what, TS.LABEL, Kit.GOLD if kind == "noble" else ink, "sans_bold", Rect2(mx(320, 760, ROW.x), 0, 760, ROW.y),
			start_align(), holder)
	# the gems taken, or the card bought / reserved
	var x := 1120.0
	for c in m.get("colors", []):
		var tok := Gems.token_tex(String(c))
		if tok:
			var r := TextureRect.new()
			r.texture = tok
			r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			r.mouse_filter = Control.MOUSE_FILTER_IGNORE
			r.position = Vector2(mx(x, 84, ROW.x), 17) * u
			r.size = Vector2(84, 84) * u
			holder.add_child(r)
			x += 96.0
	var cid := String(m.get("card", ""))
	if GameData.CARDS.has(cid):
		var d: Dictionary = GameData.CARDS[cid]
		var art := Gems.card_art(String(d["element"]), int(d["tier"]))
		if art:
			var r := TextureRect.new()
			r.texture = art
			r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			r.clip_contents = true
			r.mouse_filter = Control.MOUSE_FILTER_IGNORE
			r.position = Vector2(mx(1120, 130, ROW.x), 14) * u
			r.size = Vector2(130, 90) * u
			holder.add_child(r)
		var gem := Kit.gem(String(d["element"]), 60.0 * u)
		gem.position = Vector2(mx(1270, 60, ROW.x), 29) * u
		holder.add_child(gem)
	var pw := int(m.get("power", -1))
	if pw >= 0:
		text(str(pw), TS.NUM_M, Kit.GOLD if not mine else ink, "num", Rect2(mx(1560, 160, ROW.x), 0, 160, ROW.y),
				HORIZONTAL_ALIGNMENT_CENTER, holder)
