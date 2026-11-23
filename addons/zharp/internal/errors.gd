## Errors as Zharp files them: `exception.type`, `exception.message` and `exception.stacktrace`,
## whose frames read `[0] take_damage (res://player/player.gd:42)`, innermost first.
extends RefCounted

## Godot's Logger error types.
const ERROR_TYPE_ERROR := 0
const ERROR_TYPE_WARNING := 1
const ERROR_TYPE_SCRIPT := 2
const ERROR_TYPE_SHADER := 3

## The same error from the same place is sent at most once in this many seconds: an error in
## `_process` happens every frame.
const REPEAT_SECONDS := 60.0
const MAX_REMEMBERED := 200

const SOURCE_FRAMES := 5
const SOURCE_AROUND := 5
const SOURCE_MAX_LINE := 300
const SOURCE_MAX_BYTES := 12000
## Where the export plugin puts the scripts' text when an export compiles them to tokens.
const SOURCES_DIR := "res://.zharp/sources/"

var _recent := {}
var _sources := {}

## `System.InvalidOperationException: Cart is empty` at the start of a C# error's text.
var _dotnet_head := RegEx.create_from_string("^([A-Za-z_][\\w.`+]*(?:Exception|Error))(?::\\s*(.*))?$")
var _dotnet_frame := RegEx.create_from_string("^\\s*at\\s+\\S")


## A Logger error event as {type, message, stacktrace, frames}. Frames are {function, file, line}.
func describe(event: Dictionary) -> Dictionary:
	var error_type: int = event.get("error_type", ERROR_TYPE_ERROR)
	var file: String = event.get("file", "")
	var function: String = event.get("function", "")
	var code: String = event.get("code", "")
	var rationale: String = event.get("rationale", "")
	var text := rationale if rationale.strip_edges() != "" else code
	var frames: Array = []
	for f in event.get("frames", []):
		frames.append({"function": f.get("function", ""), "file": f.get("file", ""), "line": int(f.get("line", 0))})

	var type := "Error"
	var message := text.strip_edges()
	var extra_lines := PackedStringArray()
	# C#: the exception's own text, with its .NET frames, is the message.
	var dotnet := _parse_dotnet(text)
	if not dotnet.is_empty():
		type = dotnet.type
		message = dotnet.message
		extra_lines = dotnet.frames
	elif error_type == ERROR_TYPE_SCRIPT:
		type = "ScriptError"
	elif error_type == ERROR_TYPE_SHADER:
		type = "ShaderError"
	elif function == "push_error":
		type = "Error"
	elif not file.begins_with("res://"):
		type = "EngineError"

	# Where the engine noticed it (C++), before the script frames that led there; not for
	# push_error, whose C++ location is always the same line.
	var located := file != "" and function != "push_error" and dotnet.is_empty()
	if located and not (frames.size() > 0 and frames[0].file == file and frames[0].line == line_of(event)):
		frames.push_front({"function": function, "file": file, "line": line_of(event)})
	return {"type": type, "message": message, "frames": frames, "stacktrace": stacktrace(type, message, frames, extra_lines)}


static func line_of(event: Dictionary) -> int:
	return int(event.get("line", 0))


## A handled error the game reported itself, with the script frames where it was called.
func describe_handled(message: String, type: String, frames: Array) -> Dictionary:
	return {"type": type, "message": message, "frames": frames, "stacktrace": stacktrace(type, message, frames)}


static func stacktrace(type: String, message: String, frames: Array, extra_lines := PackedStringArray()) -> String:
	var lines := PackedStringArray()
	var first_line := message.split("\n")[0] if message != "" else ""
	lines.append(type + (": " + first_line if first_line != "" else ""))
	for i in frames.size():
		lines.append(format_frame(i, frames[i]))
	for extra in extra_lines:
		lines.append(extra)
	return "\n".join(lines)


static func format_frame(index: int, frame: Dictionary) -> String:
	var where: String = frame.get("file", "")
	var line: int = int(frame.get("line", 0))
	if where != "" and line > 0:
		where += ":" + str(line)
	var function: String = frame.get("function", "")
	return "[%d] %s (%s)" % [index, function if function != "" else "<unknown>", where if where != "" else "<unknown>"]


