class_name Meshes
extends RefCounted
## Tiny mesh builders. Flat quads lie on XZ (normal +Y) with the texture's
## top edge toward -Z, which is "up" on screen.

static func quad(w: float, h: float, offset := Vector2.ZERO) -> ArrayMesh:
	var hw := w * 0.5
	var hh := h * 0.5
	var ox := offset.x
	var oz := offset.y
	var verts := PackedVector3Array([
		Vector3(-hw + ox, 0, -hh + oz), Vector3(hw + ox, 0, -hh + oz),
		Vector3(hw + ox, 0, hh + oz), Vector3(-hw + ox, 0, hh + oz)])
	var uvs := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	var normals := PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP, Vector3.UP])
	return _build(verts, uvs, normals, PackedInt32Array([0, 1, 2, 0, 2, 3]))


## Upright quad in the XY plane facing +Z, bottom edge at y = 0.
static func upright(w: float, h: float) -> ArrayMesh:
	var hw := w * 0.5
	var verts := PackedVector3Array([
		Vector3(-hw, h, 0), Vector3(hw, h, 0), Vector3(hw, 0, 0), Vector3(-hw, 0, 0)])
	var uvs := PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	var n := Vector3.BACK
	var normals := PackedVector3Array([n, n, n, n])
	return _build(verts, uvs, normals, PackedInt32Array([0, 1, 2, 0, 2, 3]))


## Disc on XZ, radius 1, UVs map onto the circle inscribed in the texture.
static func disc(segments := 40, facing_up := true) -> ArrayMesh:
	var verts := PackedVector3Array([Vector3.ZERO])
	var uvs := PackedVector2Array([Vector2(0.5, 0.5)])
	var n := Vector3.UP if facing_up else Vector3.DOWN
	var normals := PackedVector3Array([n])
	var idx := PackedInt32Array()
	for i in segments + 1:
		var a := TAU * i / segments
		var p := Vector2(cos(a), sin(a))
		verts.append(Vector3(p.x, 0, p.y))
		uvs.append(Vector2(0.5 + p.x * 0.495, 0.5 + (p.y if facing_up else -p.y) * 0.495))
		normals.append(n)
	for i in segments:
		if facing_up:
			idx.append_array([0, i + 2, i + 1])
		else:
			idx.append_array([0, i + 1, i + 2])
	return _build(verts, uvs, normals, idx)


## A thin slab with rounded corners (cards, tiles, trays), centred on the
## origin: `w` along X, `h` along Z (-Z is up on screen), from y = 0 to
## y = `thick`. Surface 0 is the face (top, UV 0..1 with v = 0 at -Z),
## surface 1 the back (bottom; its UV reads correctly once the slab is
## turned over around Z), surface 2 the rim.
static func rounded_slab(w: float, h: float, r: float, thick: float, seg := 6) -> ArrayMesh:
	r = minf(r, minf(w, h) * 0.5)
	var ring := PackedVector2Array()
	var norms := PackedVector2Array()
	var centres := [Vector2(w * 0.5 - r, -h * 0.5 + r), Vector2(w * 0.5 - r, h * 0.5 - r),
			Vector2(-w * 0.5 + r, h * 0.5 - r), Vector2(-w * 0.5 + r, -h * 0.5 + r)]
	for k in 4:
		var a0 := -PI * 0.5 + k * PI * 0.5
		for i in seg + 1:
			var a := a0 + PI * 0.5 * i / seg
			var n := Vector2(cos(a), sin(a))
			ring.append((centres[k] as Vector2) + n * r)
			norms.append(n)
	var m := ArrayMesh.new()
	var n_pts := ring.size()
	for side in 2:  # 0 face (top), 1 back (bottom)
		var verts := PackedVector3Array([Vector3(0, thick if side == 0 else 0.0, 0)])
		var uvs := PackedVector2Array([Vector2(0.5, 0.5)])
		var nrm := Vector3.UP if side == 0 else Vector3.DOWN
		var normals := PackedVector3Array([nrm])
		for p in ring:
			verts.append(Vector3(p.x, thick if side == 0 else 0.0, p.y))
			var u := (p.x + w * 0.5) / w
			uvs.append(Vector2(u if side == 0 else 1.0 - u, (p.y + h * 0.5) / h))
			normals.append(nrm)
		var idx := PackedInt32Array()
		for i in n_pts:
			var a := i + 1
			var b := (i + 1) % n_pts + 1
			if side == 0:
				idx.append_array([0, a, b])
			else:
				idx.append_array([0, b, a])
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_INDEX] = idx
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# rim
	var rv := PackedVector3Array()
	var ruv := PackedVector2Array()
	var rn := PackedVector3Array()
	var ri := PackedInt32Array()
	for i in n_pts + 1:
		var p := ring[i % n_pts]
		var n2 := norms[i % n_pts]
		rv.append(Vector3(p.x, thick, p.y))
		rv.append(Vector3(p.x, 0.0, p.y))
		var u := float(i) / n_pts
		ruv.append(Vector2(u, 0.0))
		ruv.append(Vector2(u, 1.0))
		rn.append(Vector3(n2.x, 0, n2.y))
		rn.append(Vector3(n2.x, 0, n2.y))
	for i in n_pts:
		var t0 := i * 2
		ri.append_array([t0, t0 + 1, t0 + 2, t0 + 1, t0 + 3, t0 + 2])
	var ra := []
	ra.resize(Mesh.ARRAY_MAX)
	ra[Mesh.ARRAY_VERTEX] = rv
	ra[Mesh.ARRAY_TEX_UV] = ruv
	ra[Mesh.ARRAY_NORMAL] = rn
	ra[Mesh.ARRAY_INDEX] = ri
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ra)
	return m


## A soft rounded-rectangle shadow texture (cards and tiles).
static var _rr_shadow: Texture2D


static func rect_shadow_tex() -> Texture2D:
	if _rr_shadow:
		return _rr_shadow
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var p := Vector2(x + 0.5, y + 0.5) / n * 2.0 - Vector2.ONE
			var q := Vector2(absf(p.x), absf(p.y)) - Vector2(0.62, 0.62)
			var d := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - 0.08
			var a := 1.0 - smoothstep(-0.25, 0.3, d)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	img.generate_mipmaps()
	_rr_shadow = ImageTexture.create_from_image(img)
	return _rr_shadow


static func _build(verts: PackedVector3Array, uvs: PackedVector2Array,
		normals: PackedVector3Array, idx: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m


## A MeshInstance3D carrying one flat art texture with the shared art shader.
static func art(tex_path: String, w: float, h := -1.0, offset := Vector2.ZERO) -> MeshInstance3D:
	var t := Tex.get_tex(tex_path)
	if h < 0.0:
		h = w * t.get_height() / t.get_width()
	var mi := MeshInstance3D.new()
	mi.mesh = quad(w, h, offset)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/art.gdshader")
	mat.set_shader_parameter("tex", t)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func shadow_of(tex: Texture2D, w: float, h: float, strength := 0.5, blur := 2.5) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = quad(w, h)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/shadow.gdshader")
	mat.set_shader_parameter("tex", tex)
	mat.set_shader_parameter("strength", strength)
	mat.set_shader_parameter("blur", blur)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func glow(size: float, color: Color, intensity := 1.0, ring := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = quad(size, size)
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/glow.gdshader")
	mat.set_shader_parameter("color", color)
	mat.set_shader_parameter("intensity", intensity)
	mat.set_shader_parameter("ring", ring)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi
