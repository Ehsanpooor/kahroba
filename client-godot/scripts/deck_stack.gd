class_name DeckStack
extends Node3D
## A face-down deck at its hole, as the host's design (Frame 45, Figma 3D:
## swing Y 75, field of view 25): landscape card backs swung away so the top
## card shows as a tall narrow panel in true perspective (its far left edge
## shorter), the cards behind it as slim edges to its right. Thins as it
## empties. Local units are table design px; shapes are measured on the design.

const K := 1080.0 / 1221.0
## The top card, around the hole's centre (design PNG px): far (left) edge and near (right) edge.
const FAR_X := -34.5
const FAR_Y := Vector2(-77.0, 73.0)
const NEAR_X := 25.5
const NEAR_Y := Vector2(-108.0, 103.0)
const EDGE := 10.0  # how much of each card behind shows
const MAX_BEHIND := 3

var tier := 1
var count := 0
var size := Vector2(67, 192) * K  # the hole
var _tex: Texture2D
var _quads: Array[MeshInstance3D] = []
var _holder := Node3D.new()


func setup(t: int, n: int, hole: Vector2) -> void:
	tier = t
	size = hole
	var p := "res://assets/splendor/hud/back_%d.png" % t
	_tex = Tex.get_tex(p) if ResourceLoader.exists(p) else null
	add_child(_holder)
	set_count(n)


## One card back as a perspective trapezoid shifted `dx` to the right.
func _card(dx: float, shade: float) -> MeshInstance3D:
	var fx := (FAR_X + dx) * K
	var nx := (NEAR_X + dx) * K
	var verts := PackedVector3Array([
		Vector3(fx, 0, FAR_Y.x * K), Vector3(nx, 0, NEAR_Y.x * K),
		Vector3(nx, 0, NEAR_Y.y * K), Vector3(fx, 0, FAR_Y.y * K)])
	# perspective weight: proportional to how tall each edge appears
	var qf := (FAR_Y.y - FAR_Y.x) / (NEAR_Y.y - NEAR_Y.x)
	var qn := 1.0
	var uvs := PackedVector2Array([Vector2(0, 0) * qf, Vector2(1, 0) * qn, Vector2(1, 1) * qn, Vector2(0, 1) * qf])
	var uv2 := PackedVector2Array([Vector2(qf, 0), Vector2(qn, 0), Vector2(qn, 0), Vector2(qf, 0)])
	var normals := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/deck_back.gdshader")
	mat.set_shader_parameter("tex", _tex)
	mat.set_shader_parameter("shade", shade)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func set_count(n: int) -> void:
	count = n
	for q in _quads:
		q.queue_free()
	_quads.clear()
	if n <= 0 or _tex == null:
		return
	var behind := clampi(ceili((n - 1) / 8.0), 0, MAX_BEHIND)
	# farthest first, the top card last (on top)
	for k in range(behind, -1, -1):
		var q := _card(k * EDGE, 1.0 - k * 0.08)
		q.position.y = (behind - k) * 0.05
		(q.material_override as ShaderMaterial).render_priority = behind - k
		_holder.add_child(q)
		_quads.append(q)


## Where the top card is (the dealt card starts here).
func top_world() -> Vector3:
	return to_global(Vector3((FAR_X + NEAR_X) * 0.5 * K, 0.6, 0))


func top_height() -> float:
	return 0.6


func contains_world(p: Vector3) -> bool:
	var l := to_local(p)
	return absf(l.x) <= size.x * 0.5 + EDGE * K * 2.0 and absf(l.z) <= size.y * 0.5


func pop() -> void:
	var tw := create_tween()
	tw.tween_property(_holder, "scale", Vector3(1.04, 1.0, 1.04), 0.08)
	tw.tween_property(_holder, "scale", Vector3.ONE, 0.2).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
