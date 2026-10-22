class_name AIBrain
extends RefCounted
## The computer opponents' thinking: pure logic, no nodes, so it can run on a
## worker thread and in the headless arena (scripts/dev_ai_arena.gd).
##
##   var b := AIBrain.new()
##   b.load_snapshot(snap)   # plain data, read once (main thread)
##   var d := b.decide()     # {"kind": "buy"|"buy_reserved"|"reserve"|"reserve_blind"|"take"|"skip", ...}
##
## The snapshot: {bank {colour: n incl gold}, board [12 card dicts, {} = none],
## decks {1: n, 2: n, 3: n}, nobles [{reqs, need}], noble_free [bool],
## players [{coins, cards, prestige, reserved [card dicts; {"hidden": true}
## for another player's blind reserve]}] by seat, seat (who moves),
## first_seat, final_round, win_points, difficulty}.
##
## Levels (strength measured with the arena, see dev_ai_arena.gd):
##   easy       the old computer, careless: sometimes ignores a card it could buy
##   legacy     the old computer exactly (arena reference only)
##   normal     every legal move looked at one move ahead, judged by its own
##              position only (nobles half seen), with a little randomness
##   hard       every legal move one move ahead with the full evaluation:
##              prestige, the engine (discounts), nobles, the cards within
##              reach and how many turns they are away, tokens that serve
##              them, and the same for every other player (so taking or
##              reserving a card someone else needs counts)
##   very_hard  hard's evaluation, then its best 10 moves are played out:
##              every other player answers with its own best move, then its own
##              best next move (in a duel the other answers once more); the
##              last round is counted exactly (who can still score what)
##
## Reserving is only considered when the card can be bought soon or another
## player could buy it now and it would help them a lot (or the hand is full).
## The evaluation is in "points": a term worth 1.0 is worth about one prestige;
## its weights were tuned by self-play in the arena (--tune).
## It sees what a player in its seat sees; a card dealt into an emptied place
## is unknown, so the look-ahead leaves the place empty.

const MAX_COINS := 10
const RESERVE_MAX := 3
const COLORS := ["white", "blue", "green", "red", "black"]

const MK_TAKE := 0
const MK_BUY := 1
const MK_BUYRES := 2
const MK_RES := 3
const MK_BLIND := 4
const MK_SKIP := 5
const UNKNOWN := -2  # a card reserved blind in the look-ahead

# every card once, by a small index
static var c_id: Array = []
static var c_index := {}
static var c_tier := PackedInt32Array()
static var c_pts := PackedInt32Array()
static var c_el := PackedInt32Array()
static var c_cost := PackedInt32Array()  # 5 per card
static var c_total := PackedInt32Array()

## Tables built once (call on the main thread before any worker uses them).
static func prepare() -> void:
	if not c_id.is_empty():
		return
	var ids: Array = GameData.CARDS.keys()
	ids.sort()
	for id in ids:
		var d: Dictionary = GameData.CARDS[id]
		c_index[id] = c_id.size()
		c_id.append(id)
		c_tier.append(int(d["tier"]))
		c_pts.append(int(d["points"]))
		c_el.append(COLORS.find(String(d["element"])))
		var cost := [0, 0, 0, 0, 0]
		var tot := 0
		for pair in d["costs"]:
			var k := COLORS.find(String(pair[0]))
			cost[k] = int(pair[1])
			tot += int(pair[1])
		for k in 5:
			c_cost.append(cost[k])
		c_total.append(tot)


## The game as the brain sees it: everything in flat int arrays.
class S:
	var n := 2
	var bank := PackedInt32Array()  # 6 (gold last)
	var board := PackedInt32Array()  # 12 card indices, -1 = empty
	var deck := PackedInt32Array()  # [0, I, II, III]
	var nreq := PackedInt32Array()  # 5 per noble
	var nfree := PackedInt32Array()  # 1 = still free
	var coins := PackedInt32Array()  # 6 per seat
	var bon := PackedInt32Array()  # 5 per seat
	var pts := PackedInt32Array()
	var ncards := PackedInt32Array()
	var res := PackedInt32Array()  # 3 per seat, -1 = empty, UNKNOWN = blind (look-ahead)
	var cur := 0
	var first := 0
	var win := 15
	var final_round := false
	var ended := false
	var touched := false  # the last move changed the board or the nobles

	func clone() -> S:
		var o := S.new()
		o.n = n
		o.bank = bank.duplicate()
		o.board = board.duplicate()
		o.deck = deck.duplicate()
		o.nreq = nreq
		o.nfree = nfree.duplicate()
		o.coins = coins.duplicate()
		o.bon = bon.duplicate()
		o.pts = pts.duplicate()
		o.ncards = ncards.duplicate()
		o.res = res.duplicate()
		o.cur = cur
		o.first = first
		o.win = win
		o.final_round = final_round
		o.ended = ended
		return o


