class_name SavedGame
extends RefCounted
## The game in progress, kept on the device at the start of every turn, so
## it can be continued after the app closes (a game against the computer) or
## rejoined after the connection drops (an online or friends game). Finishing
## or leaving a game forgets it. The tutorial and the demo are never kept.
##
## Saved with store_var, so numbers stay ints and cards stay dictionaries.

const PATH := "user://last_game.dat"
const VERSION := 1
## An online seat is kept by the server this long after a drop; later the
## game has gone on without you.
const REJOIN_SECONDS := 15 * 60

const KEYS := ["mode", "difficulty", "win_points", "first_seat", "round_no", "turn", "final_round",
		"bank_counts", "me", "opps", "board_cards", "decks", "noble_data", "noble_owner", "moves", "match_id"]


static func save(board: Node) -> void:
	var d := {"version": VERSION, "saved_at": int(Time.get_unix_time_from_system())}
	for k in KEYS:
		d[k] = board.get(k)
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f:
		f.store_var(d)


## The saved game, or {} when there is none (or it can no longer be played).
static func read() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return {}
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return {}
	var v: Variant = f.get_var()
	if not (v is Dictionary) or int((v as Dictionary).get("version", 0)) != VERSION:
		return {}
	var d: Dictionary = v
	if is_online(d) and age(d) > REJOIN_SECONDS:
		clear()  # the table has moved on without you
		return {}
	return d


static func exists() -> bool:
	return not read().is_empty()


static func clear() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


static func is_online(d: Dictionary) -> bool:
	return String(d.get("mode", "")) in ["online", "friends"]


static func age(d: Dictionary) -> int:
	return int(Time.get_unix_time_from_system()) - int(d.get("saved_at", 0))


## Put a saved game back on the board (before it is built).
static func restore(board: Node, d: Dictionary) -> void:
	for k in KEYS:
		if d.has(k):
			board.set(k, d[k])
