## The code that ran, in exported games. Godot 4.3+ exports scripts as compiled tokens by default,
## which can't be read back as text; so each script's text is added to the export under
## `res://.zharp/sources/`, where the Zharp autoload reads the lines around an error. Exports that
## keep scripts as text don't need it. `zharp/source_context` off leaves the export alone.
@tool
extends EditorExportPlugin

const DIR := "res://.zharp/sources/"


func _get_name() -> String:
	return "Zharp"


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if not ProjectSettings.get_setting("zharp/source_context", true):
		return
	if not path.ends_with(".gd") or path.begins_with("res://addons/"):
		return
	if get_export_preset() != null and get_export_preset().get_script_export_mode() == EditorExportPreset.MODE_SCRIPT_TEXT:
		return
	var text := FileAccess.get_file_as_bytes(path)
	if not text.is_empty():
		add_file(DIR + path.trim_prefix("res://") + ".txt", text, false)