var level := "normal"
var root: S
var me := 0
var snap: Dictionary = {}
var rng := RandomNumberGenerator.new()
var result: Dictionary = {}  # the last decide()'s move (read it after a worker thread ran decide)
var evals := 0  # seat evaluations made by the last decide()
var last_us := 0  # how long the last decide() took

# --- the evaluation's weights (set per level in _set_level) ---
## Tunable by name (the arena's --tune changes them through `overrides`).
const PARAMS := ["w_point", "w_disc1", "w_disc_curve", "w_noble", "w_noble_decay", "w_noble2", "w_target",
		"w_target2", "w_target3", "w_tpt", "w_res_far", "w_turn", "w_coin", "w_surplus", "w_gold", "w_hoard", "w_reserve", "w_lt_min", "w_omax", "w_opp"]
var w_point := 1.0
var w_disc1 := 0.621  # the first card of a colour, in points
var w_disc_curve := 0.758  # each further card of a colour is worth this much of the one before
var w_noble := 5.681
var w_noble_decay := 0.432
var w_noble2 := 0.174
var w_target := 0.704
var w_target2 := 0.476
var w_target3 := 0.095
var w_tpt := 0.370  # collecting turns per missing token
var w_res_far := -0.150  # a reserved card, per turn it is still away
var w_turn := 0.545  # a card one more turn away is worth this much of itself
var w_coin := 0.172
var w_surplus := 0.248  # a token no near card wants, against a wanted one
var w_gold := 0.198
var w_hoard := 0.300
var w_reserve := -0.300
var w_lt_min := 0.350  # how much the engine is still worth on the doorstep of the target
var w_omax := 0.700  # opponents: weight of the best one against their average
var w_opp := 1.120  # opponents against ourselves
var see_nobles := true
var see_opps := true
var noise := 0.0  # random spread added to every move's value
var reply_k := 10  # very_hard: own candidate moves played out further (two players)
var reply_k_multi := 10  # the same with three or four players
var line_duel := 0  # plies played out in a duel (0 = the other, us, the other again)
var line_multi := 0  # plies played out with 3-4 players (0 = every other player, then us)
var budget_us := 80000  # very_hard: look at no more candidates after this long (slow phones)
var w_disc := PackedFloat32Array()  # value of holding n cards of a colour (built from w_disc1 / w_disc_curve)

## Test levels: name -> {"base": level, param: value, ...} (the arena).
static var overrides := {}

var debug := false
var prune := true  # leave out reserves that serve no purpose
var res_close := 1.0  # reserve a card we can buy within this many turns
var res_deny := 3  # or one another player can buy now that is worth this much to them

var _ng := PackedFloat32Array([0, 0, 0, 0, 0])  # scratch: noble gain by colour


func _init() -> void:
	prepare()
	rng.randomize()


func load_snapshot(s: Dictionary) -> void:
	snap = s
	_set_level(String(s.get("difficulty", "normal")))
	var st := S.new()
	var players: Array = s["players"]
	st.n = players.size()
	st.bank.resize(6)
	for c in 5:
		st.bank[c] = int(s["bank"].get(COLORS[c], 0))
	st.bank[5] = int(s["bank"].get("gold", 0))
	st.board.resize(12)
	st.board.fill(-1)
	var board: Array = s["board"]
	for k in mini(board.size(), 12):
		var d: Dictionary = board[k]
		if not d.is_empty() and c_index.has(d.get("id", "")):
			st.board[k] = c_index[d["id"]]
	st.deck = PackedInt32Array([0, int(s["decks"].get(1, 0)), int(s["decks"].get(2, 0)), int(s["decks"].get(3, 0))])
	var nobles: Array = s["nobles"]
	var free: Array = s["noble_free"]
	for k in nobles.size():
		var req := [0, 0, 0, 0, 0]
		for col in nobles[k]["reqs"]:
			req[COLORS.find(String(col))] = int(nobles[k]["need"])
		for c in 5:
			st.nreq.append(req[c])
		st.nfree.append(1 if bool(free[k]) else 0)
	for p in players:
		for c in 5:
			st.coins.append(int(p["coins"].get(COLORS[c], 0)))
		st.coins.append(int(p["coins"].get("gold", 0)))
		var nc := 0
		for c in 5:
			var b := int(p["cards"].get(COLORS[c], 0))
			st.bon.append(b)
			nc += b
		st.ncards.append(nc)
		st.pts.append(int(p["prestige"]))
		var r: Array = p["reserved"]
		for k in RESERVE_MAX:
			if k < r.size() and c_index.has(r[k].get("id", "")):
				st.res.append(c_index[r[k]["id"]])
			elif k < r.size():
				st.res.append(UNKNOWN)
			else:
				st.res.append(-1)
	st.cur = int(s["seat"])
	st.first = int(s.get("first_seat", 0))
	st.win = int(s.get("win_points", 15))
	st.final_round = bool(s.get("final_round", false))
	root = st
	me = st.cur


