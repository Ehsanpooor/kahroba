class_name NetGame
extends Node
## An online (or friends) game on the board. The server owns the game: this
## turns its messages into the board's own animations and sends your moves.
##
## Every STATE_FULL is compared with the one before it to see what the
## player on turn did (took gems, bought, reserved, a noble came), and the
## board plays that move the way it plays a computer's move; then the board's
## model is set to the server's numbers, so it can never drift.
##
## Server seats are turned so that you are always seat 0 on the board.

signal state_arrived

var b: Node  ## the board
var state := {}  ## the latest STATE_FULL
var my_seat := 0
var n := 0
var started := false  ## the game is being played (after the intro)
var awaiting := false  ## your move was sent; waiting for the server
var room_code := ""
var search_started := 0.0  ## unix time the player started looking for a table (public)
var _queue: Array = []  ## [op, data] waiting to be played on the board
var _running := false
var _slots := {1: ["", "", "", ""], 2: ["", "", "", ""], 3: ["", "", "", ""]}  ## board ids per tier, as placed
var _lobby_open := false
var _ready_state := {}
var _game_started := {}
var _ended := false
var _resync := false  ## after a reconnect the next state replaces the table
## A move that got no answer (lost as the line dropped and came back): after a
## few seconds the whole table is asked for again and rebuilt from it.
const AWAIT_LIMIT := 8.0
var _awaiting_for := 0.0
var _sent_on_turn := 0  # the turn your move was sent on: a newer turn from the server answers it
## The table checks itself against the server (an online game must never sit
## on the wrong turn): the server always moves the turn on by its deadline,
## so a turn shown past that deadline, or a move whose animation never ends,
## means this table missed something; it is then loaded again from the server.
const PAST_DEADLINE := 5.0  # seconds a turn may be shown past its deadline
const STUCK_LIMIT := 15.0  # seconds one move's animation may take
var _drain_gen := 0  # a reload starts a new run of the queue; the old one stops
var _item_started := 0.0
var _turn_due := 0.0  # local seconds when the shown turn's deadline passes
var _checking := false  # a check asked for the table: compare, replace if it differs
var _shown_turn_no := 0
var ad_break := false  ## the server's ad break before the game: waiting for the others
var _ad_sent := false
var _latest_turn_no := 0  # the newest turn any message has told of (played or still queued)
## The table's flags (TABLE_STATUS, op 111): who is offline, who asked for the
## pause of a friends' game, and the pause itself. Seats are the server's.
var table := {}
var paused := false  ## a friends' game the players paused: the board is hidden
var _reconnect_tries := 0
var _my_take: Array = []  # the gems of your last take (an exchange may hand some back)


func attach(board: Node) -> void:
	b = board
	room_code = String(Prefs.game.get("code", ""))
	search_started = float(Prefs.game.get("search_started", 0))
	Api.match_message.connect(_on_message)
	Api.socket_closed.connect(_on_socket_closed)


## Ask for the table and wait for it (false after 10 s of silence).
func first_state() -> bool:
	Api.send_op(Api.OP_SYNC)
	var t := 0.0
	while state.is_empty() and t < 10.0:
		await get_tree().process_frame
		t += get_process_delta_time()
	return not state.is_empty()


func _on_message(op: int, data: Dictionary) -> void:
	if OS.get_cmdline_user_args().has("--netdebug"):
		print("NET op=%d phase=%s started=%s" % [op, String(data.get("phase", "")), started])
	match op:
		Api.OP_STATE:
			var tno := int(data.get("turnNumber", 0))
			if data.has("table"):
				_table_status(data["table"])
			if _checking and started and not _resync:
				_checking = false
				# right when it is the turn shown, or the one the queue is about to show
				if tno == _shown_turn_no and _queue.is_empty() and not _running \
						or tno <= _latest_turn_no and (not _queue.is_empty() or _running):
					return
				print("NETLOG turn check: server turn %d, shown %d, latest %d" % [tno, _shown_turn_no, _latest_turn_no])
				push_warning("turn check: the table differs from the server; loading it again")
				_resync = true
			if _resync and started:
				_resync = false
				_restart_queue()
				resync(data)
				_start_turn_from(data.get("currentTurn", 0), int(data.get("turnDeadlineMs", 0)), int(data.get("serverNowMs", 0)),
						int(data.get("turnNumber", 1)))
				return
			_latest_turn_no = maxi(_latest_turn_no, tno)
			if state.is_empty() or not started:
				_set_state(data)
				if started:
					return
				state_arrived.emit()
				return
			_queue.append([op, data])
		Api.OP_TABLE_STATUS:
			_table_status(data)
			return
		Api.OP_TURN_SKIPPED:
			var ks := local(int(data.get("playerIndex", 0)))
			if started and ks != 0:
				b.hud.toast(L.t("opp_skips", String(_seat_dict(ks)["name"])))
			return
		Api.OP_READY_STATE:
			_ready_state = data
			state_arrived.emit()
		Api.OP_STARTED:
			_game_started = data
			state_arrived.emit()
		Api.OP_REMOVED:
			_removed(data)
		Api.OP_REJECTED:
			_rejected(data)
		Api.OP_AD_BREAK:
			_ad_break()
		_:
			if op == Api.OP_TURN:
				_latest_turn_no = maxi(_latest_turn_no, int(data.get("turnNumber", 0)))
			if started:
				_queue.append([op, data])
			elif op == Api.OP_ENDED:
				_queue.append([op, data])
	if started and not _running:
		_drain()


