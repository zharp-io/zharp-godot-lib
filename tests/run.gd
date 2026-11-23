## Unit tests: godot --headless --path tests_project -s res://tests/run.gd
## Each tests/test_*.gd has test_* methods; a failed check prints and the run exits 1.
extends SceneTree

var failures := 0
var checks := 0
var current := ""


func _initialize() -> void:
	var files := DirAccess.get_files_at("res://tests")
	files.sort()
	for file in files:
		if not (file.begins_with("test_") and file.ends_with(".gd")):
			continue
		var suite = load("res://tests/" + file).new()
		suite.t = self
		for method in suite.get_method_list():
			if str(method.name).begins_with("test_"):
				current = file + " " + method.name
				suite.call(method.name)
	print("%d checks, %d failed" % [checks, failures])
	quit(1 if failures > 0 else 0)


func eq(actual, expected, what := "") -> void:
	checks += 1
	if typeof(actual) != typeof(expected) or actual != expected:
		failures += 1
		print("FAIL %s %s\n  expected: %s\n  actual:   %s" % [current, what, var_to_str(expected), var_to_str(actual)])


func ok(condition: bool, what := "") -> void:
	eq(condition, true, what)