func _set_level(lv: String) -> void:
	var extra: Dictionary = overrides.get(lv, {})
	level = String(extra.get("base", lv))
	match level:
		"normal":  # its own position only, nobles half seen, a little careless
			see_opps = false
			w_noble = 2.5
			w_target2 = 0.2
			noise = 0.55
		"hard":
			pass
		"very_hard":
			pass
	for k in extra:
		if k != "base":
			set(k, extra[k])
	w_disc = PackedFloat32Array()
	var v := 0.0
	var step := w_disc1
	for k in 9:
		w_disc.append(v)
		v += step
		step *= w_disc_curve


## The move to make, as a plain dictionary.
func decide() -> Dictionary:
	var t0 := Time.get_ticks_usec()
	evals = 0
	var out: Dictionary
	if level == "easy" or level == "legacy":
		out = _legacy(level == "easy")
	else:
		var m := _choose()
		out = _to_dict(m)
	last_us = Time.get_ticks_usec() - t0
	result = out
	return out


# ------------------------------------------------------------------ moves

## Every legal move of the seat on turn (a few pointless smaller takes left out).
func _gen(st: S) -> PackedInt32Array:
	var out := PackedInt32Array()
	var s := st.cur
	var cb := s * 6
	var total := 0
	for c in 6:
		total += st.coins[cb + c]
	var room := MAX_COINS - total
	var avail: Array = []
	for c in 5:
		if st.bank[c] > 0:
			avail.append(c)
	var na := avail.size()
	if room >= 3 and na >= 3:
		for a in na:
			for b in range(a + 1, na):
				for d in range(b + 1, na):
					out.append(MK_TAKE | (((1 << (2 * avail[a])) + (1 << (2 * avail[b])) + (1 << (2 * avail[d]))) << 3))
	if na < 3 or room < 3:
		if room >= 2:
			for a in na:
				for b in range(a + 1, na):
					out.append(MK_TAKE | (((1 << (2 * avail[a])) + (1 << (2 * avail[b]))) << 3))
		if room >= 1:
			for a in na:
				out.append(MK_TAKE | ((1 << (2 * avail[a])) << 3))
	if room >= 2:
		for c in 5:
			if st.bank[c] >= 4:
				out.append(MK_TAKE | ((2 << (2 * c)) << 3))
	for k in 12:
		var ci := st.board[k]
		if ci >= 0 and _affordable(st, s, ci):
			out.append(MK_BUY | (k << 3))
	var nres := 0
	for k in RESERVE_MAX:
		var ci := st.res[s * 3 + k]
		if ci == -1:
			continue
		nres += 1
		if ci >= 0 and _affordable(st, s, ci):
			out.append(MK_BUYRES | (k << 3))
	if nres < RESERVE_MAX:
		var gold_in := 1 if st.bank[5] > 0 and room > 0 else 0
		for k in 12:
			var ci := st.board[k]
			if ci >= 0 and (not prune or room <= 1 or _reserve_ok(st, s, ci, gold_in)):
				out.append(MK_RES | (k << 3))
		if not prune or room <= 1:
			for t in [1, 2, 3]:
				if st.deck[t] > 0:
					out.append(MK_BLIND | (t << 3))
	if out.is_empty() and prune:
		prune = false
		out = _gen(st)
		prune = true
	return out