# ------------------------------------------------------------------ the table from a state

func _set_state(s: Dictionary) -> void:
	state = s
	n = (s.get("players", []) as Array).size()
	my_seat = maxi(int(s.get("yourSeat", 0)), 0)


func local(seat: int) -> int:
	return posmod(seat - my_seat, maxi(n, 1))


func server_seat(local_i: int) -> int:
	return posmod(local_i + my_seat, maxi(n, 1))


## The board takes the whole table from the state (before it is built).
func apply_full() -> void:
	var s := state
	var players: Array = s.get("players", [])
	b.opps = []
	for k in n:
		var pv: Dictionary = players[server_seat(k)]
		var d := _player(pv, k == 0)
		if k == 0:
			b.me = d
		else:
			b.opps.append(d)
	for t in [1, 2, 3]:
		var ids: Array = s.get("tier%dVisible" % t, [])
		_slots[t] = ["", "", "", ""]
		for i in mini(ids.size(), 4):
			_slots[t][i] = String(ids[i])
	b.board_cards = []
	b.board_cards.resize(12)
	for r in 3:
		var t: int = b.TIER_OF_ROW[r]
		for c in 4:
			var id: String = _slots[t][c]
			b.board_cards[r * 4 + c] = Api.card({"id": id}) if id != "" else {}
	for t in [1, 2, 3]:
		var deck := []
		deck.resize(int(s.get("tier%dCount" % t, 0)))
		deck.fill({})
		b.decks[t] = deck
	b.bank_counts = _bank(s)
	# the nobles still waiting, and the ones already visiting someone
	b.noble_data = []
	b.noble_owner = []
	for a in s.get("artifacts", []):
		b.noble_data.append(_noble(a))
		b.noble_owner.append("")
	for k in n:
		var pv: Dictionary = players[server_seat(k)]
		for aid in pv.get("artifacts", []):
			var nd := _noble_by_id(String(aid))
			b.noble_data.append(nd)
			b.noble_owner.append(String(_seat_dict(k)["name"]))
	b.win_points = int(s.get("winThreshold", 15))
	b.first_seat = local(int(s.get("firstSeat", 0))) if int(s.get("firstSeat", -1)) >= 0 else 0
	b.turn = local(int(s.get("currentTurn", 0)))
	b.round_no = maxi((int(s.get("turnNumber", 1)) - 1) / maxi(n, 1) + 1, 1)
	b.final_round = String(s.get("phase", "")) == "finalRound"


func _seat_dict(k: int) -> Dictionary:
	return b.me if k == 0 else b.opps[k - 1]


func _player(pv: Dictionary, mine: bool) -> Dictionary:
	var name := String(pv.get("displayName", ""))
	var portrait := String(pv.get("avatarId", ""))
	var bot := ""
	if pv.get("isAI", false):
		bot = Portraits.BOTS[absi(String(pv.get("userId", "")).hash()) % Portraits.BOTS.size()]
		name = L.t("bot_" + bot)
		portrait = bot
	if mine:
		name = Prefs.display_name()
		portrait = String(Prefs.get_v("portrait"))
	elif not portrait.begins_with("A-"):
		portrait = "A-01"
	var rating := int(pv.get("rating", 0))
	if rating <= 0:
		rating = int(Prefs.get_v("rating")) if mine else 1000
	var d: Dictionary = b._new_player(name, portrait, rating)
	if bot != "":
		d["bot"] = bot
	d["user_id"] = String(pv.get("userId", ""))
	_fill_player(d, pv, mine)
	return d


## The numbers of a player from the server.
func _fill_player(d: Dictionary, pv: Dictionary, mine: bool) -> void:
	var coins := Api.gems(pv.get("coins", {}))
	for c in Gems.ALL:
		d["coins"][c] = int(coins.get(c, 0))
	for c in Gems.COLORS:
		d["cards"][c] = 0
	for hc in pv.get("hiredCards", []):
		var col: String = Api.TO_GEM.get(String(hc.get("affinity", "")), "white")
		d["cards"][col] += 1
	d["prestige"] = int(pv.get("power", 0))
	d["nobles"] = (pv.get("artifacts", []) as Array).size()
	var res := []
	for slot in pv.get("reserve", []):
		if mine and String(slot.get("cardId", "")) != "":
			res.append(Api.card({"id": String(slot["cardId"])}))
		else:
			res.append({"id": "", "tier": int(slot.get("tier", 1)), "element": "white", "hidden": true, "points": 0, "costs": []})
	d["reserved"] = res
	d["away"] = pv.get("disconnected", false)
	d["missed"] = int(pv.get("missedTurns", 0))


