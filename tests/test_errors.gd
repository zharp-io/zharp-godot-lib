extends RefCounted

const Errors := preload("res://addons/zharp/internal/errors.gd")
var t


## Logger events exactly as Godot 4.5.1 passed them (see the probe in tests/README).
func test_script_error() -> void:
	var d := Errors.new().describe({
		"function": "helper_null", "file": "res://main.gd", "line": 24,
		"code": "Invalid call. Nonexistent function 'foo' in base 'Nil'.", "rationale": "", "error_type": 2,
		"frames": [{"function": "helper_null", "file": "res://main.gd", "line": 24}, {"function": "_ready", "file": "res://main.gd", "line": 10}],
	})
	t.eq(d.type, "ScriptError")
	t.eq(d.message, "Invalid call. Nonexistent function 'foo' in base 'Nil'.")
	t.eq(d.stacktrace, "ScriptError: Invalid call. Nonexistent function 'foo' in base 'Nil'.\n[0] helper_null (res://main.gd:24)\n[1] _ready (res://main.gd:10)")


func test_push_error() -> void:
	var d := Errors.new().describe({
		"function": "push_error", "file": "core/variant/variant_utility.cpp", "line": 1024,
		"code": "a pushed error", "rationale": "", "error_type": 0,
		"frames": [{"function": "_ready", "file": "res://main.gd", "line": 9}],
	})
	t.eq(d.type, "Error")
	t.eq(d.stacktrace, "Error: a pushed error\n[0] _ready (res://main.gd:9)")


func test_engine_error_keeps_the_engine_location_first() -> void:
	var d := Errors.new().describe({
		"function": "get_node", "file": "scene/main/node.cpp", "line": 1907,
		"code": "Method/function failed. Returning: nullptr", "rationale": "Node not found: \"Nope\" (relative to \"/root/Main\").", "error_type": 0,
		"frames": [{"function": "_ready", "file": "res://main.gd", "line": 11}],
	})
	t.eq(d.type, "EngineError")
	t.eq(d.message, "Node not found: \"Nope\" (relative to \"/root/Main\").")
	t.eq(d.stacktrace, "EngineError: Node not found: \"Nope\" (relative to \"/root/Main\").\n[0] get_node (scene/main/node.cpp:1907)\n[1] _ready (res://main.gd:11)")


func test_csharp_exception_text() -> void:
	var d := Errors.new().describe({
		"function": "void Godot.NativeInterop.ExceptionUtils.LogException(System.Exception)", "file": "/root/godot/modules/mono/glue/GodotSharp/GodotSharp/Core/NativeInterop/ExceptionUtils.cs", "line": 113,
		"code": "System.InvalidOperationException: Cart is empty\n   at Shop.Cart.Checkout() in /game/Cart.cs:line 12\n   at Shop.Main._Ready() in /game/Main.cs:line 8\n   at Godot.Node.InvokeGodotClassMethod(godot_string_name& method, NativeVariantPtrArgs args, godot_variant& ret)",
		"rationale": "", "error_type": 0, "frames": [],
	})
	t.eq(d.type, "System.InvalidOperationException")
	t.eq(d.message, "Cart is empty")
	t.eq(d.stacktrace, "System.InvalidOperationException: Cart is empty\n   at Shop.Cart.Checkout() in /game/Cart.cs:line 12\n   at Shop.Main._Ready() in /game/Main.cs:line 8\n   at Godot.Node.InvokeGodotClassMethod(godot_string_name& method, NativeVariantPtrArgs args, godot_variant& ret)")


func test_repeats_within_a_minute_are_skipped() -> void:
	var e := Errors.new()
	var d := e.describe_handled("boom", "Error", [{"function": "f", "file": "res://a.gd", "line": 1}])
	t.eq(e.is_repeat(d, 1000.0), false)
	t.eq(e.is_repeat(d, 1030.0), true)
	t.eq(e.is_repeat(d, 1061.0), false)
	var other := e.describe_handled("boom", "Error", [{"function": "g", "file": "res://a.gd", "line": 2}])
	t.eq(e.is_repeat(other, 1062.0), false)


func test_app_frames() -> void:
	t.ok(Errors.is_app_frame({"file": "res://player/player.gd"}))
	t.ok(not Errors.is_app_frame({"file": "res://addons/dialogue/x.gd"}))
	t.ok(not Errors.is_app_frame({"file": "scene/main/node.cpp"}))


func test_source_context_reads_the_script() -> void:
	var text := Errors.new().source_context([
		{"function": "x", "file": "res://addons/zharp/internal/otlp.gd", "line": 3},
		{"function": "eq", "file": "res://tests/run.gd", "line": 3},
	])
	var sent = JSON.parse_string(text)
	t.eq(sent.size(), 1, "addon frames have no code sent")
	t.eq(sent[0].file, "res://tests/run.gd")
	t.eq(sent[0].code, "extends SceneTree")
	t.eq(sent[0].pre.size(), 2)
	t.eq(sent[0].post.size(), 5)