## Worth reserving: we can buy it soon (with the gold it brings), or another
## player can buy it now and it would help them a lot.
func _reserve_ok(st: S, s: int, ci: int, gold_in: int) -> bool:
	if _turns(st, s, ci, gold_in) <= res_close:
		return true
	for k in st.n:
		if k == s or not _affordable(st, k, ci):
			continue
		var g := c_pts[ci]
		if st.pts[k] + g + 3 >= st.win:
			return true
		var el := c_el[ci]
		for q in st.nfree.size():
			if st.nfree[q] == 0 or st.nreq[q * 5 + el] <= st.bon[k * 5 + el]:
				continue
			var ok := true
			for c in 5:
				if st.bon[k * 5 + c] + (1 if c == el else 0) < st.nreq[q * 5 + c]:
					ok = false
					break
			if ok:
				g += 3
				break
		if g >= res_deny:
			return true
	return false


## Collecting turns seat `s` still needs before it can buy card `ci`.
func _turns(st: S, s: int, ci: int, extra_gold := 0) -> float:
	var cb := s * 6
	var bb := s * 5
	var cc := ci * 5
	var net_total := 0
	var short := 0
	var maxd := 0
	for c in 5:
		var net := c_cost[cc + c] - st.bon[bb + c]
		if net > 0:
			net_total += net
			var d := net - st.coins[cb + c]
			if d > 0:
				short += d
				if d > maxd:
					maxd = d
	var gold := st.coins[cb + 5] + extra_gold
	var turns := 0.0
	short -= gold
	if short > 0:
		turns = maxf(float(short) * w_tpt, float(maxi(maxd - gold, 0)) * 0.5)
	if net_total > MAX_COINS:
		turns += float(net_total - MAX_COINS) * 0.5
	return turns


func _affordable(st: S, s: int, ci: int) -> bool:
	var cb := s * 6
	var bb := s * 5
	var cc := ci * 5
	var short := 0
	for c in 5:
		var d := c_cost[cc + c] - st.bon[bb + c] - st.coins[cb + c]
		if d > 0:
			short += d
	return short <= st.coins[cb + 5]


## Play move `m` for the seat on turn and pass the turn (as board.gd does:
## pay colour first, gold for the rest; one noble per turn; final round).
func _apply(st: S, m: int) -> void:
	var s := st.cur
	var cb := s * 6
	var bb := s * 5
	var kind := m & 7
	var arg := m >> 3
	st.touched = false
	if kind == MK_TAKE:
		var a := arg
		for c in 5:
			var k := a & 3
			a = a >> 2
			if k > 0:
				st.coins[cb + c] += k
				st.bank[c] -= k
	elif kind == MK_BUY or kind == MK_BUYRES:
		var ci := -1
		if kind == MK_BUY:
			ci = st.board[arg]
			st.board[arg] = -1
			st.touched = true
		else:
			ci = st.res[s * 3 + arg]
			for k in range(arg, RESERVE_MAX - 1):
				st.res[s * 3 + k] = st.res[s * 3 + k + 1]
			st.res[s * 3 + RESERVE_MAX - 1] = -1
		var cc := ci * 5
		var gold := 0
		for c in 5:
			var net := c_cost[cc + c] - st.bon[bb + c]
			if net > 0:
				var pay := mini(net, st.coins[cb + c])
				st.coins[cb + c] -= pay
				st.bank[c] += pay
				gold += net - pay
		st.coins[cb + 5] -= gold
		st.bank[5] += gold
		st.bon[bb + c_el[ci]] += 1
		st.pts[s] += c_pts[ci]
		st.ncards[s] += 1
	elif kind == MK_RES or kind == MK_BLIND:
		var ci := UNKNOWN
		if kind == MK_RES:
			ci = st.board[arg]
			st.board[arg] = -1
			st.touched = true
		else:
			st.deck[arg] -= 1
		for k in RESERVE_MAX:
			if st.res[s * 3 + k] == -1:
				st.res[s * 3 + k] = ci
				break
		var total := 0
		for c in 6:
			total += st.coins[cb + c]
		if st.bank[5] > 0 and total < MAX_COINS:
			st.bank[5] -= 1
			st.coins[cb + 5] += 1
	var nn := st.nfree.size()
	for k in nn:
		if st.nfree[k] == 0:
			continue
		var ok := true
		for c in 5:
			if st.bon[bb + c] < st.nreq[k * 5 + c]:
				ok = false
				break
		if ok:
			st.nfree[k] = 0
			st.pts[s] += 3
			st.touched = true
			break
	if st.pts[s] >= st.win:
		st.final_round = true
	var nx := (s + 1) % st.n
	if st.final_round and nx == st.first:
		st.ended = true
	st.cur = nx


