class_name PhotoPicker
extends RefCounted
## "Use my photo": the system's own file / gallery picker (a browser file
## chooser on the web). The picked picture goes to the crop window
## (CropDialog); save() keeps the result on the device as the "custom" portrait.

static var _js_callback: Variant  # the web callback must stay alive
static var _on_done: Callable


## Opens the picker; `on_done(image)` gets the picked picture, or null.
static func pick(owner: Node, on_done: Callable) -> void:
	_on_done = on_done
	if OS.has_feature("web"):
		_pick_web()
	elif DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		DisplayServer.file_dialog_show("Choose a photo", "", "", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
				PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Pictures"]),
				func(ok: bool, paths: PackedStringArray, _filter: int):
					if ok and paths.size() > 0:
						_use_image(Image.load_from_file(paths[0]))
					else:
						_finish(null))
	else:
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.filters = PackedStringArray(["*.png, *.jpg, *.jpeg, *.webp ; Pictures"])
		fd.use_native_dialog = true
		owner.add_child(fd)
		fd.file_selected.connect(func(p: String):
			_use_image(Image.load_from_file(p))
			fd.queue_free())
		fd.canceled.connect(func():
			_finish(null)
			fd.queue_free())
		fd.popup_centered_ratio(0.8)


static func _pick_web() -> void:
	var window: JavaScriptObject = JavaScriptBridge.get_interface("window")
	_js_callback = JavaScriptBridge.create_callback(func(args: Array):
		var url := String(args[0]) if args.size() > 0 else ""
		var comma := url.find(",")
		if comma < 0:
			_finish(null)
			return
		var bytes := Marshalls.base64_to_raw(url.substr(comma + 1))
		var img := Image.new()
		var err := img.load_png_from_buffer(bytes)
		if err != OK:
			err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			err = img.load_webp_from_buffer(bytes)
		_use_image(img if err == OK else null))
	window.veyPhoto = _js_callback
	JavaScriptBridge.eval("""
		(function () {
			var i = document.createElement('input');
			i.type = 'file';
			i.accept = 'image/*';
			i.onchange = function () {
				var f = i.files[0];
				if (!f) { return; }
				var r = new FileReader();
				r.onload = function () { window.veyPhoto(r.result); };
				r.readAsDataURL(f);
			};
			i.click();
		})();
	""", true)


static func _use_image(img: Image) -> void:
	if img == null or img.is_empty():
		_finish(null)
		return
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	# a phone photo can be huge; 2048 px is plenty to crop a portrait from
	var big := maxi(img.get_width(), img.get_height())
	if big > 2048:
		var k := 2048.0 / big
		img.resize(int(img.get_width() * k), int(img.get_height() * k), Image.INTERPOLATE_LANCZOS)
	_finish(img)


## Keep the cropped square as the player's portrait.
static func save(img: Image) -> void:
	img.save_png(Tex.CUSTOM_FILE)
	Tex.forget(Tex.CUSTOM)


static func _finish(img: Image) -> void:
	if _on_done.is_valid():
		_on_done.call(img)
