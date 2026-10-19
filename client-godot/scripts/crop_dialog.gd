class_name CropDialog
extends Control
## Fit a photo into the round portrait: drag to move it, pinch (or the slider,
## or the mouse wheel) to zoom. The circle shows what the portrait will be.
## `done(image)` gets the 256 px square, or null when cancelled.

signal done(image: Image)

var _src: Image
var _tex: ImageTexture
var _u := 1.0
var _view := 0.0  # side of the square crop area, px
var _area: Control  # the square crop area (clips the photo)
var _photo: TextureRect
var _slider: HSlider
var _min_scale := 1.0  # photo px -> screen px when the photo just covers the square
var _zoom := 1.0  # 1 .. 4, on top of _min_scale
var _pos := Vector2.ZERO  # the photo's top-left inside the area
var _touches := {}  # touch index -> position, for the pinch
var _pinch_d := 0.0
var _pinch_zoom := 1.0
var _drag_from := Vector2.ZERO
var _pos_from := Vector2.ZERO
var _dragging := false


static func open(parent: Node, img: Image, on_done: Callable) -> CropDialog:
	var d := CropDialog.new()
	d._src = img
	d.done.connect(on_done)
	parent.add_child(d)
	return d


func _ready() -> void:
	var vp := get_viewport().get_visible_rect().size
	position = Vector2.ZERO
	size = vp
	mouse_filter = Control.MOUSE_FILTER_STOP
	_u = minf(vp.x / 800.0, vp.y / 1500.0)
	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.02, 0.92)
	shade.size = vp
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	var cx := vp.x * 0.5
	var t := UI.label("FIT YOUR PHOTO", 44.0 * _u, UI.GOLD, "title_bold", 700.0 * _u)
	t.size = Vector2(vp.x, 60.0 * _u)
	t.position = Vector2(0, 120.0 * _u)
	add_child(t)
	var hint := UI.label("Drag to move  •  pinch or slide to zoom", 26.0 * _u, UI.MUTED, "serif", 700.0 * _u)
	hint.size = Vector2(vp.x, 40.0 * _u)
	hint.position = Vector2(0, 182.0 * _u)
	add_child(hint)

	_view = minf(600.0 * _u, vp.x - 80.0 * _u)
	_area = Control.new()
	_area.clip_contents = true
	_area.size = Vector2(_view, _view)
	_area.position = Vector2(cx - _view * 0.5, 250.0 * _u)
	_area.mouse_filter = Control.MOUSE_FILTER_STOP
	_area.gui_input.connect(_on_area_input)
	add_child(_area)
	if _src.is_compressed():
		_src.decompress()
	_tex = ImageTexture.create_from_image(_src)
	_photo = TextureRect.new()
	_photo.texture = _tex
	_photo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_photo.stretch_mode = TextureRect.STRETCH_SCALE
	_photo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_area.add_child(_photo)
	# the round guide: dark outside the circle, a gold ring on it
	var guide := TextureRect.new()
	guide.texture = _guide_texture(512)
	guide.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	guide.stretch_mode = TextureRect.STRETCH_SCALE
	guide.size = _area.size
	guide.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_area.add_child(guide)
	var frame := Panel.new()
	frame.add_theme_stylebox_override("panel", UI.box_style(Color(0, 0, 0, 0), Color(0.6, 0.47, 0.24), 4.0, 2.0 * _u))
	frame.size = _area.size
	frame.position = _area.position
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frame)

	_min_scale = maxf(_view / _src.get_width(), _view / _src.get_height())
	_zoom = 1.0
	_pos = (Vector2(_view, _view) - Vector2(_src.get_size()) * _min_scale) * 0.5
	_apply()

	var sy := _area.position.y + _view + 70.0 * _u
	var minus := UI.label("−", 44.0 * _u, UI.GOLD, "num", 60.0 * _u)
	minus.size = Vector2(60, 60) * _u
	minus.position = Vector2(cx - 300.0 * _u, sy - 30.0 * _u)
	add_child(minus)
	var plus := UI.label("+", 44.0 * _u, UI.GOLD, "num", 60.0 * _u)
	plus.size = Vector2(60, 60) * _u
	plus.position = Vector2(cx + 240.0 * _u, sy - 30.0 * _u)
	add_child(plus)
	_slider = UI.slider(0.0, Vector2(460, 44) * _u, func(v: float): _set_zoom(1.0 + v * 3.0, Vector2(_view, _view) * 0.5))
	_slider.position = Vector2(cx - 230.0 * _u, sy - 22.0 * _u)
	add_child(_slider)

	var by := sy + 120.0 * _u
	var cancel := UI.button("CANCEL", Vector2(300, 110) * _u, "dark")
	cancel.position = Vector2(cx - 320.0 * _u, by)
	cancel.pressed.connect(func(): _close(null))
	add_child(cancel)
	var use := UI.button("USE PHOTO", Vector2(320, 110) * _u, "gold")
	use.position = Vector2(cx + 0.0 * _u, by)
	use.pressed.connect(func(): _close(_cropped()))
	add_child(use)