func _to_dict(m: int) -> Dictionary:
	if m < 0:
		return {"kind": "skip"}
	var kind := m & 7
	var arg := m >> 3
	match kind:
		MK_TAKE:
			var cols := []
			var a := arg
			for c in 5:
				for k in a & 3:
					cols.append(COLORS[c])
				a = a >> 2
			return {"kind": "take", "colors": cols}
		MK_BUY:
			return {"kind": "buy", "index": arg}
		MK_BUYRES:
			return {"kind": "buy_reserved", "k": arg}
		MK_RES:
			return {"kind": "reserve", "index": arg}
		MK_BLIND:
			return {"kind": "reserve_blind", "tier": arg}
	return {"kind": "skip"}


# ------------------------------------------------------------------ evaluation

## How good seat `s`'s position is on its own, in points. (The inner loop of
## every look-ahead: written out by colour, with local copies, for speed.)
func _seat(st: S, s: int) -> float:
	evals += 1
	var bon := st.bon
	var coins := st.coins
	var cost := c_cost
	var wd := w_disc
	var cb := s * 6
	var bb := s * 5
	var b0 := bon[bb]
	var b1 := bon[bb + 1]
	var b2 := bon[bb + 2]
	var b3 := bon[bb + 3]
	var b4 := bon[bb + 4]
	var k0 := coins[cb]
	var k1 := coins[cb + 1]
	var k2 := coins[cb + 2]
	var k3 := coins[cb + 3]
	var k4 := coins[cb + 4]
	var gold := coins[cb + 5]
	var pts := st.pts[s]
	var score := float(pts) * w_point
	var lt := clampf(float(st.win - pts) / (float(st.win) * 0.6), w_lt_min, 1.0)
	# the engine: permanent discounts, worth less as the game nears its end
	score += (wd[mini(b0, 8)] + wd[mini(b1, 8)] + wd[mini(b2, 8)] + wd[mini(b3, 8)] + wd[mini(b4, 8)]) * lt
	# nobles, by how close they are; g0..g4: what one more card of a colour brings
	var g0 := 0.0
	var g1 := 0.0
	var g2 := 0.0
	var g3 := 0.0
	var g4 := 0.0
	if see_nobles:
		var nreq := st.nreq
		var nfree := st.nfree
		var best := 0.0
		var second := 0.0
		for k in nfree.size():
			if nfree[k] == 0:
				continue
			var q := k * 5
			var r0 := nreq[q] - b0
			var r1 := nreq[q + 1] - b1
			var r2 := nreq[q + 2] - b2
			var r3 := nreq[q + 3] - b3
			var r4 := nreq[q + 4] - b4
			var def := maxi(r0, 0) + maxi(r1, 0) + maxi(r2, 0) + maxi(r3, 0) + maxi(r4, 0)
			var v := w_noble / (1.0 + w_noble_decay * def)
			if v > best:
				second = best
				best = v
			elif v > second:
				second = v
			if def > 0:
				var g := w_noble / (1.0 + w_noble_decay * (def - 1)) - v
				if r0 > 0 and g > g0:
					g0 = g
				if r1 > 0 and g > g1:
					g1 = g
				if r2 > 0 and g > g2:
					g2 = g
				if r3 > 0 and g > g3:
					g3 = g
				if r4 > 0 and g > g4:
					g4 = g
		score += best + w_noble2 * second
	# what one more card of each colour brings: its discount and noble progress
	var mg := _ng
	mg[0] = (wd[mini(b0 + 1, 8)] - wd[mini(b0, 8)]) * lt + g0
	mg[1] = (wd[mini(b1 + 1, 8)] - wd[mini(b1, 8)]) * lt + g1
	mg[2] = (wd[mini(b2 + 1, 8)] - wd[mini(b2, 8)]) * lt + g2
	mg[3] = (wd[mini(b3 + 1, 8)] - wd[mini(b3, 8)]) * lt + g3
	mg[4] = (wd[mini(b4 + 1, 8)] - wd[mini(b4, 8)]) * lt + g4
	# the cards in reach: what they bring, discounted by the turns to afford them
	var board := st.board
	var res := st.res
	var pts_c := c_pts
	var el_c := c_el
	var t1 := 0.0
	var t2 := 0.0
	var t3 := 0.0
	var i1 := -1
	var i2 := -1
	var i3 := -1
	var res_pen := 0.0
	for slot in 15:
		var ci := -1
		if slot < 12:
			ci = board[slot]
		else:
			ci = res[s * 3 + slot - 12]
			if ci == UNKNOWN:
				res_pen += w_reserve + w_res_far * 2.0
				continue
		if ci < 0:
			continue
		var cc := ci * 5
		var net_total := 0
		var short := 0
		var maxd := 0
		var n := cost[cc] - b0
		if n > 0:
			net_total += n
			n -= k0
			if n > 0:
				short += n
				maxd = n
		n = cost[cc + 1] - b1
		if n > 0:
			net_total += n
			n -= k1
			if n > 0:
				short += n
				if n > maxd:
					maxd = n
		n = cost[cc + 2] - b2
		if n > 0:
			net_total += n
			n -= k2
			if n > 0:
				short += n
				if n > maxd:
					maxd = n
		n = cost[cc + 3] - b3
		if n > 0:
			net_total += n
			n -= k3
			if n > 0:
				short += n
				if n > maxd:
					maxd = n
		n = cost[cc + 4] - b4
		if n > 0:
			net_total += n
			n -= k4
			if n > 0:
				short += n
				if n > maxd:
					maxd = n
		var turns := 0.0
		short -= gold
		if short > 0:
			turns = maxf(float(short) * w_tpt, float(maxi(maxd - gold, 0)) * 0.5)
		if net_total > MAX_COINS:  # needs more discounts first
			turns += float(net_total - MAX_COINS) * 0.5
		if slot >= 12:
			res_pen += w_reserve + w_res_far * minf(turns, 4.0)
		var v := (float(pts_c[ci]) * w_point + mg[el_c[ci]]) * pow(w_turn, turns + 1.0)
		if v > t1:
			t3 = t2
			i3 = i2
			t2 = t1
			i2 = i1
			t1 = v
			i1 = ci
		elif v > t2:
			t3 = t2
			i3 = i2
			t2 = v
			i2 = ci
		elif v > t3:
			t3 = v
			i3 = ci
	score += w_target * t1 + w_target2 * t2 + w_target3 * t3 + res_pen
	# tokens are worth what they buy: the ones the best cards still want
	# count fully, the rest a little; a full hand wastes turns
	var w0 := 0
	var w1 := 0
	var w2 := 0
	var w3 := 0
	var w4 := 0
	for ci in [i1, i2, i3]:
		if ci >= 0:
			var cc: int = ci * 5
			w0 = maxi(w0, cost[cc] - b0)
			w1 = maxi(w1, cost[cc + 1] - b1)
			w2 = maxi(w2, cost[cc + 2] - b2)
			w3 = maxi(w3, cost[cc + 3] - b3)
			w4 = maxi(w4, cost[cc + 4] - b4)
	var useful := mini(k0, w0) + mini(k1, w1) + mini(k2, w2) + mini(k3, w3) + mini(k4, w4)
	var tot := k0 + k1 + k2 + k3 + k4
	score += float(useful) * w_coin + float(tot - useful) * w_coin * w_surplus + float(gold) * w_gold
	tot += gold
	if tot > 8:
		score -= float(tot - 8) * w_hoard
	return score


