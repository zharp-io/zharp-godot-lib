## Every engine and script error, warning and printed line, through Godot 4.5's Logger.
##
## Godot calls these from whichever thread printed, so they only queue what they're given (under
## a mutex) for the Zharp autoload to handle on the main thread. They never print: a line printed
## here would come straight back.
extends Logger

const MAX_QUEUED := 1000

var capture_messages := false
var _mutex := Mutex.new()
var _queue: Array = []
var _dropped := 0


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	var frames: Array = []
	for backtrace in script_backtraces:
		if backtrace == null or backtrace.is_empty():
			continue
		var language := backtrace.get_language_name()
		for i in backtrace.get_frame_count():
			frames.append({
				"function": backtrace.get_frame_function(i),
				"file": backtrace.get_frame_file(i),
				"line": backtrace.get_frame_line(i),
				"language": language,
			})
	_push({
		"kind": "error",
		"function": function,
		"file": file,
		"line": line,
		"code": code,
		"rationale": rationale,
		"error_type": error_type,
		"frames": frames,
		"time": Time.get_unix_time_from_system(),
		"main_thread": OS.get_thread_caller_id() == OS.get_main_thread_id(),
	})


func _log_message(message: String, error: bool) -> void:
	if not capture_messages or message.begins_with("[Zharp]"):
		return
	_push({"kind": "message", "message": message, "error": error, "time": Time.get_unix_time_from_system()})


func _push(event: Dictionary) -> void:
	_mutex.lock()
	if _queue.size() >= MAX_QUEUED:
		_queue.pop_front()
		_dropped += 1
	_queue.append(event)
	_mutex.unlock()


## What was queued since the last call, oldest first.
func take() -> Array:
	_mutex.lock()
	var events := _queue
	_queue = []
	_mutex.unlock()
	return events