func _guide_texture(n: int) -> Texture2D:
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(n, n) * 0.5
	var r := n * 0.5 - 2.0
	for y in n:
		for x in n:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			var col := Color(0.0, 0.0, 0.03, 0.62) if d > r else Color(0, 0, 0, 0)
			if absf(d - r) < 3.0:
				col = Color(1.0, 0.82, 0.4, 0.95)
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


func _scale() -> float:
	return _min_scale * _zoom


## Zoom about a point of the area, keeping the photo under it still.
func _set_zoom(z: float, about: Vector2) -> void:
	var old := _scale()
	_zoom = clampf(z, 1.0, 4.0)
	var k := _scale() / old
	_pos = about - (about - _pos) * k
	_apply()
	if _slider and absf(_slider.value - (_zoom - 1.0) / 3.0) > 0.001:
		_slider.set_value_no_signal((_zoom - 1.0) / 3.0)


## The photo always covers the whole square.
func _apply() -> void:
	var sz := Vector2(_src.get_size()) * _scale()
	_pos.x = clampf(_pos.x, _view - sz.x, 0.0)
	_pos.y = clampf(_pos.y, _view - sz.y, 0.0)
	_photo.size = sz
	_photo.position = _pos


func _on_area_input(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		var st := e as InputEventScreenTouch
		if st.pressed:
			_touches[st.index] = st.position
		else:
			_touches.erase(st.index)
		if _touches.size() == 2:
			var ps: Array = _touches.values()
			_pinch_d = (ps[0] as Vector2).distance_to(ps[1])
			_pinch_zoom = _zoom
		_dragging = false
	elif e is InputEventScreenDrag:
		var sd := e as InputEventScreenDrag
		_touches[sd.index] = sd.position
		if _touches.size() == 2 and _pinch_d > 1.0:
			var ps2: Array = _touches.values()
			var d: float = (ps2[0] as Vector2).distance_to(ps2[1])
			_set_zoom(_pinch_zoom * d / _pinch_d, ((ps2[0] as Vector2) + (ps2[1] as Vector2)) * 0.5)
	elif e is InputEventMagnifyGesture:
		var mg := e as InputEventMagnifyGesture
		_set_zoom(_zoom * mg.factor, mg.position)
	elif e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_set_zoom(_zoom * 1.1, mb.position)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_set_zoom(_zoom / 1.1, mb.position)
		elif mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			_drag_from = mb.position
			_pos_from = _pos
	elif e is InputEventMouseMotion and _dragging and _touches.size() < 2:
		_pos = _pos_from + ((e as InputEventMouseMotion).position - _drag_from)
		_apply()


## The square under the area, from the original photo, at 256 px.
func _cropped() -> Image:
	var s := _scale()
	var side := _view / s
	var x0 := clampf(-_pos.x / s, 0.0, _src.get_width() - side)
	var y0 := clampf(-_pos.y / s, 0.0, _src.get_height() - side)
	var cut := _src.get_region(Rect2i(int(x0), int(y0), maxi(int(side), 1), maxi(int(side), 1)))
	cut.resize(256, 256, Image.INTERPOLATE_LANCZOS)
	return cut


func _close(img: Image) -> void:
	done.emit(img)
	queue_free()