## The game is over: who won (most prestige, then fewest cards).
func _terminal(st: S, s: int, est: PackedInt32Array, cards: PackedInt32Array, scale: float) -> float:
	var best := -1
	for k in st.n:
		if best < 0 or est[k] > est[best] or (est[k] == est[best] and cards[k] < cards[best]):
			best = k
	var mine := est[s]
	var top_other := -1
	for k in st.n:
		if k != s and (top_other < 0 or est[k] > top_other):
			top_other = est[k]
	if best == s or (est[best] == mine and cards[best] == cards[s]):
		return scale + float(mine - top_other)
	return -scale + float(mine - top_other)


## The best prestige seat `s` can add with one move now (a card and its noble).
func _best_immediate(st: S, s: int) -> int:
	var bb := s * 5
	var best := 0
	for slot in 15:
		var ci := -1
		if slot < 12:
			ci = st.board[slot]
		else:
			ci = st.res[s * 3 + slot - 12]
		if ci < 0 or not _affordable(st, s, ci):
			continue
		var g := c_pts[ci]
		var el := c_el[ci]
		for k in st.nfree.size():
			if st.nfree[k] == 0:
				continue
			var ok := true
			for c in 5:
				var have := st.bon[bb + c] + (1 if c == el else 0)
				if have < st.nreq[k * 5 + c]:
					ok = false
					break
			if ok:
				g += 3
				break
		if g > best:
			best = g
	return best


