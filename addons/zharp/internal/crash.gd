## Engine crashes, found on the next launch.
##
## Godot's crash handler writes "Program crashed with signal 11" (Linux, macOS, Android) or
## "Program crashed" (Windows), the native backtrace and, since 4.5, the script backtrace to the
## log file, then the process dies; nothing more can run. On the next launch the previous run's
## log (rotated to `user://logs/godot<date>.log`) is read, and the crash is sent with that run's
## session, scene and user. Address-only frames are readable only with export templates built
## with debug symbols.
extends RefCounted

const Errors := preload("errors.gd")

const SIGNALS := {1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
	7: "SIGBUS", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGUSR1", 11: "SIGSEGV", 13: "SIGPIPE", 15: "SIGTERM"}

## How much of the end of a log is read: the crash is the last thing in it.
const TAIL_BYTES := 256 * 1024


## The newest log in `log_path`'s folder other than the current one: the previous run's.
static func previous_log(log_path: String) -> String:
	var dir := log_path.get_base_dir()
	var current := log_path.get_file()
	var base := current.get_basename()
	var ext := current.get_extension()
	var newest := ""
	for name in DirAccess.get_files_at(dir):
		if name == current or not name.begins_with(base) or name.get_extension() != ext:
			continue
		if newest == "" or name > newest:
			newest = name
	return dir.path_join(newest) if newest != "" else ""


static func read_tail(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var length := file.get_length()
	if length > TAIL_BYTES:
		file.seek(length - TAIL_BYTES)
	return file.get_buffer(mini(length, TAIL_BYTES)).get_string_from_utf8()


## The crash in a log's text as {type, message, stacktrace, frames, engine}, or {} when it has none.
##
##     ERROR: boom
##        at: crash (core/core_bind.cpp:336)
##        GDScript backtrace (most recent call first):
##            [0] explode (res://main.gd:26)
##     ================================================================
##     handle_crash: Program crashed with signal 4
##     Engine version: Godot Engine v4.5.1.stable.official (f62fdbde...)
##     Dumping the backtrace. Please include this when reporting the bug on: ...
##     [1] /lib/x86_64-linux-gnu/libc.so.6(+0x3c050) [0x7f98e9289050] (??:0)
##     [2] godot() [0x41e2dda] (??:0)
##     -- END OF C++ BACKTRACE --
##     ================================================================
##     GDScript backtrace (most recent call first):
##         [0] explode (res://main.gd:26)
##     -- END OF GDSCRIPT BACKTRACE --
static func parse(text: String) -> Dictionary:
	var at := text.rfind("Program crashed")
	if at < 0:
		return {}
	# Up to the start of the crash line ("handle_crash: Program crashed…").
	var line_start := maxi(0, text.rfind("\n", at))
	var from := maxi(0, line_start - 8192)
	var before := text.substr(from, line_start - from).replace("\r\n", "\n").split("\n")
	var lines := text.substr(at).replace("\r\n", "\n").split("\n")
	var head := lines[0].strip_edges()
	var signal_number := -1
	var m := RegEx.create_from_string("signal (\\d+)").search(head)
	if m != null:
		signal_number = m.get_string(1).to_int()
	var native := PackedStringArray()
	var script_frames: Array = []
	var engine := ""
	var in_script := false
	var native_frame := RegEx.create_from_string("^\\[(\\d+)\\]\\s+(.*)$")
	for i in range(1, lines.size()):
		var line := lines[i].strip_edges()
		if line.begins_with("Engine version:"):
			engine = line.trim_prefix("Engine version:").strip_edges()
		elif line.contains("backtrace (most recent call first)"):
			in_script = true
		elif line.contains("END OF") and line.contains("BACKTRACE"):
			in_script = false
		elif line.begins_with("["):
			if in_script:
				var frame := script_frame_of(line)
				if not frame.is_empty():
					script_frames.append(frame)
			else:
				var n := native_frame.search(line)
				if n != null:
					native.append(n.get_string(2))
	# What the engine said last before it crashed (OS.crash's message, a failed check), and its
	# script backtrace: the handler's own is missing when the handler fails too (no addr2line).
	var reason := ""
	var reason_frames: Array = []
	for i in range(before.size() - 1, -1, -1):
		var line := before[i].strip_edges()
		if line.begins_with("ERROR:") or line.begins_with("FATAL:") or line.begins_with("SCRIPT ERROR:"):
			reason = line.trim_prefix("SCRIPT ERROR:").trim_prefix("ERROR:").strip_edges().trim_prefix("FATAL:").strip_edges()
			for j in range(i + 1, before.size()):
				var frame := script_frame_of(before[j].strip_edges())
				if not frame.is_empty():
					reason_frames.append(frame)
			break
		if line.begins_with("=====") or line == "" or line.begins_with("at:") or line.begins_with("[") or line.contains("backtrace (most recent"):
			continue
		break
	if script_frames.is_empty():
		script_frames = reason_frames
	var type: String = (SIGNALS.get(signal_number, "Signal%d" % signal_number)) if signal_number >= 0 else "EngineCrash"
	var message := head.substr(head.find("Program crashed"))
	if reason != "":
		message = reason + " (" + message + ")"
	# Script frames first: they're what the game was doing, and how the crash is grouped. The
	# engine's frames follow as Godot wrote them, numbered on.
	var stack := PackedStringArray([type + ": " + message])
	for i in script_frames.size():
		stack.append(Errors.format_frame(i, script_frames[i]))
	for i in native.size():
		stack.append("[%d] %s" % [script_frames.size() + i, native[i]])
	return {"type": type, "message": message, "stacktrace": "\n".join(stack), "frames": script_frames, "engine": engine, "mechanism": "signal"}


## A run that ended without shutting down and without the crash handler's report (release
## export templates have none): the last error the log shows just before the end, if any, says
## what happened, with its script backtrace.
static func unclean_exit(text: String) -> Dictionary:
	var lines := text.replace("\r\n", "\n").strip_edges().split("\n")
	var reason := ""
	var frames: Array = []
	# Only an error among the last lines: one long before the end says nothing about it.
	var first := maxi(0, lines.size() - 25)
	for i in range(lines.size() - 1, first - 1, -1):
		var line := lines[i].strip_edges()
		if line.begins_with("ERROR:") or line.begins_with("SCRIPT ERROR:"):
			reason = line.trim_prefix("SCRIPT ERROR:").trim_prefix("ERROR:").strip_edges().trim_prefix("FATAL:").strip_edges()
			for j in range(i + 1, lines.size()):
				var frame := script_frame_of(lines[j].strip_edges())
				if not frame.is_empty():
					frames.append(frame)
			break
	var message := "The game ended without shutting down"
	if reason != "":
		message += " after: " + reason
	var stack := PackedStringArray(["UncleanExit: " + message])
	for i in frames.size():
		stack.append(Errors.format_frame(i, frames[i]))
	return {"type": "UncleanExit", "message": message, "stacktrace": "\n".join(stack), "frames": frames, "engine": "", "mechanism": "unclean_exit"}


## `[0] explode (res://main.gd:26)` as {function, file, line}, or {}.
static func script_frame_of(line: String) -> Dictionary:
	var s := RegEx.create_from_string("^\\[(\\d+)\\]\\s+(.*?)\\s+\\((.*?)(?::(\\d+))?\\)$").search(line)
	if s == null:
		return {}
	return {"function": s.get_string(2), "file": s.get_string(3), "line": s.get_string(4).to_int()}
