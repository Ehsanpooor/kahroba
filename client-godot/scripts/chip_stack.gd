class_name ChipStack
extends Node3D
## A stack of gem tokens: one real chip per token (up to MAX_SHOWN), so a pile
## grows and shrinks as tokens come and go, with its count beside it. Tokens
## that move are separate flying chips. Local units are design px.

const THICK := 0.25  # chip thickness relative to its radius
const BEVEL := 0.065  # radius of the rounded edge, relative to the chip's radius
const MAX_SHOWN := 4
## Enamel down the side of each token: the colour of its painted face's rim.
const SIDE := {
	"white": Color(0.93, 0.87, 0.77), "black": Color(0.2, 0.2, 0.2), "blue": Color(0.06, 0.3, 0.84),
	"red": Color(0.84, 0.08, 0.12), "green": Color(0.05, 0.54, 0.26), "gold": Color(0.92, 0.72, 0.26),
}

static var _mesh: ArrayMesh
static var _mats := {}  # col (+ "_d") -> material

var color := "red"
var count := 0
var radius := 44.0
var chips: Array[Node3D] = []
var label: Label3D
var badge: Node3D
var ghost: Node3D
var _base := Node3D.new()
var _label_a := 1.0


## One chip of radius 1 (scale it to the radius you want).
static func make_chip(col: String, dark := false) -> Node3D:
	if _mesh == null:
		_mesh = _chip_mesh(64, 5)
	var key := col + ("_d" if dark else "")
	if not _mats.has(key):
		var m := ShaderMaterial.new()
		m.shader = preload("res://shaders/chip.gdshader")
		var t := Gems.token_tex(col)
		m.set_shader_parameter("has_tex", 1.0 if t else 0.0)
		if t:
			m.set_shader_parameter("tex", t)
		m.set_shader_parameter("col", Gems.BASE[col])
		m.set_shader_parameter("side", SIDE.get(col, Gems.BASE[col]))
		m.set_shader_parameter("glint", Gems.GLOW[col])
		m.set_shader_parameter("inlay", Color(0.85, 0.86, 0.9) if col == "white" else Color(0.95, 0.75, 0.36))
		m.set_shader_parameter("dark", 1.0 if dark else 0.0)
		_mats[key] = m
	var n := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh
	mi.material_override = _mats[key]
	n.add_child(mi)
	return n


## One chip of radius 1 and height THICK, centred on the origin: the outline
## (flat face, rounded edge, straight side, rounded edge, flat back) turned
## around the Y axis, with smooth normals so the edges shade round.
static func _chip_mesh(segments: int, bevel_steps: int) -> ArrayMesh:
	var h := THICK * 0.5
	var b := BEVEL
	var prof: Array[Vector4] = []  # x = radius, y = height, z/w = normal (radial, up)
	prof.append(Vector4(0.0, h, 0.0, 1.0))
	for i in bevel_steps + 1:
		var a := PI * 0.5 * (1.0 - float(i) / bevel_steps)
		prof.append(Vector4(1.0 - b + b * cos(a), h - b + b * sin(a), cos(a), sin(a)))
	for i in bevel_steps + 1:
		var a := -PI * 0.5 * float(i) / bevel_steps
		prof.append(Vector4(1.0 - b + b * cos(a), -h + b + b * sin(a), cos(a), sin(a)))
	prof.append(Vector4(0.0, -h, 0.0, -1.0))
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	for s in segments + 1:
		var ang := TAU * s / segments
		var dir := Vector2(cos(ang), sin(ang))
		for k in prof.size():
			var q := prof[k]
			verts.append(Vector3(dir.x * q.x, q.y, dir.y * q.x))
			normals.append(Vector3(dir.x * q.z, q.w, dir.y * q.z).normalized())
			uvs.append(Vector2(0.5 + dir.x * q.x * 0.5, 0.5 + dir.y * q.x * 0.5))
	var idx := PackedInt32Array()
	var rows := prof.size()
	for s in segments:
		for k in rows - 1:
			var a := s * rows + k
			var c := (s + 1) * rows + k
			idx.append_array([a, c, a + 1, a + 1, c, c + 1])
	return Meshes._build(verts, uvs, normals, idx)