## The value of a position for seat `s`. `cache` holds seat scores of the
## position before the last move (or is empty): only the seat that moved is
## scored again unless that move touched the board or the nobles.
func _value(st: S, s: int, cache: PackedFloat32Array = PackedFloat32Array(), mover := -1) -> float:
	if st.ended or st.final_round:
		var est := st.pts.duplicate()
		var cards := st.ncards.duplicate()
		if not st.ended:  # the seats still to move this round get one more move
			var k := st.cur
			while k != st.first:
				var g := _best_immediate(st, k)
				est[k] += g
				if g > 0:
					cards[k] += 1
				k = (k + 1) % st.n
		return _terminal(st, s, est, cards, 60.0 if st.ended else 40.0) + 0.05 * _seat_or_cache(st, s, cache, mover)
	var my := _seat_or_cache(st, s, cache, mover)
	if not see_opps:
		return my
	var mx := -INF
	var sum := 0.0
	for k in st.n:
		if k == s:
			continue
		var v := _seat_or_cache(st, k, cache, mover)
		sum += v
		if v > mx:
			mx = v
	return my - w_opp * (w_omax * mx + (1.0 - w_omax) * sum / float(st.n - 1))


func _seat_or_cache(st: S, k: int, cache: PackedFloat32Array, mover: int) -> float:
	if cache.size() > k and k != mover and not st.touched:
		return cache[k]
	return _seat(st, k)


func _scores(st: S) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(st.n)
	for k in st.n:
		out[k] = _seat(st, k)
	return out


# ------------------------------------------------------------------ choosing

func _choose() -> int:
	var moves := _gen(root)
	if moves.is_empty():
		return -1
	var base := _scores(root)
	var vals := PackedFloat32Array()
	vals.resize(moves.size())
	for i in moves.size():
		var st := root.clone()
		_apply(st, moves[i])
		vals[i] = _value(st, me, base, me) + (rng.randf() * noise if noise > 0.0 else 0.0)
	if debug:
		var order := range(moves.size())
		order.sort_custom(func(a, b): return vals[a] > vals[b])
		var line := "  base me %.2f opp %.2f |" % [base[me], base[1 - me] if root.n == 2 else 0.0]
		for j in mini(6, order.size()):
			var st2 := root.clone()
			_apply(st2, moves[order[j]])
			line += " %s=%.2f(me %.2f opp %.2f)" % [_name(moves[order[j]]), vals[order[j]], _seat(st2, me), _seat(st2, (me + 1) % root.n)]
		print(line)
	if level != "very_hard":
		return moves[_argmax(vals)]
	return _deepen(moves, vals)


func _argmax(vals: PackedFloat32Array) -> int:
	var b := 0
	for i in vals.size():
		if vals[i] > vals[b] or (vals[i] == vals[b] and rng.randf() < 0.5):
			b = i
	return b


## very_hard: the best few moves are played out further: every other player
## answers with its own best move, then we make our best next move (and in a
## duel the opponent answers once more); the move whose line ends best wins.
func _deepen(moves: PackedInt32Array, vals: PackedFloat32Array) -> int:
	var order := range(moves.size())
	order.sort_custom(func(a, b): return vals[a] > vals[b])
	var t0 := Time.get_ticks_usec()
	var best_i: int = order[0]
	var best_v := -INF
	var k_max := mini(reply_k if root.n == 2 else reply_k_multi, order.size())
	var plies := root.n + (1 if root.n == 2 else 0)  # the others, ourselves, (the other again)
	if root.n > 2 and line_multi > 0:
		plies = line_multi
	elif root.n == 2 and line_duel > 0:
		plies = line_duel
	for j in k_max:
		if j >= 3 and Time.get_ticks_usec() - t0 > budget_us:
			break
		var i: int = order[j]
		var st := root.clone()
		_apply(st, moves[i])
		var v := _line(st, plies)
		if debug:
			print("    deep %s: 1-ply %.2f line %.2f" % [_name(moves[i]), vals[i], v])
		if v > best_v:
			best_v = v
			best_i = i
	return moves[best_i]


## Play `plies` more moves, each the mover's own best by one look ahead,
## and value the end for us.
func _line(st: S, plies: int) -> float:
	for p in plies:
		if st.ended:
			break
		var nx := _best_child(st)
		if nx == null:
			break
		st = nx
	return _value(st, me)


## The position after the best move of the seat on turn (its own view).
func _best_child(st: S) -> S:
	var who := st.cur
	var moves := _gen(st)
	if moves.is_empty():
		var sk := st.clone()
		_apply(sk, MK_SKIP)
		return sk
	var base := _scores(st)
	var best: S = null
	var best_v := -INF
	for m in moves:
		var s2 := st.clone()
		_apply(s2, m)
		var v := _value(s2, who, base, who)
		if v > best_v:
			best_v = v
			best = s2
	return best


