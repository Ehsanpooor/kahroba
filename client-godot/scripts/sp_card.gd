class_name SCard
extends Node3D
## A development card in 3D: a thin rounded slab, landscape. The face shows
## the painting with the points top-left, the bonus gem top-right and the
## cost row along the bottom; the back is the level's leather. Cards lift and
## tilt toward the pointer, flip over, fly and land. Local units are design px
## (the board scales the node to world size).

signal arrived

const W := 280.0
const H := 280.0 * 60.0 / 82.0  # the host's card: 82 x 60
const THICK := 4.0
const RADIUS := 14.0
## The host's card design: white border, points top-left, a big gem
## top-right, the costs in a row along the bottom (fractions of the card).
const PIP_D := 0.3 * H
const PIP_STEP := 0.232 * W
const POINTS_AT := Vector2(0.135, 0.215)
const POINTS_PX := 0.34 * H
const GEM_AT := Vector2(0.855, 0.24)
const GEM_D := 0.54 * H
const COST_X0 := 0.16
const COST_Y := 0.815
const BORDER := 0.03 * W
const WINDOW := Vector4(0.075, 0.196, 0.851, 0.504)  # the frame's opening: x, y, w, h

static var _mesh: ArrayMesh
static var _rim_mat: StandardMaterial3D
static var _back_mats := {}

var data: Dictionary = {}
var pivot := Node3D.new()  # lift, tilt, scale (hover, inspect, flights)
var flipper := Node3D.new()  # turns the card over (rotation.z)
## The tilted camera sees the table shortened; a flat card is stretched along
## the table to look true. The stretch must follow the card's own tilt (none
## when it faces the camera), or it deforms the card as it lifts and flies.
var squash := Node3D.new()
var cam_tilt := 0.0  # the camera's tilt from straight down (radians); set by the board
var body := MeshInstance3D.new()
var overlay := Node3D.new()
var face_mat: ShaderMaterial
var backlight: MeshInstance3D
var hover := 0.0
var target_hover := 0.0
var tilt_target := Vector2.ZERO  # pointer position over the card, -1..1
var busy := false
var interactive := true
var face_up := true
var glow_target := 0.0
var _glow := 0.0
var _raised := false
var _overlay_items: Array = []  # [node, layer]


func _init() -> void:
	add_child(pivot)
	pivot.add_child(squash)
	squash.add_child(flipper)
	flipper.position.y = THICK * 0.5
	body.mesh = slab_mesh()
	body.position.y = -THICK * 0.5
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	flipper.add_child(body)
	overlay.position.y = THICK * 0.5 + 0.35
	flipper.add_child(overlay)
	# the level's light behind the card
	backlight = MeshInstance3D.new()
	backlight.mesh = Meshes.quad(W * 1.24, H * 1.3)
	var bm := ShaderMaterial.new()
	bm.shader = preload("res://shaders/backlight.gdshader")
	bm.set_shader_parameter("box", Vector2(1.0 / 1.24, 1.0 / 1.3))
	backlight.material_override = bm
	backlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	backlight.position.y = 0.15
	backlight.visible = false
	add_child(backlight)


## The card shape, shared by every card and deck.
static func slab_mesh() -> ArrayMesh:
	if _mesh == null:
		_mesh = Meshes.rounded_slab(W, H, RADIUS, THICK, 5)
		_rim_mat = StandardMaterial3D.new()
		_rim_mat.albedo_color = Color(0.93, 0.88, 0.76)
		_rim_mat.roughness = 0.6
	return _mesh


static func back_material(tier: int) -> ShaderMaterial:
	if _back_mats.has(tier):
		return _back_mats[tier]
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/card_back.gdshader")
	# the host's backs (the decks in the holes), else the older painted ones
	var hp := "res://assets/splendor/hud/back_%d.png" % tier
	var t: Texture2D = Tex.get_tex(hp) if ResourceLoader.exists(hp) else Gems.back_tex(tier)
	m.set_shader_parameter("has_tex", 1.0 if t else 0.0)
	if t:
		m.set_shader_parameter("tex", t)
	m.set_shader_parameter("tier_col", Gems.TIER[tier])
	m.set_shader_parameter("size_px", Vector2(W, H))
	_back_mats[tier] = m
	return m


static func rim_material() -> StandardMaterial3D:
	slab_mesh()
	return _rim_mat