func _bank(s: Dictionary) -> Dictionary:
	var sup := Api.gems(s.get("supply", {}))
	var out := {}
	for c in Gems.COLORS:
		out[c] = int(sup.get(c, 0))
	out["gold"] = int(s.get("aetherSupply", 0))
	return out


func _noble(a: Dictionary) -> Dictionary:
	var req := Api.gems(a.get("requirement", {}))
	var reqs := []
	var need := 0
	for c in Gems.COLORS:
		if int(req.get(c, 0)) > 0:
			reqs.append(c)
			need = int(req[c])
	return {"id": "N-" + String(a.get("id", "A-01")).substr(2), "reqs": reqs, "need": need}


func _noble_by_id(aid: String) -> Dictionary:
	for a in GameData.ARTIFACTS:
		if String(a["id"]) == aid:
			var nd: Dictionary = (a as Dictionary).duplicate(true)
			nd["id"] = "N-" + aid.substr(2)
			return nd
	return {"id": "N-" + aid.substr(2), "reqs": [], "need": 0}


# ------------------------------------------------------------------ before the game: room, ready check, who starts

## The waiting room (friends), the ready check and who starts, as the server
## runs them. Returns when the game is on.
func run_intro() -> void:
	var phase := String(state.get("phase", "playing"))
	if OS.get_cmdline_user_args().has("--netdebug"):
		print("NET intro phase=", phase)
	if phase in ["waiting", "readyCheck"]:
		var lobby: Lobby = b._lobby()
		await lobby.show_net(self)
		if _ended:
			return
		# the full table follows GAME_STARTED: wait for it, then show who starts
		var t := 0.0
		while String(state.get("phase", "")) not in ["playing", "finalRound"] and t < 4.0:
			await get_tree().process_frame
			t += get_process_delta_time()
		apply_full()
		b._build()
		b.first_seat = local(int(_game_started.get("firstSeat", state.get("firstSeat", 0))))
		await lobby.choose_starter([b.me] + b.opps, b.first_seat)


## Every seat as the lobby draws them: [{name, portrait, ready, open, bot}].
func lobby_seats() -> Array:
	var out := []
	var rs_seats: Array = _ready_state.get("seats", [])
	if not rs_seats.is_empty():  # the ready check lists every seat
		var count := rs_seats.size()
		for k in count:
			var seat := posmod(k + my_seat, count)
			for r in rs_seats:
				if int(r.get("seat", -1)) != seat:
					continue
				var me_ := String(r.get("userId", "")) == Api.user_id
				var name := String(r.get("displayName", ""))
				var portrait := String(r.get("avatarId", ""))
				if r.get("isAI", false):
					var bot: String = Portraits.BOTS[absi(String(r.get("userId", "")).hash()) % Portraits.BOTS.size()]
					name = L.t("bot_" + bot)
					portrait = bot
				if me_:
					name = Prefs.display_name()
					portrait = String(Prefs.get_v("portrait"))
				elif not portrait.begins_with("A-"):
					portrait = "A-01"
				out.append({"name": name, "portrait": portrait, "rating": int(r.get("rating", 1000)), "ready": r.get("ready", false),
						"open": r.get("open", false), "me": me_})
		return out
	var players: Array = state.get("players", [])
	var rs: Array = _ready_state.get("seats", [])
	for k in maxi(int(state.get("expectedPlayerCount", n)), n):
		var seat := server_seat(k) if k < n else k
		if seat < players.size():
			var pv: Dictionary = players[seat]
			var d := _player(pv, seat == my_seat)
			var ready: bool = pv.get("ready", false)
			for r in rs:
				if int(r.get("seat", -1)) == seat:
					ready = r.get("ready", false)
			out.append({"name": d["name"], "portrait": d["portrait"], "rating": int(d.get("rating", 1000)), "ready": ready,
					"open": pv.get("seatOpen", false), "me": seat == my_seat})
		else:
			out.append({"name": "", "portrait": "", "open": true, "ready": false, "me": false})
	return out


func phase() -> String:
	if not _game_started.is_empty():
		return "playing"
	var ph := String(state.get("phase", ""))
	if ph == "waiting" and not _ready_state.is_empty():
		return "readyCheck"  # the server announces the check before it sends a new state
	return ph


## The countdown of the ready check, in seconds.
func ready_left() -> float:
	var src := _ready_state if not _ready_state.is_empty() else state
	var dl := int(src.get("deadlineMs", src.get("readyDeadlineMs", 0)))
	var now := int(src.get("serverNowMs", 0))
	return maxf((dl - now) / 1000.0, 0.0) if dl > 0 else 0.0


## The ready countdown's full length, as the server set it.
func ready_total() -> float:
	return float(_ready_state.get("readySeconds", 45))


func send_ready() -> void:
	Api.send_op(Api.OP_READY)


