extends Node
## Headless AI arena (`-- --aiarena`): the computer levels play many fast
## games against each other (no table, no animation: AIBrain decides, a rules
## simulator here plays the move) and the win rates are printed.
##
## Options (after `--`):
##   --games=N                 games per match (default 200)
##   --match=a:b[:c[:d]]       one match only (repeatable), e.g. very_hard:hard or
##                             hard:normal:normal:normal; without it a standard set runs
##   --duel=a:b                a against b on fixed deals, each played from both seats
##   --win=15                  target prestige
##   --set=name:level:w_x=1,.. a test level: `level` with some weights changed
##   --tune=level [--pool=a:b] [--iters=N]  hill-climb that level's weights
##   --trace                   print every move (with --games=1)
##   --bench                   time the brain's parts
## Levels: legacy (the old computer), easy, normal, hard, very_hard.
## Seats rotate, so every level starts equally often. A game that runs past
## 120 rounds (or where everyone passes) counts as stalled: nobody wins it.

const TIER_OF_ROW := [1, 2, 3]
const MAX_COINS := 10
const RESERVE_MAX := 3

var games := 200
var win := 15
var illegal := 0
var trace := false
var pool := ["legacy"]
var nohide := OS.get_cmdline_user_args().has("--nohide")
var margin := 0.02
var time_us := {}  # level -> [total us, moves, max us]


func _ready() -> void:
	await get_tree().process_frame
	AIBrain.prepare()
	var matches: Array = []
	var tune := ""
	var duels := []
	var iters := 40
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--tune="):
			tune = a.get_slice("=", 1)
		elif a.begins_with("--duel="):
			duels.append(a.get_slice("=", 1).split(":"))
		elif a.begins_with("--pool="):
			pool = Array(a.get_slice("=", 1).split(":"))
		elif a.begins_with("--margin="):
			margin = float(a.get_slice("=", 1))
		elif a.begins_with("--iters="):
			iters = int(a.get_slice("=", 1))
		elif a.begins_with("--set="):  # --set=level:base:param=v,param=v
			var parts := a.substr(a.find("=") + 1).split(":")
			var o := {"base": parts[1]}
			for kv in parts[2].split(","):
				o[kv.get_slice("=", 0)] = float(kv.get_slice("=", 1))
			AIBrain.overrides[parts[0]] = o
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--games="):
			games = int(a.get_slice("=", 1))
		elif a == "--trace":
			trace = true
		elif a.begins_with("--win="):
			win = int(a.get_slice("=", 1))
		elif a.begins_with("--match="):
			matches.append(Array(a.get_slice("=", 1).split(":")))
	if OS.get_cmdline_user_args().has("--bench"):
		_bench()
		get_tree().quit()
		return
	if tune != "":
		_tune(tune, iters)
		get_tree().quit()
		return
	for ab in duels:  # each deal from both seats, the same deals every run
		print("duel %s vs %s: %.3f" % [ab[0], ab[1], _duel(ab[0], ab[1], games / 2, 99)])
	if not duels.is_empty() and matches.is_empty():
		_print_times()
		get_tree().quit()
		return
	if matches.is_empty():
		matches = [["normal", "legacy"], ["hard", "normal"], ["very_hard", "hard"],
				["very_hard", "legacy"], ["easy", "legacy"],
				["very_hard", "hard", "hard", "hard"], ["hard", "normal", "normal", "normal"],
				["normal", "legacy", "legacy", "legacy"], ["very_hard", "hard", "normal", "legacy"]]
	var t0 := Time.get_ticks_msec()
	for m in matches:
		_run_match(m)
	_print_times()
	print("arena done in %.0f s" % ((Time.get_ticks_msec() - t0) / 1000.0))
	get_tree().quit()