func set_data(d: Dictionary) -> void:
	data = d
	for c in overlay.get_children():
		c.queue_free()
	_overlay_items.clear()
	var col: String = d["element"]
	var tier := int(d["tier"])
	face_mat = ShaderMaterial.new()
	face_mat.shader = preload("res://shaders/card_face.gdshader")
	# up to three paintings per colour and level, spread over the cards
	var art := Gems.card_art(col, tier, [0, 2, 3][int(String(d["id"]).substr(2)) % 3])
	face_mat.set_shader_parameter("has_art", 1.0 if art else 0.0)
	if art:
		face_mat.set_shader_parameter("art", art)
	face_mat.set_shader_parameter("gem_col", Gems.BASE[col])
	face_mat.set_shader_parameter("tier_col", Gems.TIER[tier])
	face_mat.set_shader_parameter("size_px", Vector2(W, H))
	face_mat.set_shader_parameter("border_px", BORDER)
	face_mat.set_shader_parameter("seed", float(String(d["id"]).hash() % 997) / 97.0)
	var frame: Texture2D = null  # the gem frames are retired (host's call); the board design comes later
	face_mat.set_shader_parameter("has_frame", 1.0 if frame else 0.0)
	if frame:
		face_mat.set_shader_parameter("frame", frame)
		face_mat.set_shader_parameter("win", WINDOW)
	var tc: Color = Gems.TIER[tier]
	(backlight.material_override as ShaderMaterial).set_shader_parameter("color", tc.lightened(0.25))
	body.set_surface_override_material(0, face_mat)
	body.set_surface_override_material(1, back_material(tier))
	body.set_surface_override_material(2, _rim_mat)

	# points in the frame's medallion, top-left
	var points := int(d["points"])
	if points > 0:
		var pl := Fonts.label3d(str(points), POINTS_PX, Color(1, 1, 1), "num", 4.0, Color(0.1, 0.05, 0.02, 0.6))
		pl.position = Vector3((POINTS_AT.x - 0.5) * W, 0, (POINTS_AT.y - 0.5) * H)
		_add_overlay(pl, 3)
	# the gem is part of the frame; drawn here only while the frame art is missing
	# the gem: the frame has its own, but a bigger painted gem over the socket reads on a phone
	var gem := Gems.icon(col, GEM_D, Vector2((GEM_AT.x - 0.5) * W, (GEM_AT.y - 0.5) * H))
	_add_overlay(gem, 1)
	# the costs, big, along the frame's bottom band
	var costs: Array = d["costs"]
	for i in costs.size():
		var cost: Array = costs[i]
		var pos := Vector2((COST_X0 - 0.5) * W + i * PIP_STEP, (COST_Y - 0.5) * H)
		var p := Gems.pip(cost[0], int(cost[1]), PIP_D, pos)
		_add_overlay(p, 2)
	_apply_layers()


func _add_overlay(n: Node3D, layer: int) -> void:
	overlay.add_child(n)
	_overlay_items.append([n, layer])


## Raised cards (lifted, flying) draw above the dimming veil.
func set_raised(r: bool) -> void:
	_raised = r
	_apply_layers()


func _apply_layers() -> void:
	var base := 20 if _raised else 0
	for e in _overlay_items:
		_set_priority(e[0], base + int(e[1]) * 2)


static func _set_priority(n: Node, p: int) -> void:
	if n is Label3D:
		(n as Label3D).render_priority = p + 1
		(n as Label3D).outline_render_priority = p
	elif n is MeshInstance3D and (n as MeshInstance3D).material_override:
		(n as MeshInstance3D).material_override.render_priority = p
	for c in n.get_children():
		_set_priority(c, p + 1)


func _process(delta: float) -> void:
	_update_squash()
	hover = lerpf(hover, target_hover, 1.0 - exp(-delta * 12.0))
	_glow = lerpf(_glow, glow_target, 1.0 - exp(-delta * 6.0))
	if face_mat:
		face_mat.set_shader_parameter("highlight", hover)
		var pulse := 0.65 + 0.35 * sin(Time.get_ticks_msec() * 0.004)
		face_mat.set_shader_parameter("glow", _glow * pulse)
	if not busy:
		pivot.position = Vector3(0, hover * 14.0, 0)
		pivot.rotation = Vector3(tilt_target.y * 0.12 * hover, 0, -tilt_target.x * 0.12 * hover)


