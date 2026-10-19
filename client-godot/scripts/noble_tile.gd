class_name NobleTile
extends Node3D
## A noble: a square portrait tile that hangs from the top edge of the
## screen, only its lower part showing (face, points and what it needs).
## Hover or tap slides it down into full view. Local units are design px.

const S := 184.0
const THICK := 4.0
const REVEAL := 96.0  # how far it slides down when shown in full
const RADIUS := 0.16 * S  # the frame's rounded corners
const BAND := 4.5  # the gold line
const NUM_PX := 0.19 * S

static var _mesh: ArrayMesh

var data: Dictionary = {}
var pivot := Node3D.new()
var body := MeshInstance3D.new()
var overlay := Node3D.new()
var face_mat: ShaderMaterial
var hover := 0.0
var target_hover := 0.0
var busy := false
var _items: Array = []


func _init() -> void:
	add_child(pivot)
	if _mesh == null:
		_mesh = Meshes.rounded_slab(S, S, RADIUS, THICK, 6)
	body.mesh = _mesh
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	pivot.add_child(body)
	overlay.position.y = THICK + 0.35
	pivot.add_child(overlay)


func setup(d: Dictionary) -> void:
	data = d
	face_mat = ShaderMaterial.new()
	face_mat.shader = preload("res://shaders/noble_face.gdshader")
	var t := Gems.noble_tex(String(d["id"]))
	face_mat.set_shader_parameter("has_tex", 1.0 if t else 0.0)
	if t:
		face_mat.set_shader_parameter("tex", t)
	var tints := [Color(0.45, 0.12, 0.14), Color(0.14, 0.2, 0.42), Color(0.2, 0.32, 0.18), Color(0.35, 0.22, 0.1)]
	face_mat.set_shader_parameter("tint", tints[String(d["id"]).hash() % tints.size()])
	face_mat.set_shader_parameter("size_px", Vector2(S, S))
	face_mat.set_shader_parameter("radius_px", RADIUS)
	face_mat.set_shader_parameter("band_px", BAND)
	body.set_surface_override_material(0, face_mat)
	body.set_surface_override_material(1, SCard.back_material(3))
	body.set_surface_override_material(2, SCard.rim_material())
	# as the host's design (fractions of the tile's width): the points in gold
	# bottom-left, the cards it needs to the right, standing on the frame's
	# bottom edge; every one with a soft drop shadow (blur 3, black 80 %)
	var bottom := S * 0.5 - BAND
	var pts := Fonts.label3d("3", NUM_PX, Color("#d4a74c"), "num", 5.0, Color(0, 0, 0, 0.55))
	pts.position = Vector3(-S * 0.5 + 0.11 * S, 0.2, bottom - 0.106 * S)
	overlay.add_child(pts)
	_items.append([pts, 4])
	var reqs: Array = d["reqs"]
	var xs: Array = [0.39, 0.59, 0.81].slice(3 - reqs.size())
	var cw := 0.2 * S
	var ch := 0.218 * S
	for k in reqs.size():
		var col: String = reqs[k]
		var cx := -S * 0.5 + float(xs[k]) * S
		var cz := bottom - ch * 0.5
		var sh := Meshes.shadow_of(Meshes.rect_shadow_tex(), cw * 1.4, ch * 1.4, 0.8, 1.5)
		sh.position = Vector3(cx, 0.05, cz)
		overlay.add_child(sh)
		_items.append([sh, 1])
		var path := "res://assets/splendor/hud/card_%s.png" % col
		if ResourceLoader.exists(path):
			var card := Meshes.art(path, cw, ch)
			(card.material_override as ShaderMaterial).set_shader_parameter("uv_rect", Vector4(0, 0, 1, ch / cw * 0.711))
			(card.material_override as ShaderMaterial).set_shader_parameter("lit", 0.0)
			card.position = Vector3(cx, 0.1, cz)
			overlay.add_child(card)
			_items.append([card, 2])
		var num := Fonts.label3d(str(int(d["need"])), NUM_PX, Gems.INK[col], "num", 0.0)
		num.position = Vector3(cx, 0.2, bottom - 0.106 * S)
		overlay.add_child(num)
		_items.append([num, 4])
	set_raised(false)


func set_raised(r: bool) -> void:
	for e in _items:
		SCard._set_priority(e[0], (20 if r else 0) + int(e[1]) * 2)


func _process(delta: float) -> void:
	hover = lerpf(hover, target_hover, 1.0 - exp(-delta * 9.0))
	if face_mat:
		face_mat.set_shader_parameter("highlight", hover * 0.6)
	if not busy:
		pivot.position = Vector3(0, hover * 10.0, hover * REVEAL)
		pivot.rotation = Vector3(-hover * 0.08, 0, 0)


func contains_world(p: Vector3) -> bool:
	if not visible:
		return false
	var l := pivot.to_local(p)
	return absf(l.x) <= S * 0.5 and absf(l.z) <= S * 0.5


func flash(v: float) -> void:
	if face_mat:
		face_mat.set_shader_parameter("flash", v)