# ------------------------------------------------------------------ the old computer

## The computer as it was: buy the highest-prestige card it can afford,
## sometimes reserve one at random, otherwise take gems toward one card.
func _legacy(easy: bool) -> Dictionary:
	var players: Array = snap["players"]
	var o: Dictionary = players[int(snap["seat"])]
	var board: Array = snap["board"]
	var bank: Dictionary = snap["bank"]
	var best := -1
	var best_pts := -1
	for k in board.size():
		var d: Dictionary = board[k]
		if not d.is_empty() and _can_afford_d(o, d):
			if int(d["points"]) > best_pts:
				best = k
				best_pts = int(d["points"])
	var res_best := -1
	var reserved: Array = o["reserved"]
	for k in reserved.size():
		if _can_afford_d(o, reserved[k]) and int(reserved[k]["points"]) > best_pts:
			res_best = k
			best_pts = int(reserved[k]["points"])
	var total := 0
	for c in o["coins"]:
		total += int(o["coins"][c])
	var room := MAX_COINS - total
	var can_res := reserved.size() < RESERVE_MAX
	if easy and (best >= 0 or res_best >= 0) and room >= 3 and rng.randf() < 0.4:
		best = -1
		res_best = -1
	var want: Array = _legacy_wants(o, board) if not easy else []
	if res_best >= 0:
		return {"kind": "buy_reserved", "k": res_best}
	if best >= 0:
		return {"kind": "buy", "index": best}
	if can_res and (room <= 0 or rng.randf() < 0.12):
		if rng.randf() < 0.35:
			var t: int = [1, 2, 3][rng.randi() % 3]
			if int(snap["decks"].get(t, 0)) > 0:
				return {"kind": "reserve_blind", "tier": t}
			return {"kind": "skip"}
		var choices := []
		for k in board.size():
			if not (board[k] as Dictionary).is_empty():
				choices.append(k)
		if not choices.is_empty():
			return {"kind": "reserve", "index": choices[rng.randi() % choices.size()]}
		return {"kind": "skip"}
	if room > 0:
		var avail: Array = COLORS.filter(func(c): return int(bank[c]) > 0)
		for k in range(avail.size() - 1, 0, -1):  # shuffle with our own generator (thread-safe)
			var j := rng.randi() % (k + 1)
			var tmp = avail[k]
			avail[k] = avail[j]
			avail[j] = tmp
		if not want.is_empty():
			avail.sort_custom(func(a, b): return want.has(a) and not want.has(b))
		var take: Array = avail.slice(0, mini(3, room))
		var deep: Array = COLORS.filter(func(c): return int(bank[c]) >= 4)
		if room >= 2 and not deep.is_empty() and (take.size() < 2 or rng.randf() < 0.2):
			take = [deep[0], deep[0]]
		if take.is_empty():
			return {"kind": "skip"}
		return {"kind": "take", "colors": take}
	return {"kind": "skip"}


func _can_afford_d(p: Dictionary, d: Dictionary) -> bool:
	var g := 0
	for cost in d["costs"]:
		var c: String = cost[0]
		var need := maxi(int(cost[1]) - int(p["cards"][c]), 0)
		g += maxi(need - int(p["coins"][c]), 0)
	return g <= int(p["coins"]["gold"])


func _legacy_wants(o: Dictionary, board: Array) -> Array:
	var best_score := -INF
	var best_need := {}
	for d in board:
		if (d as Dictionary).is_empty():
			continue
		var need := {}
		var missing := 0
		for cost in d["costs"]:
			var c: String = cost[0]
			need[c] = maxi(int(cost[1]) - int(o["cards"][c]), 0)
			missing += maxi(int(need[c]) - int(o["coins"][c]), 0)
		var sc := float(d["points"]) * 2.0 - float(missing)
		if sc > best_score:
			best_score = sc
			best_need = need
	var out := []
	for col in best_need:
		if int(best_need[col]) > int(o["coins"][col]):
			out.append(col)
	return out


func _name(m: int) -> String:
	var d := _to_dict(m)
	match String(d["kind"]):
		"take":
			return "take" + "".join((d["colors"] as Array).map(func(c): return String(c).substr(0, 2)))
		"buy", "reserve":
			return "%s:%s" % [d["kind"], c_id[root.board[int(d["index"])]]]
		"buy_reserved":
			return "buyres:%s" % c_id[root.res[me * 3 + int(d["k"])]]
		"reserve_blind":
			return "blind%d" % int(d["tier"])
	return "skip"