func set_face_up(up: bool) -> void:
	face_up = up
	flipper.rotation.z = 0.0 if up else PI


func set_dim(v: float) -> void:
	if face_mat:
		face_mat.set_shader_parameter("dim", v)


## The level's light behind the card: not in the host's design, so always off.
func set_backlight(_on: bool) -> void:
	backlight.visible = false


## Seen by a camera tilted `cam_tilt`, a card tilted `rx` toward it shows
## its length shortened by cos(rx - cam_tilt): stretch it back by exactly that.
func _update_squash() -> void:
	if cam_tilt <= 0.0:
		return
	squash.scale.z = 1.0 / maxf(cos(pivot.rotation.x - cam_tilt), 0.35)


func contains_world(p: Vector3) -> bool:
	if not interactive or not visible:
		return false
	var l := to_local(p)
	return absf(l.x) <= W * 0.5 and absf(l.z) <= H * 0.5 * squash.scale.z


## Where the pointer is over the card, -1..1 on both axes (for the tilt).
func local_tilt(p: Vector3) -> Vector2:
	var l := to_local(p)
	return Vector2(clampf(l.x / (W * 0.5), -1, 1), clampf(l.z / (H * 0.5), -1, 1))


func reset_pose() -> void:
	busy = false
	hover = 0.0
	pivot.position = Vector3.ZERO
	pivot.rotation = Vector3.ZERO
	pivot.scale = Vector3.ONE
	set_face_up(true)
	set_raised(false)
	_set_flash(0.0)
	set_dissolve(0.0)


func _set_flash(v: float) -> void:
	if face_mat:
		face_mat.set_shader_parameter("flash", v)


func set_dissolve(v: float) -> void:
	if face_mat:
		face_mat.set_shader_parameter("dissolve", v)
	overlay.visible = v < 0.5


## Short squash on touch.
func press() -> void:
	var tw := create_tween()
	tw.tween_property(pivot, "scale", Vector3.ONE * 0.95, 0.06)
	tw.tween_property(pivot, "scale", Vector3.ONE, 0.14).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Dealt from `from_world` (the top of a deck), face down: it first rises
## straight up out of the hole (`rise`, local units) still shaped like the
## deck (`start_scale`, turned `start_yaw`), then arcs onto this card's place,
## turning over and straightening on the way. Resolves when it lands.
func deal_from(from_world: Vector3, dur := 0.55, start_scale := 0.85, start_yaw := 0.0, rise := 0.0) -> void:
	busy = true
	set_raised(true)
	set_face_up(false)
	var start := to_local(from_world)
	var up := start + Vector3(0, rise, 0)
	var k_rise := 0.3 if rise > 0.0 else 0.0
	pivot.position = start
	pivot.rotation = Vector3(0, start_yaw, 0)
	pivot.scale = Vector3.ONE * start_scale
	var tw := create_tween()
	if k_rise > 0.0:
		tw.tween_property(pivot, "position", up, dur * k_rise).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(t: float):
		var e := 1.0 - pow(1.0 - t, 3.0)
		var p := up.lerp(Vector3.ZERO, e)
		p.y += sin(t * PI) * 70.0
		pivot.position = p
		pivot.rotation = Vector3(sin(t * PI) * -0.25, lerpf(start_yaw, 0.0, smoothstep(0.0, 0.7, t)), 0)
		flipper.rotation.z = PI * (1.0 - smoothstep(0.2, 0.85, t))
		pivot.scale = Vector3.ONE * lerpf(start_scale, 1.0, e), 0.0, 1.0, dur * (1.0 - k_rise))
	await tw.finished
	set_face_up(true)
	pivot.position = Vector3.ZERO
	pivot.rotation = Vector3.ZERO
	pivot.scale = Vector3.ONE
	set_raised(false)
	busy = false
	_land_bump()


