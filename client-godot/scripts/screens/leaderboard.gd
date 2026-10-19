extends Screen
## The best players by rating, on painted rows: medals for the top three,
## your own ivory row pinned at the bottom. Live rankings come from the
## server once the client is online; until then a sample table.

const SAMPLE := [
	["Kaveh", "H-07", 1684, 212], ["Morad", "M-12", 1631, 187], ["Sahar", "M-17", 1598, 240],
	["Nima Arvand", "D-09", 1560, 133], ["Leila", "E-03", 1544, 158], ["Darius", "V-05", 1519, 97],
	["Shirin", "E-11", 1497, 120], ["Arash", "D-02", 1476, 88], ["Roya", "H-12", 1452, 143],
	["Bahram", "V-11", 1430, 76], ["Mina", "M-09", 1411, 102], ["Farhad", "D-14", 1398, 64],
	["Parisa", "E-07", 1380, 91], ["Kian", "H-03", 1366, 55], ["Yasmin", "V-02", 1349, 70],
]
const LIST := Rect2(300, 260, 1800, 590)

## The live board from the server, once fetched: [[name, portrait, rating, -1, me], ...]
static var _live: Array = []
static var _loaded := false
const ROW := Vector2(1800, 132)


func build() -> void:
	backdrop("screen_bg", 0.3)
	title_bar(L.t("leaderboard"))
	var live := Net.online and _loaded
	if not live:
		text(L.t("sample_board"), TS.CAPTION, Color(0.9, 0.66, 0.45), "serif", Rect2(0, 1032, D.x, 40))
	if Net.online:
		_fetch()
	# column titles
	var cols := [[L.t("col_rank"), 40, 140], [L.t("col_player"), 330, 600], [L.t("col_wins"), 1180, 200],
			[L.t("col_rating"), 1460, 260]]
	for c in cols:
		text(c[0], TS.CAPTION, Kit.MUTED, "title_bold", Rect2(LIST.position.x + mx(c[1], c[2], ROW.x), 222, c[2], 36))
	var content := scroll_area(LIST)
	var rows: Array = _live if live else SAMPLE
	var my_rank := 0
	for i in rows.size():
		_row(content, i + 1, rows[i], Vector2(0, i * (ROW.y + 14)), false)
		if live and rows[i].size() > 4 and rows[i][4]:
			my_rank = i + 1
	if live and rows.is_empty():
		text(L.t("board_empty"), TS.LABEL, Kit.MUTED, "serif", Rect2(LIST.position.x, LIST.position.y + 120, LIST.size.x, 80))
	# you, pinned under the list
	var pin := Control.new()
	pin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	put(pin, Vector2(LIST.position.x, LIST.end.y + 40), ROW)
	_row(pin, my_rank if live else 214, [Prefs.display_name(), String(Prefs.get_v("portrait")), int(Prefs.get_v("rating")), 0],
			Vector2.ZERO, true)


func _row(parent: Control, rank: int, p: Array, at: Vector2, mine: bool) -> void:
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.size = ROW * u
	holder.position = at * u
	parent.add_child(holder)
	if parent.get_parent() is ScrollContainer:
		parent.custom_minimum_size.y = maxf(parent.custom_minimum_size.y, holder.position.y + holder.size.y + 20.0 * u)
	holder.add_child(Kit.row(holder.size, mine))
	var ink := Kit.INK_DARK if mine else Kit.IVORY
	# rank: a medal for the top three, else the number
	var medal := Kit.tex("medal_%d" % rank) if rank >= 1 and rank <= 3 else null
	var rx := mx(100, 110, ROW.x)
	if medal:
		var m := TextureRect.new()
		m.texture = medal
		m.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		m.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		m.mouse_filter = Control.MOUSE_FILTER_IGNORE
		m.position = Vector2(rx, 11) * u
		m.size = Vector2(110, 110) * u
		holder.add_child(m)
	else:
		text(str(rank) if rank > 0 else "–", TS.NUM_M, Kit.GOLD if not mine else ink, "num", Rect2(rx, 0, 110, ROW.y), HORIZONTAL_ALIGNMENT_CENTER, holder)
	var av := Kit.avatar(String(p[1]), 110.0 * u)
	av.position = Vector2(mx(250, 110, ROW.x), 11) * u
	holder.add_child(av)
	text(String(p[0]), TS.LABEL, ink, "sans_bold", Rect2(mx(370, 560, ROW.x), 0, 560, ROW.y), start_align(), holder)
	text(str(p[3]) if not mine and int(p[3]) >= 0 else "–", TS.NUM_S, ink, "num", Rect2(mx(1180, 200, ROW.x), 0, 200, ROW.y),
			HORIZONTAL_ALIGNMENT_CENTER, holder)
	text(str(p[2]), TS.NUM_M, Kit.GOLD if not mine else ink, "num", Rect2(mx(1460, 260, ROW.x), 0, 260, ROW.y),
			HORIZONTAL_ALIGNMENT_CENTER, holder)


## The rating board from the server (players still provisional are not on it).
func _fetch() -> void:
	if has_meta("fetching"):
		return
	set_meta("fetching", true)
	var recs := await Api.leaderboard(100)
	var rows := []
	for r in recs:
		rows.append([String(r["name"]), String(r["portrait"]), int(r["rating"]), -1, r["me"]])
	var changed := not _loaded or rows != _live
	_live = rows
	_loaded = true
	if changed and is_inside_tree():
		_rebuild()
