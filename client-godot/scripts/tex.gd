class_name Tex
extends RefCounted
## Texture cache. Textures loaded from script are not seen by the editor's
## "used in 3D" detection, so mipmaps are generated here at load time.

static var _cache: Dictionary = {}
static var _dot: Texture2D

## The player's own photo is a portrait like the others ("custom"), read from
## the device instead of the game files.
const CUSTOM := "res://assets/portraits/custom.png"
const CUSTOM_FILE := "user://avatar.png"


static func exists(path: String) -> bool:
	if path == CUSTOM:
		return FileAccess.file_exists(CUSTOM_FILE)
	return ResourceLoader.exists(path)


## The part of a portrait shown in a round avatar: the head of a character
## (the art is a full figure), or all of the player's photo (already cropped
## to the face in the crop window).
static func face_rect(portrait: String) -> Vector4:
	if portrait == "custom" or portrait == CUSTOM:
		return Vector4(0.0, 0.0, 1.0, 1.0)
	var r := Portraits.resolve(portrait.get_file().get_basename())
	if r.begins_with("A-"):
		return Vector4(0.08, 0.05, 0.84, 0.84)  # the new avatars are already head and shoulders
	return Vector4(0.22, 0.04, 0.56, 0.56)


## Drop a cached texture (the photo was replaced).
static func forget(path: String) -> void:
	_cache.erase(path)


static func get_tex(path: String) -> Texture2D:
	# old character portraits show as the new avatars (once those exist)
	if path.begins_with("res://assets/portraits/") and path != CUSTOM:
		var id := path.get_file().get_basename()
		var r := Portraits.resolve(id)
		if r != id:
			path = "res://assets/portraits/%s.png" % r
	if _cache.has(path):
		return _cache[path]
	var img: Image
	if path == CUSTOM:
		img = Image.load_from_file(CUSTOM_FILE) if FileAccess.file_exists(CUSTOM_FILE) else null
		if img == null:
			return get_tex("res://assets/portraits/M-04.png")
	else:
		var src: Texture2D = load(path)
		img = src.get_image()
	if img.is_compressed():
		img.decompress()
	img.generate_mipmaps()
	var t := ImageTexture.create_from_image(img)
	_cache[path] = t
	return t


static func size_of(path: String) -> Vector2:
	return get_tex(path).get_size()


## Soft round particle / shadow blob.
static func dot() -> Texture2D:
	if _dot:
		return _dot
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var d := Vector2(x + 0.5 - n * 0.5, y + 0.5 - n * 0.5).length() / (n * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, a * a))
	img.generate_mipmaps()
	_dot = ImageTexture.create_from_image(img)
	return _dot
