## The code that ran, in exported games. Godot 4.3+ exports scripts as compiled tokens by default,
## which can't be read back as text; so each script's text is added to the export under
## `res://.zharp/sources/`, where the Zharp autoload reads the lines around an error. Exports that
## keep scripts as text don't need it. `zharp/source_context` off leaves the export alone.
##
## The copies are added when the export begins: `_export_file` is never called for scripts (the
## engine's own GDScript export takes them first).
@tool
extends EditorExportPlugin

const DIR := "res://.zharp/sources/"


func _get_name() -> String:
	return "Zharp"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	if not ProjectSettings.get_setting("zharp/source_context", true):
		return
	var preset := get_export_preset()
	if preset != null and preset.get_script_export_mode() == EditorExportPreset.MODE_SCRIPT_TEXT:
		return
	# A preset that exports selected files lists them; one that exports everything lists none.
	var files := preset.get_files_to_export() if preset != null else PackedStringArray()
	if files.is_empty():
		files = _scripts_in("res://")
	for path in files:
		if not path.ends_with(".gd") or path.begins_with("res://addons/"):
			continue
		var text := FileAccess.get_file_as_bytes(path)
		if not text.is_empty():
			add_file(DIR + path.trim_prefix("res://") + ".txt", text, false)


## Every script under `dir`.
static func _scripts_in(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for name in DirAccess.get_files_at(dir):
		if name.ends_with(".gd"):
			out.append(dir.path_join(name))
	for sub in DirAccess.get_directories_at(dir):
		if not sub.begins_with("."):
			out.append_array(_scripts_in(dir.path_join(sub)))
	return out
