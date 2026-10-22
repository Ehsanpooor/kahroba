extends Node
## Developer check for online play (`-- --nettest=host|guest --codefile=<path>`):
## the host opens a friends' room and writes its code to the file, the guest
## reads it and joins; both then go to the board, where `--autoplay` plays.


func _ready() -> void:
	var role := ""
	var codefile := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--nettest="):
			role = a.get_slice("=", 1)
		elif a.begins_with("--codefile="):
			codefile = a.get_slice("=", 1)
	await get_tree().process_frame
	await Api.sync_profile()
	var game := {}
	if role == "search":  # a public table
		var count := 4 if OS.get_cmdline_user_args().has("--four") else 2
		var r := await Api.rpc_call("start_public_search", {"playerCount": count})
		print("NETTEST table ", r["data"])
		print("NETTEST join ", await Api.join_match(String(r["data"].get("matchId", ""))))
		game = {"mode": "online", "players": count, "search_started": Time.get_unix_time_from_system()}
	elif role == "host":
		var count := 4 if OS.get_cmdline_user_args().has("--four") else 2
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--players="):  # a bigger friends' room (up to 6)
				count = int(a.get_slice("=", 1))
		var r := await Api.rpc_call("create_private_match", {"playerCount": count, "winThreshold": 15})
		print("NETTEST host room ", r["data"])
		var f := FileAccess.open(codefile, FileAccess.WRITE)
		f.store_string(String(r["data"].get("code", "")))
		f.close()
		print("NETTEST join ", await Api.join_match(String(r["data"]["matchId"])))
		game = {"mode": "friends", "players": 2, "code": String(r["data"].get("code", ""))}
	else:
		var code := ""
		while code == "":
			await get_tree().create_timer(0.5).timeout
			if FileAccess.file_exists(codefile):
				code = FileAccess.get_file_as_string(codefile).strip_edges()
		var j := await Api.rpc_call("join_by_code", {"code": code})
		print("NETTEST guest code ", code, " -> ", j["data"])
		print("NETTEST join ", await Api.join_match(String(j["data"].get("matchId", ""))))
		game = {"mode": "friends", "players": 0, "code": code}
	game["net"] = true
	game["match_id"] = Api.match_id
	Prefs.game = game
	get_tree().change_scene_to_file("res://scenes/board.tscn")