## Everyone is ready and the server holds a short ad break: show this
## device's ad (if any), then tell the server it is done. The game starts when
## every player has, or at the server's deadline.
func _ad_break() -> void:
	if _ad_sent or _ended:
		return
	_ad_sent = true
	ad_break = true
	state_arrived.emit()  # the waiting room says so
	await Ads.show("pregame_online")
	Api.send_op(Api.OP_AD_DONE, {})


func is_ended() -> bool:
	return _ended


## Leave before the game starts: the server frees the seat (no rating).
func leave_lobby() -> void:
	_ended = true
	Api.send_op(Api.OP_CONCEDE)
	Api.leave_match()
	SavedGame.clear()
	state_arrived.emit()
	b._to_menu()


# ------------------------------------------------------------------ the game

## The game is on: take the turn from the state and play what comes.
func start() -> void:
	started = true
	_start_turn_from(state.get("currentTurn", 0), int(state.get("turnDeadlineMs", 0)), int(state.get("serverNowMs", 0)),
			int(state.get("turnNumber", 1)))
	_drain()


func _drain() -> void:
	if _running:
		return
	_running = true
	var g := _drain_gen
	while not _queue.is_empty():
		var it: Array = _queue.pop_front()
		var op: int = it[0]
		var data: Dictionary = it[1]
		_item_started = _now()
		match op:
			Api.OP_STATE:
				await _play_state(data)
				if g != _drain_gen:
					return  # the table was loaded again meanwhile: a new run took over
			Api.OP_TURN:
				_start_turn_from(data.get("playerIndex", 0), int(data.get("deadlineMs", 0)), int(data.get("serverNowMs", 0)),
						int(data.get("turnNumber", 1)))
			Api.OP_ABANDONED:
				var k := local(int(data.get("playerIndex", 0)))
				if k != 0:
					b.hud.toast(L.t("missed_turn", String(_seat_dict(k)["name"]), int(data.get("missedCount", 1))))
			Api.OP_ENDED:
				await _game_ended(data)
				if g != _drain_gen:
					return
	_running = false


func _start_turn_from(seat_v: Variant, deadline_ms: int, now_ms: int, turn_number: int) -> void:
	var t := local(int(seat_v))
	b.round_no = maxi((turn_number - 1) / maxi(n, 1) + 1, 1)
	b.start_turn(t, true)
	var left: float = b.hud.TURN_SECONDS
	if deadline_ms > 0 and now_ms > 0:
		left = (deadline_ms - now_ms) / 1000.0
		b.hud.turn_started = Time.get_ticks_msec() / 1000.0 - (b.hud.TURN_SECONDS - left)
	_turn_due = _now() + maxf(left, 0.0) if not paused else 0.0
	if paused:  # (a turn that began just before the pause) its clock waits too
		b.hud.freeze_clock(float(table.get("turnLeftMs", 0)) / 1000.0)
	_shown_turn_no = turn_number
	_latest_turn_no = maxi(_latest_turn_no, turn_number)
	awaiting = false
	if turn_number == 3 and OS.get_cmdline_user_args().has("--pausetest") and not _pt_asked:
		_pt_asked = true  # test: everyone asks for the pause, one after another
		get_tree().create_timer(1.0 + my_seat * 2.0).timeout.connect(func(): send_pause(true))


## One state after a move: play the move, then take the server's numbers.
func _play_state(s: Dictionary) -> void:
	var prev := state
	_set_state(s)
	var actor := local(int(prev.get("currentTurn", 0)))
	var pp: Dictionary = (prev.get("players", []) as Array)[server_seat(actor)]
	var np: Dictionary = (s.get("players", []) as Array)[server_seat(actor)]
	var hired_before := (pp.get("hiredCards", []) as Array).size()
	var hired_after := (np.get("hiredCards", []) as Array).size()
	var res_before := int(pp.get("reserveCount", (pp.get("reserve", []) as Array).size()))
	var res_after := int(np.get("reserveCount", (np.get("reserve", []) as Array).size()))
	var gone := _board_gone(prev, s)  # ids that left the board: [id, ...]
	var animated_slot := {}
	if hired_after > hired_before:
		var newest: Dictionary = (np["hiredCards"] as Array).back()
		var id := String(newest.get("id", ""))
		await _anim_buy(actor, id, gone.has(id), pp, np)
		animated_slot[id] = true
	elif res_after > res_before:
		var from_board := ""
		for id in gone:
			from_board = id
		var slot: Dictionary = (np.get("reserve", []) as Array).back()
		await _anim_reserve(actor, from_board, int(slot.get("tier", 1)), String(slot.get("cardId", "")), pp, np)
		if from_board != "":
			animated_slot[from_board] = true
	else:
		var gained := []
		var pc := Api.gems(pp.get("coins", {}))
		var nc := Api.gems(np.get("coins", {}))
		for c in Gems.COLORS:
			for k in maxi(int(nc.get(c, 0)) - int(pc.get(c, 0)), 0):
				gained.append(c)
		# an exchange: gems went back too (yours, counted from the take you sent)
		var took: Array = _my_take if actor == 0 and not b.staged.is_empty() else gained
		var back := []
		for c in Gems.ALL:
			for k in maxi(int(pc.get(c, 0)) + took.count(c) - int(nc.get(c, 0)), 0):
				back.append(c)
		if not gained.is_empty():
			await _anim_take(actor, gained)
		elif actor == 0 and not b.staged.is_empty():
			await _undo_staged()
		if not back.is_empty() and not gained.is_empty():
			if actor != 0:
				b.hud.toast(L.t("opp_exchanged", String(_seat_dict(actor)["name"])))
			_pay_flights(actor, back)
			await b._wait(0.5)
	# a noble came
	var na := (np.get("artifacts", []) as Array).size()
	if na > (pp.get("artifacts", []) as Array).size():
		var aid := String((np["artifacts"] as Array).back())
		await _anim_noble(actor, aid)
	await _refill_board(s)
	_sync()


