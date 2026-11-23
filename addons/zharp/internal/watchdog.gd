## Hangs, the way Android's watchdog sees them: the main thread not getting through a frame for
## `threshold` seconds is reported once per freeze. Runs on its own thread, so it can see the
## freeze while it lasts; the report goes straight to the outbox, so a player who gives up and
## kills the game still has it sent on the next launch. Off on web builds without threads, while
## the game is in the background (mobile), and under the debugger (breakpoints freeze it too).
extends RefCounted

var threshold_msec := 5000
var paused := false
## Called on the watchdog's thread with the blocked time in seconds.
var on_hang: Callable

var _thread: Thread
var _last_beat := 0
var _running := false
var _reported := false
var _mutex := Mutex.new()


static func supported() -> bool:
	return not (OS.has_feature("web") and not OS.has_feature("threads"))


func start() -> void:
	if _running or not supported():
		return
	_running = true
	beat()
	_thread = Thread.new()
	_thread.start(_run, Thread.PRIORITY_LOW)


## The main thread got through a frame.
func beat() -> void:
	_mutex.lock()
	_last_beat = Time.get_ticks_msec()
	_reported = false
	_mutex.unlock()


func stop() -> void:
	if not _running:
		return
	_running = false
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()


func _run() -> void:
	while _running:
		OS.delay_msec(200)
		_mutex.lock()
		var blocked := Time.get_ticks_msec() - _last_beat
		var report := not _reported and not paused and blocked >= threshold_msec
		if report:
			_reported = true
		_mutex.unlock()
		if report and not EngineDebugger.is_active() and on_hang.is_valid():
			on_hang.call(blocked / 1000.0)
