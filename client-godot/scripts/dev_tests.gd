extends Node
## Developer checks run from the command line (`-- --apitest`): talks to the
## server and prints what came back, then quits.


func _ready() -> void:
	await get_tree().process_frame
	print("server: ", Net.server())
	print("session: ", await Api.ensure_session(), " user ", Api.user_id)
	var p := await Api.sync_profile()
	print("profile: ", p["ok"], " ", p["message"])
	var cat := await Api.rpc_call("get_catalog", {})
	print("catalog: ", cat["ok"], " cards ", (cat["data"].get("cards", []) as Array).size(), " win ", cat["data"].get("config", {}).get("winThresholdOptions"))
	var act := await Api.rpc_call("get_active_game", {})
	print("active: ", act["data"])
	print("socket: ", await Api.connect_socket())
	var room := await Api.rpc_call("create_private_match", {"playerCount": 2, "winThreshold": 15})
	print("room: ", room)
	if room["ok"]:
		var code := String(room["data"].get("code", ""))
		var j := await Api.rpc_call("join_by_code", {"code": code})
		print("by code: ", j)
		print("join: '", await Api.join_match(String(room["data"]["matchId"])), "'")
		await get_tree().create_timer(1.0).timeout
		Api.send_op(Api.OP_CONCEDE)
		await get_tree().create_timer(1.0).timeout
	print("rating: ", await Api.my_rating())
	print("board: ", await Api.leaderboard(5))
	get_tree().quit()