## Ids on the board before that are not there now.
func _board_gone(prev: Dictionary, s: Dictionary) -> Array:
	var out := []
	for t in [1, 2, 3]:
		var now_ids: Array = s.get("tier%dVisible" % t, [])
		for id in prev.get("tier%dVisible" % t, []):
			if not now_ids.has(id):
				out.append(String(id))
	return out


func _card_node(id: String) -> SCard:
	for c in b.cards:
		if c.visible and not c.data.is_empty() and String(c.data.get("id", "")) == id:
			return c
	return null


## Coins that went back to the bank from a seat, as [colour, ...].
func _paid(pp: Dictionary, np: Dictionary) -> Array:
	var out := []
	var pc := Api.gems(pp.get("coins", {}))
	var nc := Api.gems(np.get("coins", {}))
	for c in Gems.ALL:
		for k in maxi(int(pc.get(c, 0)) - int(nc.get(c, 0)), 0):
			out.append(c)
	return out


func _anim_take(actor: int, gained: Array) -> void:
	if actor == 0:
		if b.staged.is_empty():  # taken by the clock or on another device: show them
			for c in gained:
				b._stage_add(c)
				await b._wait(0.3)
		await b._stage_commit(-1)
		b.picks.clear()
		b.hud.set_stage("", false)
		return
	var o: Dictionary = b.opps[actor - 1]
	b.hud.set_stage(L.t("opp_taking", String(o["name"])), false)
	for c in gained:
		b._stage_add(c)
		await b._wait(0.42)
	await b._wait(0.7)
	b.hud.set_stage("", false)
	await b._stage_commit(actor - 1)


func _undo_staged() -> void:
	while not b.staged.is_empty():
		await b._stage_undo()
	b.picks.clear()
	b._update_bar()


func _pay_flights(actor: int, paid: Array) -> void:
	var delay := 0.2
	for c in paid:
		var from: Vector3 = b._hud_point(b.hud.me_token_anchor(c) if actor == 0 else b.hud.seat_token_anchor(actor - 1, c), 40.0)
		b._fly_chip_from_point(c, from, b.bank[c], delay)
		delay += 0.08


func _anim_buy(actor: int, id: String, from_board: bool, pp: Dictionary, np: Dictionary) -> void:
	var d := Api.card({"id": id})
	var col: String = d["element"]
	var p: Dictionary = _seat_dict(actor)
	_fill_coins_only(p, np)  # the tokens leave the tray as they fly
	_pay_flights(actor, _paid(pp, np))
	var dest: Vector3 = b._hud_point(b.hud.me_card_anchor(col) if actor == 0 else b.hud.seat_card_anchor(actor - 1, col), 60.0)
	var line1 := L.t("you_bought") if actor == 0 else L.t("opp_bought", String(p["name"]))
	var card := _card_node(id) if from_board else null
	var loose := card == null
	if loose:
		var at: Vector3 = b._hud_point(b.hud.me_reserve_anchor() if actor == 0 else b.hud.seat_reserve_anchor(actor - 1), 60.0)
		card = b._loose_card(d, at)
		card.pivot.scale = Vector3.ONE * 0.2
		line1 += "  (%s)" % L.t("from_reserve")
		if actor == 0 and not b.fan.is_empty():
			b.close_fan()
	card.set_backlight(false)
	await b._reveal(card, line1, L.t("card_of", L.gem(col), d["tier"]), actor == 0, dest, 0.36 if actor == 0 else 0.2)
	card.visible = false
	if loose:
		card.queue_free()
	else:
		card.reset_pose()
		card.set_backlight(true)
		card.data = {}
	p["cards"][col] += 1
	if actor == 0:
		b.hud.update_me()
		b.hud.me_view.pop_card(col)
		var pts := int(d["points"])
		if pts > 0:
			p["prestige"] = int(np.get("power", 0)) - pts - 3 * ((np.get("artifacts", []) as Array).size() - (pp.get("artifacts", []) as Array).size())
			await b._score_orb(dest, pts)
	else:
		b.hud.update_opponent(actor - 1)
		b.hud.seats[actor - 1].pop_card(col)
	FX.burst(b.world_root, dest, Gems.GLOW[col], b.U, 44, 340.0)