func _print_times() -> void:
	print("illegal moves: ", illegal)
	for lv in time_us:
		var t: Array = time_us[lv]
		print("time %-9s  avg %.1f ms  max %.1f ms  (%d moves, %.0f seat evaluations a move)" % [lv, t[0] / maxf(t[1], 1) / 1000.0, t[2] / 1000.0, t[1], t[3] / maxf(t[1], 1)])


## `levels` by seat; games rotate who sits where.
func _run_match(levels: Array) -> void:
	var n := levels.size()
	var wins := {}
	var plays := {}
	for lv in levels:
		wins[lv] = 0.0
		plays[lv] = 0
	var rounds := 0
	var draws := 0
	var t0 := Time.get_ticks_msec()
	for gi in games:
		# rotate the seating: game gi puts levels[(k + gi) % n] at seat k, seat 0 starts
		var seats := []
		for k in n:
			seats.append(levels[(k + gi) % n])
		var r := _play(seats)
		rounds += int(r["rounds"])
		var winners: Array = r["winners"]
		if winners.is_empty():
			draws += 1
		for w in winners:
			wins[seats[w]] += 1.0 / winners.size()
		for lv in seats:
			plays[lv] += 1
	var line := "%s (%dp, %d games, win %d):" % [":".join(levels), n, games, win]
	var seen := {}
	for lv in levels:
		if seen.has(lv):
			continue
		seen[lv] = true
		# a level in several seats: its share per seat
		var per_seat: float = wins[lv] / float(plays[lv])
		line += "  %s %.1f%%" % [lv, per_seat * 100.0]
	line += "  | avg rounds %.1f, stalled %d, %.0f s" % [float(rounds) / games, draws, (Time.get_ticks_msec() - t0) / 1000.0]
	print(line)


func _new_game(n: int) -> Dictionary:
	var decks := {1: [], 2: [], 3: []}
	for d in GameData.CARDS.values():
		(decks[int(d["tier"])] as Array).append((d as Dictionary).duplicate(true))
	for t in decks:
		(decks[t] as Array).shuffle()
	var board := []
	for r in 3:
		for c in 4:
			board.append((decks[TIER_OF_ROW[r]] as Array).pop_back())
	var all: Array = GameData.ARTIFACTS.duplicate(true)
	all.shuffle()
	var nobles: Array = all.slice(0, n + 1)
	var per: int = {2: 4, 3: 5, 4: 7}[n]
	var bank := {"gold": 5}
	for c in Gems.COLORS:
		bank[c] = per
	var players := []
	for k in n:
		players.append({
			"prestige": 0,
			"cards": {"white": 0, "blue": 0, "green": 0, "red": 0, "black": 0},
			"coins": {"white": 0, "blue": 0, "green": 0, "red": 0, "black": 0, "gold": 0},
			"reserved": [],
		})
	var free := []
	for k in nobles.size():
		free.append(true)
	return {"decks": decks, "board": board, "nobles": nobles, "noble_free": free, "bank": bank, "players": players}


