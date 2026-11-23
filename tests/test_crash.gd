extends RefCounted

const Crash := preload("res://addons/zharp/internal/crash.gd")
var t


func test_linux_crash() -> void:
	var c := Crash.parse(FileAccess.get_file_as_string("res://tests/fixtures/crash_linux.log"))
	t.eq(c.type, "SIGILL")
	t.eq(c.message, "boom from script (Program crashed with signal 4)")
	t.eq(c.engine, "Godot Engine v4.5.1.stable.official (f62fdbde15035c5576dad93e586201f4d41ef0cb)")
	t.eq(c.frames.size(), 2)
	var lines: PackedStringArray = c.stacktrace.split("\n")
	t.eq(lines[0], "SIGILL: boom from script (Program crashed with signal 4)")
	t.eq(lines[1], "[0] deeper_crash (res://main.gd:26)")
	t.eq(lines[2], "[1] _ready (res://main.gd:20)")
	t.eq(lines[3], "[2] /lib/x86_64-linux-gnu/libc.so.6(+0x3c050) [0x7f98e9289050] (??:0)")
	t.eq(lines[4], "[3] godot() [0x41e2dda] (??:0)")
	t.eq(lines.size(), 1 + 2 + 17)


func test_crash_handler_that_failed() -> void:
	var c := Crash.parse(FileAccess.get_file_as_string("res://tests/fixtures/crash_linux_no_addr2line.log"))
	t.eq(c.type, "SIGILL")
	t.eq(c.message, "boom from script (Program crashed with signal 4)")
	t.eq(c.stacktrace, "SIGILL: boom from script (Program crashed with signal 4)\n[0] deeper_crash (res://main.gd:26)\n[1] _ready (res://main.gd:20)")


func test_windows_crash() -> void:
	var c := Crash.parse("ERROR: Index out of bounds\n   at: get (core/x.h:1)\n\n================================================================\nCrashHandlerException: Program crashed\nEngine version: Godot Engine v4.5.1.stable.official (f62f)\nDumping the backtrace. Please include this when reporting the bug to the project developer.\n[0] Node::_propagate_ready (C:\\godot\\scene\\main\\node.cpp:312)\n[1] <couldn't map PC to fn name>\n-- END OF C++ BACKTRACE --\n")
	t.eq(c.type, "EngineCrash")
	t.eq(c.message, "Index out of bounds (Program crashed)")
	t.eq(c.stacktrace, "EngineCrash: Index out of bounds (Program crashed)\n[0] Node::_propagate_ready (C:\\godot\\scene\\main\\node.cpp:312)\n[1] <couldn't map PC to fn name>")


func test_no_crash() -> void:
	t.eq(Crash.parse(FileAccess.get_file_as_string("res://tests/fixtures/clean_exit.log")), {})


## A Linux release export: the template has no crash handler, so the log just ends.
func test_release_export_unclean_exit() -> void:
	var text := FileAccess.get_file_as_string("res://tests/fixtures/release_no_crash_handler.log")
	t.eq(Crash.parse(text), {})
	var c := Crash.unclean_exit(text)
	t.eq(c.type, "UncleanExit")
	t.eq(c.mechanism, "unclean_exit")
	t.eq(c.stacktrace, "UncleanExit: The game ended without shutting down after: Inventory corrupted\n[0] explode (res://shop/checkout.gd:40)\n[1] _ready (res://shop/checkout.gd:29)")


func test_unclean_exit_without_an_error_says_so() -> void:
	var c := Crash.unclean_exit(FileAccess.get_file_as_string("res://tests/fixtures/clean_exit.log") + "\nline\n".repeat(30))
	t.eq(c.message, "The game ended without shutting down")
	t.eq(c.frames, [])