func _anim_reserve(actor: int, board_id: String, tier: int, my_id: String, pp: Dictionary, np: Dictionary) -> void:
	var p: Dictionary = _seat_dict(actor)
	var dest: Vector3 = b._hud_point(b.hud.me_reserve_anchor() if actor == 0 else b.hud.seat_reserve_anchor(actor - 1), 60.0)
	var line1 := L.t("you_reserved") if actor == 0 else L.t("opp_reserved", String(p["name"]))
	var got_gold := int(Api.gems(np.get("coins", {})).get("gold", 0)) > int(Api.gems(pp.get("coins", {})).get("gold", 0))
	if got_gold:
		if actor == 0:
			b._fly_to_me(b.bank["gold"], 0.2)
		else:
			b._fly_chip_to_point(b.bank["gold"], b._hud_point(b.hud.seat_token_anchor(actor - 1, "gold"), 40.0), 1.4)
	var card := _card_node(board_id) if board_id != "" else null
	if card:
		var d: Dictionary = card.data
		card.set_backlight(false)
		await b._reveal(card, line1, L.t("card_of", L.gem(d["element"]), d["tier"]), actor == 0, dest, 0.3 if actor == 0 else 0.15)
		card.visible = false
		card.reset_pose()
		card.set_backlight(true)
		card.data = {}
	else:
		var shown: Dictionary = Api.card({"id": my_id}) if my_id != "" else {"id": "", "tier": tier, "element": "white", "points": 0, "costs": []}
		var c: SCard = b._loose_card(shown, (b.deck_nodes[tier] as DeckStack).top_world(), false)
		c.set_backlight(false)
		await b._reveal(c, line1, L.t("hidden_card", Gems.ROMAN[tier]), actor == 0, dest, 0.3 if actor == 0 else 0.15)
		c.queue_free()
		if actor == 0 and my_id != "":
			b.hud.announce(L.t("you_drew"), L.t("card_of", L.gem(shown["element"]), shown["tier"]), true, 1.6)


func _anim_noble(actor: int, aid: String) -> void:
	var nid := "N-" + aid.substr(2)
	for i in b.noble_data.size():
		if String(b.noble_data[i]["id"]) == nid and b.noble_owner[i] == "":
			b.noble_owner[i] = String(_seat_dict(actor)["name"])
			if actor == 0:
				b.me["prestige"] = int(b.me["prestige"])  # the orb adds the 3
			await b._noble_claim(i, actor - 1)
			return


## Places whose card changed are dealt again from their deck.
func _refill_board(s: Dictionary) -> void:
	for t in [1, 2, 3]:
		var now_ids: Array = s.get("tier%dVisible" % t, [])
		var old: Array = _slots[t]
		var fresh := now_ids.filter(func(id): return not old.has(id))
		var slots := ["", "", "", ""]
		for i in 4:
			if old[i] != "" and now_ids.has(old[i]):
				slots[i] = old[i]
		for i in 4:
			if slots[i] == "" and not fresh.is_empty():
				slots[i] = String(fresh.pop_front())
		_slots[t] = slots
		var deck := []
		deck.resize(int(s.get("tier%dCount" % t, 0)))
		deck.fill({})
		b.decks[t] = deck
		var r: int = b.TIER_OF_ROW.find(t)
		for i in 4:
			var idx := r * 4 + i
			var card: SCard = b.cards[idx]
			var want: String = slots[i]
			var have := String(card.data.get("id", "")) if card.visible else ""
			if want == have:
				continue
			if want == "":
				b.board_cards[idx] = {}
				card.visible = false
				card.data = {}
				continue
			var nd := Api.card({"id": want})
			b.board_cards[idx] = nd
			(b.deck_nodes[t] as DeckStack).set_count(deck.size())
			card.reset_pose()
			card.set_data(nd)
			card.visible = true
			await b._deal(card, t, 0.75)
		(b.deck_nodes[t] as DeckStack).set_count(deck.size())


func _fill_coins_only(p: Dictionary, np: Dictionary) -> void:
	var coins := Api.gems(np.get("coins", {}))
	for c in Gems.ALL:
		p["coins"][c] = int(coins.get(c, 0))


## The board's model becomes the server's numbers.
func _sync() -> void:
	var players: Array = state.get("players", [])
	for k in n:
		_fill_player(_seat_dict(k), players[server_seat(k)], k == 0)
	b.bank_counts = _bank(state)
	for col in b.bank:
		(b.bank[col] as ChipStack).set_count(int(b.bank_counts[col]))
	b.final_round = String(state.get("phase", "")) == "finalRound"
	b.hud.update_me()
	for i in b.opps.size():
		b.hud.update_opponent(i)
	b._refresh_glows()
	b._update_bar()


# ------------------------------------------------------------------ your moves