## Script frames where this is called from, without the addon's own.
static func current_frames() -> Array:
	var frames: Array = []
	for backtrace in Engine.capture_script_backtraces():
		for i in backtrace.get_frame_count():
			var file := backtrace.get_frame_file(i)
			if file.begins_with("res://addons/zharp/"):
				continue
			frames.append({"function": backtrace.get_frame_function(i), "file": file, "line": backtrace.get_frame_line(i)})
	return frames


func _parse_dotnet(text: String) -> Dictionary:
	var lines := text.strip_edges().split("\n")
	if lines.is_empty():
		return {}
	var head := _dotnet_head.search(lines[0].strip_edges())
	if head == null:
		return {}
	var frames := PackedStringArray()
	var message_lines := PackedStringArray([head.get_string(2)])
	for i in range(1, lines.size()):
		var line := lines[i].rstrip("\r")
		if _dotnet_frame.search(line) != null or line.strip_edges().begins_with("---"):
			if _dotnet_frame.search(line) != null:
				frames.append("   " + line.strip_edges())
		elif frames.is_empty():
			message_lines.append(line)
	return {"type": head.get_string(1), "message": "\n".join(message_lines).strip_edges(), "frames": frames}


## Whether this error (type, message, first frame) was sent less than REPEAT_SECONDS ago.
func is_repeat(description: Dictionary, now: float) -> bool:
	var frames: Array = description.frames
	var key: String = description.type + "\n" + str(description.message).split("\n")[0] + "\n" + (format_frame(0, frames[0]) if frames.size() > 0 else "")
	var last = _recent.get(key)
	if last != null and now - float(last) < REPEAT_SECONDS:
		return true
	if _recent.size() >= MAX_REMEMBERED:
		for k in _recent.keys():
			if now - float(_recent[k]) >= REPEAT_SECONDS:
				_recent.erase(k)
		if _recent.size() >= MAX_REMEMBERED:
			return false
	_recent[key] = now
	return false


## Whether a frame is the game's own script, not an addon's or the engine's.
static func is_app_frame(frame: Dictionary) -> bool:
	var file: String = frame.get("file", "")
	return file.begins_with("res://") and not file.begins_with("res://addons/")


## `zharp.source_context`: the code around the game's top frames, read from the scripts in the
## export, as [{file, line, pre, code, post}].
func source_context(frames: Array) -> String:
	var out: Array = []
	var seen := {}
	for frame in frames:
		if out.size() >= SOURCE_FRAMES:
			break
		if not is_app_frame(frame):
			continue
		var file: String = frame.file
		var line: int = int(frame.line)
		if line < 1 or seen.has(file + ":" + str(line)):
			continue
		seen[file + ":" + str(line)] = true
		var lines := _lines_of(file)
		if lines.is_empty() or line > lines.size():
			continue
		var pre: Array = []
		for n in range(max(1, line - SOURCE_AROUND), line):
			pre.append(_cut(lines[n - 1]))
		var post: Array = []
		for n in range(line + 1, min(lines.size(), line + SOURCE_AROUND) + 1):
			post.append(_cut(lines[n - 1]))
		out.append({"file": file, "line": line, "pre": pre, "code": _cut(lines[line - 1]), "post": post})
	while out.size() > 0:
		var text := JSON.stringify(out)
		if text.to_utf8_buffer().size() <= SOURCE_MAX_BYTES:
			return text
		out.pop_back()
	return ""


func _lines_of(file: String) -> PackedStringArray:
	if _sources.has(file):
		return _sources[file]
	var text := ""
	# A text export keeps the script itself; a token export has the copy the export plugin added.
	var copy := SOURCES_DIR + file.trim_prefix("res://") + ".txt"
	if FileAccess.file_exists(copy):
		text = FileAccess.get_file_as_string(copy)
	elif file.ends_with(".gd") and FileAccess.file_exists(file):
		text = FileAccess.get_file_as_string(file)
	var lines := text.replace("\r\n", "\n").split("\n") if text != "" else PackedStringArray()
	if _sources.size() < 50:
		_sources[file] = lines
	return lines


static func _cut(text: String) -> String:
	return text if text.length() <= SOURCE_MAX_LINE else text.substr(0, SOURCE_MAX_LINE - 1) + "…"