func _land_bump() -> void:
	var tw := create_tween()
	tw.tween_property(pivot, "scale", Vector3(1.04, 1.0, 1.04), 0.06)
	tw.tween_property(pivot, "scale", Vector3.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Bring the card up to `world_point`, enlarged and facing the camera.
func lift_to(world_point: Vector3, zoom: float, face_tilt: float, dur := 0.34) -> void:
	busy = true
	set_raised(true)
	var target := to_local(world_point)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(pivot, "position", target, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(pivot, "scale", Vector3.ONE * zoom, dur).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(pivot, "rotation", Vector3(face_tilt, 0, 0), dur)


func drop_back(dur := 0.26) -> void:
	var tw := create_tween().set_parallel(true)
	tw.tween_property(pivot, "position", Vector3.ZERO, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(pivot, "scale", Vector3.ONE, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(pivot, "rotation", Vector3.ZERO, dur)
	tw.chain().tween_callback(func():
		reset_pose()
		_land_bump())


## The public reveal of a purchase or reservation: one continuous motion from
## wherever the card is to `world_target`, through `world_center` halfway
## (biggest and a little slower there), ending at `end_scale`. Emits arrived.
func present_to(world_center: Vector3, zoom: float, face_tilt: float, world_target: Vector3,
		end_scale := 0.36, dur := 1.9, show_back := false) -> void:
	busy = true
	set_raised(true)
	var start := pivot.position
	var s0 := pivot.scale.x
	var r0 := pivot.rotation
	var c := to_local(world_center)
	var end := to_local(world_target)
	var f0 := flipper.rotation.z
	var tw := create_tween()
	tw.tween_method(func(t: float):
		var u := present_time(t)
		pivot.position = present_path(u, start, c, end)
		pivot.scale = Vector3.ONE * present_scale(u, s0, zoom, end_scale)
		var near := 1.0 - smoothstep(0.0, 0.35, absf(u - 0.5))
		pivot.rotation = r0.lerp(Vector3(face_tilt, 0, 0), smoothstep(0.0, 0.5, u)).lerp(Vector3.ZERO, smoothstep(0.5, 1.0, u)) \
				+ Vector3(0, sin(u * TAU) * 0.08, 0)
		if show_back:
			flipper.rotation.z = lerpf(f0, PI, smoothstep(0.0, 0.3, u))
		_set_flash(0.22 * near), 0.0, 1.0, dur)
	tw.tween_callback(func():
		_set_flash(0.0)
		arrived.emit())


## Arc to `world_target` with the scale going to `end_scale` (flights to
## your area, a player's panel, the reserve).
func fly_to(world_target: Vector3, end_scale: float, dur := 0.6, arc := 120.0) -> void:
	busy = true
	set_raised(true)
	var start := pivot.position
	var s0 := pivot.scale.x
	var r0 := pivot.rotation
	var target := to_local(world_target)
	var tw := create_tween()
	tw.tween_method(func(t: float):
		var p := start.lerp(target, t)
		p.y += sin(t * PI) * arc
		pivot.position = p
		pivot.scale = Vector3.ONE * lerpf(s0, end_scale, t)
		pivot.rotation = r0.lerp(Vector3.ZERO, t) + Vector3(sin(t * PI) * 0.3, 0, -sin(t * PI) * 0.2),
		0.0, 1.0, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(func(): arrived.emit())


## Materialise out of embers.
func appear(dur := 0.8) -> void:
	busy = true
	set_dissolve(1.0)
	var tw := create_tween()
	tw.tween_method(set_dissolve, 1.0, 0.0, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func(): busy = false)


## Time warp for every reveal: slower around the middle, never stopping.
static func present_time(t: float) -> float:
	return t + 0.45 * sin(TAU * t) / TAU


## One smooth curve start -> centre -> end (Catmull-Rom), centre halfway.
static func present_path(u: float, start: Vector3, center: Vector3, end: Vector3) -> Vector3:
	var pts := [start, start, center, end, end]
	var seg := clampi(int(u * 2.0), 0, 1)
	var f := u * 2.0 - seg
	var p0: Vector3 = pts[seg]
	var p1: Vector3 = pts[seg + 1]
	var p2: Vector3 = pts[seg + 2]
	var p3: Vector3 = pts[seg + 3]
	var f2 := f * f
	var f3 := f2 * f
	return 0.5 * ((2.0 * p1) + (-p0 + p2) * f + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * f3)


static func present_scale(u: float, s0: float, zoom: float, s1: float) -> float:
	return lerpf(lerpf(s0, zoom, smoothstep(0.0, 0.5, u)), s1, smoothstep(0.5, 1.0, u))