## Every move may carry `noble`: the noble chosen when the move leaves you
## qualifying for more than one ("" = none to choose).
func send_take(picks: Array, noble := "", ret := {}) -> void:
	_sent()
	_my_take = picks.duplicate()
	var msg := {"artifactId": noble}
	if not ret.is_empty():  # the exchange: the gems handed back past 10
		var r := {}
		for c in ret:
			r[Api.TO_ELEMENT[c]] = int(ret[c])
		msg["return"] = r
	if picks.size() == 2 and picks[0] == picks[1]:
		msg["element"] = Api.TO_ELEMENT[picks[0]]
		Api.send_op(Api.OP_CHANNEL, msg)
	else:
		msg["elements"] = picks.map(func(c): return Api.TO_ELEMENT[c])
		Api.send_op(Api.OP_HARVEST, msg)


func send_buy(id: String, from_reserve: bool, noble := "") -> void:
	_sent()
	Api.send_op(Api.OP_HIRE, {"characterId": id, "fromReserve": from_reserve, "aetherUse": 0, "artifactId": noble})


func send_reserve(id: String, noble := "") -> void:
	_sent()
	Api.send_op(Api.OP_JAIL, {"characterId": id, "artifactId": noble})


func send_reserve_blind(tier: int, noble := "") -> void:
	_sent()
	Api.send_op(Api.OP_JAIL, {"characterId": "", "tier": tier, "artifactId": noble})


func send_skip() -> void:
	_sent()
	Api.send_op(Api.OP_SKIP)


## A move went to the server: no other move until it is answered.
func _sent() -> void:
	awaiting = true
	_awaiting_for = 0.0
	_sent_on_turn = _shown_turn_no


## Ask for the pause of a friends' game, or take the request back.
func send_pause(on: bool) -> void:
	Api.send_op(Api.OP_PAUSE, {"on": on})


## While paused: ready to go on, or not.
func send_resume(on: bool) -> void:
	Api.send_op(Api.OP_RESUME, {"on": on})


func concede() -> void:
	Api.send_op(Api.OP_CONCEDE)


# ------------------------------------------------------------------ the table's flags and the pause

## TABLE_STATUS: every seat's flags; the pause starts or ends.
func _table_status(st: Dictionary) -> void:
	table = st
	var was := paused
	paused = bool(st.get("paused", false))
	if not started or b.hud == null:
		return
	b.apply_table_status()
	_pause_test(was)
	if paused and not was:
		_turn_due = 0.0  # the clock stands still: no deadline to check against
		b.hud.freeze_clock(float(st.get("turnLeftMs", 0)) / 1000.0)
	elif was and not paused:
		var left := float(st.get("turnLeftMs", 0)) / 1000.0
		_turn_due = _now() + left
		b.hud.turn_started = Time.get_ticks_msec() / 1000.0 - (b.hud.TURN_SECONDS - left)
		b.hud.resume_timer()


## Test (--pausetest): resume 8 s into the pause; --pauseshot=<file> saves
## the table when the first player asked (<file>_asked.png) and paused
## (<file>_paused.png).
var _pt_asked := false
var _pt_shots := {}


func _pause_test(was: bool) -> void:
	var args := OS.get_cmdline_user_args()
	if not args.has("--pausetest"):
		return
	if paused and not was:
		print("PAUSETEST paused")
		get_tree().create_timer(8.0 + my_seat * 1.0).timeout.connect(func(): send_resume(true))
		_pause_shot("paused", 2.5)
	elif was and not paused:
		print("PAUSETEST resumed")
		_pause_shot("resumed", 1.2)
	elif not paused and int(table.get("pauseVotes", 0)) > 0:
		_pause_shot("asked", 1.6)


func _pause_shot(tag: String, after: float) -> void:
	var path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pauseshot="):
			path = a.get_slice("=", 1)
	if path == "" or _pt_shots.has(tag):
		return
	_pt_shots[tag] = true
	await get_tree().create_timer(after).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path.get_basename() + "_" + tag + ".png")


## Seat flags by local seat (you are seat 0): [{offline, pause, resume}].
func seat_flags() -> Array:
	var out := []
	var seats: Array = table.get("seats", [])
	for k in n:
		var ss := server_seat(k)
		var f: Dictionary = seats[ss] if ss < seats.size() else {}
		out.append({"offline": bool(f.get("disconnected", false)), "pause": bool(f.get("pauseVote", false)),
				"resume": bool(f.get("resumeVote", false))})
	return out


func can_pause() -> bool:
	return bool(table.get("canPause", false)) and not _ended


func _rejected(data: Dictionary) -> void:
	awaiting = false
	var code := String(data.get("code", ""))
	print("NETLOG rejected %s: %s" % [code, String(data.get("reason", ""))])
	var key: String = {"not_your_turn": "wait_turn", "coin_limit": "max_tokens", "cannot_afford": "not_enough",
			"reserve_full": "reserve_full", "deck_empty": "deck_empty", "supply_empty": "none_left",
			"channel_supply_low": "two_needs_four", "game_paused": "game_is_paused"}.get(code, "move_refused")
	b.hud.toast(L.t(key, 10))
	if not b.staged.is_empty():
		_undo_staged()


