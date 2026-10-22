extends Node
## Autoload "Perf": keeps phones cool. On a phone the game draws at most 60
## frames a second while something is happening (a touch, an animation) and
## 30 when the table is still; the 3D table renders at 75% resolution with
## light anti-aliasing. Desktop builds are left exactly as they are.
##
## Anything that animates without a touch (an opponent's move, the deal)
## calls `Perf.wake()` while it runs.

const ACTIVE_FPS := 60
const IDLE_FPS := 30
const IDLE_AFTER := 2.5  # seconds after the last touch or animation

var mobile := false
var _awake_until := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_realtime_on = OS.get_cmdline_user_args().has("--realtime")
	mobile = OS.has_feature("mobile") or OS.get_cmdline_user_args().has("--phone-perf")
	if not mobile:
		return
	var vp := get_viewport()
	vp.msaa_3d = Viewport.MSAA_2X
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 0.75
	wake()


## Draw at full rate for a while (something moves).
func wake(seconds := IDLE_AFTER) -> void:
	if not mobile:
		return
	_awake_until = maxf(_awake_until, Time.get_ticks_msec() / 1000.0 + seconds)
	Engine.max_fps = ACTIVE_FPS


func _input(e: InputEvent) -> void:
	if mobile and (e is InputEventScreenTouch or e is InputEventScreenDrag or e is InputEventMouseButton):
		wake()


## Test (recordings): `--realtime` holds every frame until real time has caught
## up with the recording (which otherwise draws faster than real time, so the
## other players, who run in real time, would seem to take far longer).
var _realtime_on := false
var _rt_start := -1
var _rt_frames := 0


func _realtime() -> void:
	if _rt_start < 0:
		_rt_start = Time.get_ticks_usec()
	_rt_frames += 1
	var due := _rt_start + int(_rt_frames * 1000000.0 / 30.0)
	var ahead := due - Time.get_ticks_usec()
	if ahead > 0:
		OS.delay_usec(ahead)


func _process(_delta: float) -> void:
	if _realtime_on:
		_realtime()
	if OS.get_cmdline_user_args().has("--perfdebug") and Engine.get_process_frames() % 60 == 0:
		print("PERF fps=%d max=%d" % [Engine.get_frames_per_second(), Engine.max_fps])
	if mobile and Engine.max_fps != IDLE_FPS and Time.get_ticks_msec() / 1000.0 > _awake_until:
		Engine.max_fps = IDLE_FPS