func _play(seats: Array) -> Dictionary:
	var n := seats.size()
	var g := _new_game(n)
	var final_round := false
	var turn := 0
	var rounds := 0
	var passes := 0
	while true:
		if turn == 0:
			rounds += 1
		if rounds > 120:
			return {"winners": [], "rounds": rounds}
		var seen := []  # what this seat can see: others' blind reserves stay hidden
		for k in n:
			var q: Dictionary = g["players"][k]
			var res := []
			for d in q["reserved"]:
				res.append({"hidden": true} if k != turn and d.has("_blind") and not nohide else d)
			seen.append({"coins": q["coins"], "cards": q["cards"], "prestige": q["prestige"], "reserved": res})
		var snap := {
			"bank": g["bank"], "board": g["board"],
			"decks": {1: g["decks"][1].size(), 2: g["decks"][2].size(), 3: g["decks"][3].size()},
			"nobles": g["nobles"], "noble_free": g["noble_free"], "players": seen,
			"seat": turn, "first_seat": 0, "final_round": final_round, "win_points": win,
			"difficulty": seats[turn],
		}
		var brain := AIBrain.new()
		brain.load_snapshot(snap)
		brain.rng.seed = randi()  # the arena's deals and choices follow seed()
		brain.debug = trace and seats[turn] != "legacy"
		var dec := brain.decide()
		var lv: String = seats[turn]
		if not time_us.has(lv):
			time_us[lv] = [0.0, 0.0, 0.0, 0.0]
		time_us[lv][0] += brain.last_us
		time_us[lv][1] += 1
		time_us[lv][2] = maxf(time_us[lv][2], brain.last_us)
		time_us[lv][3] += brain.evals
		if trace:
			var pp: Dictionary = g["players"][turn]
			print("r%d s%d %s  pts %d  cards %s coins %s res %d  -> %s %s" % [rounds, turn, lv, pp["prestige"], pp["cards"].values(), pp["coins"].values(), pp["reserved"].size(), dec,
					(g["board"][dec["index"]]["id"] + " pts" + str(g["board"][dec["index"]]["points"])) if dec.has("index") else ""])
		if not _do(g, turn, dec):
			illegal += 1
			printerr("ILLEGAL by ", lv, ": ", dec)
		passes = passes + 1 if dec["kind"] == "skip" else 0
		if passes >= n * 2:
			return {"winners": [], "rounds": rounds}
		var p: Dictionary = g["players"][turn]
		# one noble per turn: the first whose bonuses are met
		for k in (g["nobles"] as Array).size():
			if not g["noble_free"][k]:
				continue
			var ok := true
			for c in g["nobles"][k]["reqs"]:
				if int(p["cards"][c]) < int(g["nobles"][k]["need"]):
					ok = false
			if ok:
				g["noble_free"][k] = false
				p["prestige"] += 3
				break
		if int(p["prestige"]) >= win:
			final_round = true
		turn = (turn + 1) % n
		if final_round and turn == 0:
			break
	var best := []
	var players: Array = g["players"]
	for k in n:
		if best.is_empty():
			best = [k]
			continue
		var b: Dictionary = players[best[0]]
		var q: Dictionary = players[k]
		var cmp := _better(q, b)
		if cmp > 0:
			best = [k]
		elif cmp == 0:
			best.append(k)
	return {"winners": best, "rounds": rounds}


## 1 when a beats b (more prestige, then fewer cards), 0 on a tie, -1 otherwise.
func _better(a: Dictionary, b: Dictionary) -> int:
	if int(a["prestige"]) != int(b["prestige"]):
		return 1 if int(a["prestige"]) > int(b["prestige"]) else -1
	var ca := _cards(a)
	var cb := _cards(b)
	if ca != cb:
		return 1 if ca < cb else -1
	return 0


func _cards(p: Dictionary) -> int:
	var n := 0
	for c in Gems.COLORS:
		n += int(p["cards"][c])
	return n


func _total(p: Dictionary) -> int:
	var n := 0
	for c in Gems.ALL:
		n += int(p["coins"][c])
	return n


func _afford(p: Dictionary, d: Dictionary) -> bool:
	var g := 0
	for cost in d["costs"]:
		var c: String = cost[0]
		g += maxi(maxi(int(cost[1]) - int(p["cards"][c]), 0) - int(p["coins"][c]), 0)
	return g <= int(p["coins"]["gold"])


func _pay(g: Dictionary, p: Dictionary, d: Dictionary) -> void:
	for cost in d["costs"]:
		var c: String = cost[0]
		var need := maxi(int(cost[1]) - int(p["cards"][c]), 0)
		var pay := mini(need, int(p["coins"][c]))
		p["coins"][c] -= pay
		g["bank"][c] += pay
		p["coins"]["gold"] -= need - pay
		g["bank"]["gold"] += need - pay
	p["cards"][d["element"]] += 1
	p["prestige"] += int(d["points"])


