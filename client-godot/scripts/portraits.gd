class_name Portraits
extends RefCounted
## The avatars a player may wear: 32 Renaissance gem-merchant portraits,
## A-01 (apprentices) to A-30 (merchant princes), then Fereshteh (A-31, an
## upper-middle merchant, opens at 1400) and Homa (A-32, the grandest of all,
## opens at 2200). The first ten are open from the start; the rest open as the
## player's rating rises (ratings start at 1000). Character ids of the first build (H-07, M-12, ...) still saved on a device
## or in a game are shown as one of the new avatars.

const COUNT := 32
## [rating needed, avatars open from A-01 up to this number] (A-01 to A-30)
const UNLOCKS := [[0, 10], [1100, 13], [1200, 16], [1400, 20], [1600, 25], [2000, 30]]
## The avatars added later, each with its own rating.
const EXTRA := {31: 1400, 32: 2200}

## The computer players: each wears its own avatar, its name is "bot_<id>".
const BOTS := ["A-01", "A-02", "A-03", "A-04", "A-05", "A-32", "A-31", "A-07", "A-08", "A-09", "A-10", "A-11", "A-12", "A-13", "A-14", "A-15", "A-16", "A-17", "A-18", "A-19"]
## The old faces they wear until the new avatars are all in.
const BOT_FALLBACK := ["M-12", "M-17", "H-07", "D-09"]
## Cosimo, the old merchant who teaches the first game.
const GUIDE := "A-20"


static func guide() -> String:
	return GUIDE if available() else "H-10"


static func available() -> bool:
	return ResourceLoader.exists("res://assets/portraits/A-%02d.png" % COUNT)  # only once all are in


## Every avatar id, in order of the rating that opens it.
static func all() -> Array:
	var ks := range(1, COUNT + 1)
	ks.sort_custom(func(a: int, b: int) -> bool:
		return rating_for(a) < rating_for(b) or (rating_for(a) == rating_for(b) and a < b))
	return ks.map(func(k: int) -> String: return "A-%02d" % k)


## A saved id as a new avatar: old character ids map to a fixed new one.
static func resolve(pid: String) -> String:
	if pid == "custom":
		return pid
	if not available():  # until all 30 are in, a new id shows an old face
		if pid.begins_with("A-"):
			return BOT_FALLBACK[(int(pid.substr(2)) - 1) % BOT_FALLBACK.size()]
		return pid
	if pid.begins_with("A-"):
		return pid
	if pid.length() >= 4 and pid[1] == "-":
		return "A-%02d" % (absi(pid.hash()) % 10 + 1)  # an open one
	return pid


static func open_count(rating: int) -> int:
	var n := 0
	for step in UNLOCKS:
		if rating >= int(step[0]):
			n = int(step[1])
	return n


## The rating that opens avatar number `k` (1-based).
static func rating_for(k: int) -> int:
	if EXTRA.has(k):
		return int(EXTRA[k])
	for step in UNLOCKS:
		if k <= int(step[1]):
			return int(step[0])
	return 99999


static func is_open(pid: String, rating: int) -> bool:
	if pid == "custom" or pid.length() < 4:
		return true
	return rating >= rating_for(int(pid.substr(2)))