## `label_at`: where the count sits, relative to the stack (design px);
## Vector2.INF for no count.
func setup(col: String, n: int, r_px: float, label_at := Vector2(0.85, 0.8), label_px := -1.0) -> void:
	color = col
	radius = r_px
	add_child(_base)
	ghost = make_chip(col, true)
	ghost.scale = Vector3.ONE * radius
	ghost.position.y = radius * THICK * 0.5
	_base.add_child(ghost)
	if label_at != Vector2.INF:
		var lp := Vector2(label_at.x * radius, label_at.y * radius)
		var d := radius * 0.78 if label_px < 0.0 else label_px * 1.35
		badge = Gems.pip("black", 0, d, lp)
		badge.position.y = 1.0
		# the pip carries its own label; keep a handle to change the number
		label = badge.get_child(1) as Label3D
		label.modulate = Color(1, 1, 1)
		for c in badge.get_children():
			if c is MeshInstance3D:
				(c as MeshInstance3D).material_override.render_priority = 4
			elif c is Label3D:
				(c as Label3D).render_priority = 6
				(c as Label3D).outline_render_priority = 5
		add_child(badge)
	set_count(n)


## Lean the pile back by `deg`, so the camera above sees its side (the design's piles).
func lean(deg: float) -> void:
	_base.rotation.x = -deg_to_rad(deg)
	# leaning tips the near edge of the bottom token down: lift the pile so no
	# token (the empty pile's dark one included) sinks into the table
	_base.position.y = radius * sin(deg_to_rad(deg)) + 0.5


## The count as plain text beside the pile (the design's bank), `at` in design px.
func plain_count(at: Vector2, px: float, color: Color) -> void:
	label = Fonts.label3d(str(count), px, color, "num", 0.0)
	_label_a = color.a
	label.font = PlayerView.jfont(400)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.position = Vector3(at.x, 2.0, at.y)
	label.render_priority = 6
	add_child(label)
	set_count(count)


func set_count(n: int) -> void:
	count = maxi(n, 0)
	var shown := mini(count, MAX_SHOWN)
	while chips.size() > shown:
		chips.pop_back().queue_free()
	while chips.size() < shown:
		var c := make_chip(color)
		c.scale = Vector3.ONE * radius
		_base.add_child(c)
		chips.append(c)
	for i in chips.size():
		chips[i].position = _slot(i)
		chips[i].rotation.y = _jit(i, 3.0) * PI
	ghost.visible = count == 0
	if label:
		label.text = str(count)
		if badge:
			badge.visible = true
		label.modulate.a = (0.5 if count == 0 else 1.0) * _label_a


func _jit(i: int, salt: float) -> float:
	return fposmod(sin((i + 1) * 12.9898 + salt * 78.233 + color.hash() % 97) * 43758.5453, 1.0) - 0.5


func _slot(i: int) -> Vector3:
	return Vector3(_jit(i, 1.0) * radius * 0.02, radius * THICK * (i + 0.5), _jit(i, 2.0) * radius * 0.02)


## Where the next chip lands (local).
func top_local() -> Vector3:
	return _slot(mini(count, MAX_SHOWN - 1)) + Vector3(0, radius * THICK if count >= MAX_SHOWN else 0.0, 0)


func top_world() -> Vector3:
	return _base.to_global(top_local())


func world_radius() -> float:
	return radius * global_basis.get_scale().x


## A loose chip lifted off the top of the pile (world space); count - 1.
func take_flying(world_parent: Node3D) -> Node3D:
	var c := make_chip(color)
	world_parent.add_child(c)
	var from: Vector3 = chips.back().global_position if not chips.is_empty() else top_world()
	c.global_position = from
	c.scale = Vector3.ONE * world_radius()
	set_count(count - 1)
	pop()
	return c


## A flying chip lands here: it becomes the top of the pile; count + 1.
func receive(flying: Node3D) -> void:
	flying.queue_free()
	set_count(count + 1)
	if not chips.is_empty() and count <= MAX_SHOWN:
		var top: Node3D = chips.back()
		var y := top.position.y
		top.position.y = y + radius * 0.6
		var tw := top.create_tween()
		tw.tween_property(top, "position:y", y, 0.28).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	pop()


func pop() -> void:
	if label == null:
		return
	label.scale = Vector3.ONE * 1.5
	var tw := label.create_tween()
	tw.tween_property(label, "scale", Vector3.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## A little hop of the whole pile (a refused tap).
func shake() -> void:
	var tw := _base.create_tween()
	for i in 4:
		tw.tween_property(_base, "position:x", (5.0 if i % 2 == 0 else -5.0), 0.04)
	tw.tween_property(_base, "position:x", 0.0, 0.04)


func contains_world(p: Vector3) -> bool:
	var l := to_local(p)
	return Vector2(l.x, l.z).length() < radius * 1.25