# ------------------------------------------------------------------ the end, and trouble

func _game_ended(data: Dictionary) -> void:
	_ended = true
	b.game_over = true
	b.hud.stop_timer()
	SavedGame.clear()
	var reason := String(data.get("reason", ""))
	if reason == "lobbyTimeout" or reason == "pauseTimeout":
		b.hud.toast(L.t("room_closed_pause" if reason == "pauseTimeout" else "room_closed"))
		await b._wait(1.6)
		b._to_menu()
		return
	var rows := []
	var won := false
	var place := 0
	var deltas: Dictionary = data.get("ratingDeltas", {})
	for st in data.get("standings", []):
		var k := local(int(st.get("index", 0)))
		var q := _seat_dict(k)
		rows.append({"name": q["name"], "portrait": q["portrait"], "power": int(st.get("power", 0)),
				"cards": int(st.get("hiredCount", 0)), "me": k == 0})
		if k == 0:
			place = int(st.get("rank", 0))
			won = place == 1
	var my_delta := int(deltas.get(Api.user_id, 0))
	if my_delta != 0:
		Prefs.set_v("rating", int(Prefs.get_v("rating")) + my_delta)
	b._record_game(won, my_delta, false, place)
	var title := L.t("victory") if won else L.t("wins", String(rows[0]["name"]) if not rows.is_empty() else "")
	b.hud.banner(L.t("you_win") if won else title, won)
	await b._wait(1.8)
	b.hud.show_results(rows, title, won, b.after_results(b._to_play), b.after_results(b._to_menu))
	Api.leave_match()


func _removed(data: Dictionary) -> void:
	_ended = true
	SavedGame.clear()
	b.hud.toast(L.t("removed_ready") if String(data.get("reason", "")) == "ready_timeout" else L.t("room_closed"))
	get_tree().create_timer(1.6).timeout.connect(b._to_menu)


## The socket dropped: the board shows "reconnecting" while this tries again.
func _on_socket_closed() -> void:
	if _ended:
		return
	b._on_net_changed(false)
	_reconnect_tries = 0
	while not _ended and is_inside_tree():
		# the socket itself is the test of the line: try it (more slowly as it fails)
		await get_tree().create_timer(2.0 if _reconnect_tries < 5 else 4.0).timeout
		_reconnect_tries += 1
		if not await Api.connect_socket():
			print("NETLOG reconnect %d: no socket" % _reconnect_tries)
			continue
		var why := await Api.join_match(String(Prefs.game.get("match_id", "")))
		print("NETLOG reconnect %d: join %s" % [_reconnect_tries, why if why != "" else "ok"])
		if why == "":
			_resync = true
			Api.send_op(Api.OP_SYNC)
			b._on_net_changed(true)
			return
		if why.to_lower().contains("not found"):
			# the game ended while we were away: nothing to go back to
			SavedGame.clear()
			b.hud.close_modal()
			get_tree().paused = false
			b.hud.toast(L.t("game_gone"))
			get_tree().create_timer(1.6).timeout.connect(b._to_menu)
			return


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## Drop whatever the queue was playing: a reload replaces the table.
func _restart_queue() -> void:
	_drain_gen += 1
	_running = false
	_queue.clear()


## Load the whole table from the server again.
func reload(why: String) -> void:
	if _ended or not started or _resync or not Api.socket_ready():
		return
	push_warning("turn check: %s; loading the table again" % why)
	_restart_queue()
	_resync = true
	_turn_due = _now() + 20.0  # (no second reload while this one is on its way)
	Api.send_op(Api.OP_SYNC)


## Back in the app: ask the server which turn it is, and compare.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED or what == NOTIFICATION_APPLICATION_FOCUS_IN:
		check_turn()


## Ask the server for the table and compare its turn with the one shown.
func check_turn() -> void:
	if started and not _ended and not _resync and Api.socket_ready():
		_checking = true
		Api.send_op(Api.OP_SYNC)


func _process(delta: float) -> void:
	if started and not _ended and not get_tree().paused and not paused:
		var now := _now()
		if _running and now - _item_started > STUCK_LIMIT:
			reload("a move took over %d s to show" % int(STUCK_LIMIT))
		elif not _running and _turn_due > 0.0 and now > _turn_due + PAST_DEADLINE:
			reload("the turn is past its deadline")
	if not awaiting or _ended or paused:
		return
	if _latest_turn_no > _sent_on_turn:
		return  # answered: the move waits in the queue behind the moves before it
	_awaiting_for += delta
	if _awaiting_for > AWAIT_LIMIT and Api.socket_ready():
		_awaiting_for = 0.0
		push_warning("move unanswered for %.0f s: asking for the table again" % AWAIT_LIMIT)
		_resync = true
		Api.send_op(Api.OP_SYNC)


## A fresh state after a reconnect replaces everything.
func resync(s: Dictionary) -> void:
	awaiting = false  # a move sent as the line died got no answer: the state says what happened
	_set_state(s)
	apply_full()
	b._build()