func _refill(g: Dictionary, idx: int) -> void:
	var deck: Array = g["decks"][TIER_OF_ROW[idx / 4]]
	g["board"][idx] = {} if deck.is_empty() else deck.pop_back()


func _gold(g: Dictionary, p: Dictionary) -> void:
	if int(g["bank"]["gold"]) > 0 and _total(p) < MAX_COINS:
		g["bank"]["gold"] -= 1
		p["coins"]["gold"] += 1


## Check the move against the rules and play it; false when it is illegal.
func _do(g: Dictionary, seat: int, dec: Dictionary) -> bool:
	var p: Dictionary = g["players"][seat]
	var reserved: Array = p["reserved"]
	match String(dec["kind"]):
		"skip":
			return true
		"take":
			var cols: Array = dec["colors"]
			if cols.is_empty() or cols.size() > 3 or _total(p) + cols.size() > MAX_COINS:
				return false
			if cols.size() == 2 and cols[0] == cols[1]:
				if int(g["bank"][cols[0]]) < 4:
					return false
			else:
				for c in cols:
					if cols.count(c) > 1 or int(g["bank"][c]) <= 0 or c == "gold":
						return false
			for c in cols:
				g["bank"][c] -= 1
				p["coins"][c] += 1
			return true
		"buy":
			var idx := int(dec["index"])
			var d: Dictionary = g["board"][idx]
			if d.is_empty() or not _afford(p, d):
				return false
			_pay(g, p, d)
			_refill(g, idx)
			return true
		"buy_reserved":
			var k := int(dec["k"])
			if k < 0 or k >= reserved.size() or not _afford(p, reserved[k]):
				return false
			_pay(g, p, reserved[k])
			reserved.remove_at(k)
			return true
		"reserve":
			var idx := int(dec["index"])
			var d: Dictionary = g["board"][idx]
			if d.is_empty() or reserved.size() >= RESERVE_MAX:
				return false
			reserved.append(d)
			_refill(g, idx)
			_gold(g, p)
			return true
		"reserve_blind":
			var deck: Array = g["decks"][int(dec["tier"])]
			if deck.is_empty() or reserved.size() >= RESERVE_MAX:
				return false
			var d: Dictionary = deck.pop_back()
			d["_blind"] = true
			reserved.append(d)
			_gold(g, p)
			return true
	return false


# ------------------------------------------------------------------ tuning

## Score of level a against level b over `pairs` deals, each played twice
## with the seats swapped (the same cards both times).
func _duel(a: String, b: String, pairs: int, seed0: int) -> float:
	var score := 0.0
	for j in pairs:
		for sw in 2:
			seed(seed0 + j)
			var seats := [a, b] if sw == 0 else [b, a]
			var r := _play(seats)
			var winners: Array = r["winners"]
			for w in winners:
				if seats[w] == a:
					score += 1.0 / winners.size()
			if winners.is_empty():
				score += 0.5
	return score / (2.0 * pairs)


