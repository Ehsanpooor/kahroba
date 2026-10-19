class_name TLayout
extends RefCounted
## The landscape table is designed mobile first, at 2400 x 1080 "design px"
## (a 20:9 phone). Narrower screens (tablets, 16:9) show it whole, smaller;
## wider ones get a wider design: the extra width goes
## between the groups, so the left group (opponents, menu) stays at the left
## edge, the right group (tokens, turn, reserve) at the right edge, and the
## middle (cards, nobles) in the middle. Every 3D piece is put on the table
## exactly under its design position.

## The host's design frame (Frame 45: 2619 x 1221 px) scaled to 1080 high.
const D := Vector2(2619.0 * 1080.0 / 1221.0, 1080.0)

var cam: Camera3D
var vp: Vector2
var size: Vector2  # the design size for this screen (width >= D.x)
var extra := 0.0  # design px added to the width
var s: float  # screen px per design px
var origin: Vector2


func _init(camera: Camera3D, viewport_size: Vector2) -> void:
	cam = camera
	vp = viewport_size
	size = Vector2(maxf(D.x, D.y * vp.x / vp.y), D.y)
	extra = size.x - D.x
	s = minf(vp.x / size.x, vp.y / size.y)
	origin = (vp - size * s) * 0.5


## A design x of the middle group, on this screen.
func mid(x: float) -> float:
	return x + extra * 0.5


## A design x of the right-hand group, on this screen.
func right(x: float) -> float:
	return x + extra


func screen(m: Vector2) -> Vector2:
	return origin + m * s


func design(sp: Vector2) -> Vector2:
	return (sp - origin) / s


func rect(pos: Vector2, size: Vector2) -> Rect2:
	return Rect2(screen(pos), size * s)


func world(m: Vector2, height := 0.0) -> Vector3:
	return screen_to_table(screen(m), height)


func screen_to_table(sp: Vector2, height := 0.0) -> Vector3:
	var o := cam.project_ray_origin(sp)
	var d := cam.project_ray_normal(sp)
	if absf(d.y) < 0.0001:
		return o
	return o + d * ((height - o.y) / d.y)


## World units per design px at a design position (measured across).
func unit(m: Vector2) -> float:
	return world(m + Vector2(30, 0)).distance_to(world(m - Vector2(30, 0))) / 60.0
