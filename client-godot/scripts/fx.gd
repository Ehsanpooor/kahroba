class_name FX
extends RefCounted
## One-shot particle bursts, light rings and trails, all in world space.

static var _mats: Dictionary = {}


static func _particle_mesh(size: float, additive := true) -> QuadMesh:
	var key := "add" if additive else "mix"
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = Tex.dot()
		m.no_depth_test = false
		m.disable_receive_shadows = true
		m.render_priority = 55  # above the dimming layer
		_mats[key] = m
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	q.material = _mats[key]
	return q


static func _fade_ramp(c: Color) -> Gradient:
	var g := Gradient.new()
	g.set_color(0, Color(c.r, c.g, c.b, 1.0))
	g.set_color(1, Color(c.r, c.g, c.b, 0.0))
	g.add_point(0.15, Color(c.r * 1.2, c.g * 1.2, c.b * 1.2, 1.0))
	return g


## Spark burst. `u` is world units per mock px so sizes stay design-relative.
static func burst(parent: Node, pos: Vector3, color: Color, u: float, amount := 36,
		speed := 300.0, life := 0.8, size := 14.0, up_bias := 0.6) -> void:
	var p := CPUParticles3D.new()
	p.one_shot = true
	p.explosiveness = 0.95
	p.amount = amount
	p.lifetime = life
	p.mesh = _particle_mesh(size * u)
	p.direction = Vector3(0, 1, 0)
	p.spread = 180.0 * (1.0 - up_bias * 0.5)
	p.initial_velocity_min = speed * u * 0.35
	p.initial_velocity_max = speed * u
	p.gravity = Vector3(0, -260.0 * u, 0)
	p.damping_min = 80.0 * u
	p.damping_max = 160.0 * u
	p.scale_amount_min = 0.4
	p.scale_amount_max = 1.2
	p.color_ramp = _fade_ramp(color)
	parent.add_child(p)
	p.global_position = pos
	p.emitting = true
	p.finished.connect(p.queue_free)


## Expanding flat ring of light on the table.
static func ring(parent: Node, pos: Vector3, color: Color, u: float, radius := 90.0, dur := 0.55) -> void:
	var g := Meshes.glow(1.0, color, 1.6, 1.0)
	(g.material_override as Material).render_priority = 55
	parent.add_child(g)
	g.global_position = pos + Vector3(0, 2.0 * u, 0)
	g.scale = Vector3.ONE * radius * 0.4 * u
	var mat: ShaderMaterial = g.material_override
	var tw := g.create_tween().set_parallel(true)
	tw.tween_property(g, "scale", Vector3.ONE * radius * 2.0 * u, dur).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(v: float): mat.set_shader_parameter("intensity", v), 1.6, 0.0, dur)
	tw.chain().tween_callback(g.queue_free)


## Soft flash of light (additive blob) that fades.
static func flash(parent: Node, pos: Vector3, color: Color, u: float, radius := 160.0, dur := 0.45) -> void:
	var g := Meshes.glow(1.0, color, 1.2, 0.0)
	(g.material_override as Material).render_priority = 54
	parent.add_child(g)
	g.global_position = pos + Vector3(0, 3.0 * u, 0)
	g.scale = Vector3.ONE * radius * 2.0 * u
	var mat: ShaderMaterial = g.material_override
	var tw := g.create_tween()
	tw.tween_method(func(v: float): mat.set_shader_parameter("intensity", v), 1.2, 0.0, dur)
	tw.tween_callback(g.queue_free)


## Continuous sparks left behind a moving node. Call stop_trail() on arrival.
static func trail(follow: Node3D, color: Color, u: float, size := 12.0) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.local_coords = false
	p.amount = 48
	p.lifetime = 0.5
	p.mesh = _particle_mesh(size * u)
	p.direction = Vector3(0, 1, 0)
	p.spread = 180.0
	p.initial_velocity_min = 10.0 * u
	p.initial_velocity_max = 60.0 * u
	p.gravity = Vector3(0, -40.0 * u, 0)
	p.scale_amount_min = 0.3
	p.scale_amount_max = 1.0
	p.color_ramp = _fade_ramp(color)
	follow.add_child(p)
	p.emitting = true
	return p


static func stop_trail(p: CPUParticles3D) -> void:
	if not is_instance_valid(p):
		return
	var keep := p.global_transform
	var root := p.get_tree().current_scene
	p.get_parent().remove_child(p)
	root.add_child(p)
	p.global_transform = keep
	p.emitting = false
	root.get_tree().create_timer(p.lifetime + 0.1).timeout.connect(p.queue_free)


## Ambient dust motes drifting in the candle light.
static func dust(parent: Node, center: Vector3, extents: Vector3, u: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 90
	p.lifetime = 9.0
	p.preprocess = 9.0
	p.mesh = _particle_mesh(7.0 * u)
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = extents
	p.direction = Vector3(0.3, 1, -0.2)
	p.spread = 60.0
	p.initial_velocity_min = 6.0 * u
	p.initial_velocity_max = 22.0 * u
	p.gravity = Vector3.ZERO
	p.scale_amount_min = 0.4
	p.scale_amount_max = 1.4
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.85, 0.55, 0.0))
	g.add_point(0.25, Color(1.0, 0.85, 0.55, 0.55))
	g.add_point(0.75, Color(1.0, 0.8, 0.5, 0.4))
	g.set_color(g.get_point_count() - 1, Color(1.0, 0.8, 0.5, 0.0))
	p.color_ramp = g
	parent.add_child(p)
	p.global_position = center
	return p