## Hill-climb the evaluation of level `base`: change a weight or two and keep
## the change when, on the same deals, it scores better than the current
## weights against the `pool` levels (each deal played from both seats).
func _tune(base: String, iters: int) -> void:
	var probe := AIBrain.new()
	probe._set_level(base)
	var cur := {"base": base}
	for k in AIBrain.PARAMS:
		cur[k] = probe.get(k)
	for k in AIBrain.overrides.get(base, {}):
		cur[k] = AIBrain.overrides[base][k]
	var pairs := maxi(games / 2, 10)
	var rnd := RandomNumberGenerator.new()
	rnd.randomize()
	print("tune ", base, " vs ", pool, " start ", cur)
	for it in iters:
		var cand := cur.duplicate()
		var changed := []
		for t in 1 + rnd.randi() % 2:
			var k: String = AIBrain.PARAMS[rnd.randi() % AIBrain.PARAMS.size()]
			if k == "w_point":
				continue
			var v := float(cand[k])
			if k in ["w_reserve", "w_res_far", "w_hoard"] or absf(v) < 0.05:
				v += rnd.randfn(0.0, 0.2)
			else:
				v *= exp(rnd.randfn(0.0, 0.3))
			if k in ["w_omax", "w_disc_curve", "w_lt_min", "w_turn"]:
				v = clampf(v, 0.0, 1.0)
			cand[k] = v
			changed.append("%s=%.3f" % [k, v])
		AIBrain.overrides["cand"] = cand
		AIBrain.overrides["inc"] = cur
		var seed0 := rnd.randi()
		var sc := 0.0
		var si := 0.0
		for opp in pool:
			sc += _duel("cand", opp, pairs, seed0)
			si += _duel("inc", opp, pairs, seed0)
		sc /= pool.size()
		si /= pool.size()
		var ok := sc > si + margin
		print("it %d  %s  -> %.3f vs %.3f %s" % [it, ", ".join(changed), sc, si, "ACCEPT" if ok else ""])
		if ok:
			cur = cand
	var line := []
	for k in AIBrain.PARAMS:
		line.append("%s=%.3f" % [k, float(cur[k])])
	print("tuned ", base, ": ", ",".join(line))
	AIBrain.overrides["tuned"] = cur
	AIBrain.overrides["orig"] = {"base": base}
	print("final tuned vs legacy %.3f, vs original %.3f" % [_duel("tuned", "legacy", 200, 99), _duel("tuned", "orig", 200, 7)])


## Rough cost of the brain's parts on a mid-game position (microseconds).
func _bench() -> void:
	var g := _new_game(2)
	g["players"][0]["coins"] = {"white": 2, "blue": 1, "green": 1, "red": 0, "black": 2, "gold": 1}
	g["players"][0]["cards"] = {"white": 2, "blue": 1, "green": 2, "red": 1, "black": 1}
	g["players"][1]["coins"] = {"white": 1, "blue": 2, "green": 0, "red": 2, "black": 1, "gold": 0}
	g["players"][1]["cards"] = {"white": 1, "blue": 2, "green": 1, "red": 2, "black": 0}
	var snap := {"bank": g["bank"], "board": g["board"], "decks": {1: 30, 2: 26, 3: 16}, "nobles": g["nobles"],
			"noble_free": g["noble_free"], "players": g["players"], "seat": 0, "first_seat": 0, "final_round": false,
			"win_points": 15, "difficulty": "very_hard"}
	var b := AIBrain.new()
	b.load_snapshot(snap)
	var st: AIBrain.S = b.root
	var n := 20000
	var t := Time.get_ticks_usec()
	for i in n:
		b._seat(st, 0)
	print("seat   %.2f us" % ((Time.get_ticks_usec() - t) / float(n)))
	t = Time.get_ticks_usec()
	for i in n:
		st.clone()
	print("clone  %.2f us" % ((Time.get_ticks_usec() - t) / float(n)))
	var moves := b._gen(st)
	t = Time.get_ticks_usec()
	for i in n:
		b._gen(st)
	print("gen    %.2f us (%d moves)" % [(Time.get_ticks_usec() - t) / float(n), moves.size()])
	t = Time.get_ticks_usec()
	for i in n:
		var s2 := st.clone()
		b._apply(s2, moves[i % moves.size()])
	print("clone+apply %.2f us" % ((Time.get_ticks_usec() - t) / float(n)))
	var base := b._scores(st)
	t = Time.get_ticks_usec()
	for i in n:
		var s2 := st.clone()
		b._apply(s2, moves[i % moves.size()])
		b._value(s2, 0, base, 0)
	print("child value %.2f us" % ((Time.get_ticks_usec() - t) / float(n)))
	t = Time.get_ticks_usec()
	for i in 200:
		b.decide()
	print("decide %.2f ms" % ((Time.get_ticks_usec() - t) / 200000.0))
