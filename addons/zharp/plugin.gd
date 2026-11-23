## Enabling the plugin adds the `Zharp` autoload, Zharp's settings under Project Settings > Zharp,
## and turns on two engine settings Zharp needs in exported games:
## - `debug/settings/gdscript/always_track_call_stacks`: without it, release exports record no
##   script backtraces (it costs a little speed);
## - `debug/file_logging/enable_file_logging`: crashes are read from the previous run's log, which
##   Godot writes by default on desktop only.
## Turn `zharp/release_backtraces` off to leave both alone.
@tool
extends EditorPlugin

const AUTOLOAD := "Zharp"
const SETTINGS := [
	["zharp/key", TYPE_STRING, "", PROPERTY_HINT_NONE, ""],
	["zharp/endpoint", TYPE_STRING, "", PROPERTY_HINT_PLACEHOLDER_TEXT, "https://api.zharp.io/api/v1/otlp"],
	["zharp/environment", TYPE_STRING, "", PROPERTY_HINT_PLACEHOLDER_TEXT, "production"],
	["zharp/release", TYPE_STRING, "", PROPERTY_HINT_PLACEHOLDER_TEXT, "application/config/version"],
	["zharp/service", TYPE_STRING, "", PROPERTY_HINT_PLACEHOLDER_TEXT, "application/config/name"],
	["zharp/enabled", TYPE_BOOL, true, PROPERTY_HINT_NONE, ""],
	["zharp/auto_start", TYPE_BOOL, true, PROPERTY_HINT_NONE, ""],
	["zharp/logs", TYPE_BOOL, false, PROPERTY_HINT_NONE, ""],
	["zharp/tracing", TYPE_BOOL, true, PROPERTY_HINT_NONE, ""],
	["zharp/traces_sample_rate", TYPE_FLOAT, 1.0, PROPERTY_HINT_RANGE, "0,1,0.01"],
	["zharp/detect_hangs", TYPE_BOOL, true, PROPERTY_HINT_NONE, ""],
	["zharp/hang_threshold", TYPE_FLOAT, 5.0, PROPERTY_HINT_RANGE, "1,60,0.5,suffix:s"],
	["zharp/source_context", TYPE_BOOL, true, PROPERTY_HINT_NONE, ""],
	["zharp/release_backtraces", TYPE_BOOL, true, PROPERTY_HINT_NONE, ""],
	["zharp/debug", TYPE_BOOL, false, PROPERTY_HINT_NONE, ""],
]

var _export: EditorExportPlugin


func _enable_plugin() -> void:
	add_autoload_singleton(AUTOLOAD, "res://addons/zharp/zharp.gd")
	_add_settings()
	_engine_settings()
	ProjectSettings.save()


func _disable_plugin() -> void:
	remove_autoload_singleton(AUTOLOAD)


func _enter_tree() -> void:
	_add_settings()
	_engine_settings()
	_export = preload("export_plugin.gd").new()
	add_export_plugin(_export)


func _exit_tree() -> void:
	if _export != null:
		remove_export_plugin(_export)
		_export = null


static func _add_settings() -> void:
	for s in SETTINGS:
		var name: String = s[0]
		if not ProjectSettings.has_setting(name):
			ProjectSettings.set_setting(name, s[2])
		ProjectSettings.set_initial_value(name, s[2])
		ProjectSettings.set_as_basic(name, name in ["zharp/key", "zharp/environment", "zharp/logs"])
		ProjectSettings.add_property_info({"name": name, "type": s[1], "hint": s[3], "hint_string": s[4]})


static func _engine_settings() -> void:
	if not ProjectSettings.get_setting("zharp/release_backtraces", true):
		return
	if not ProjectSettings.get_setting("debug/settings/gdscript/always_track_call_stacks", false):
		ProjectSettings.set_setting("debug/settings/gdscript/always_track_call_stacks", true)
	if not ProjectSettings.get_setting("debug/file_logging/enable_file_logging", false):
		ProjectSettings.set_setting("debug/file_logging/enable_file_logging", true)
