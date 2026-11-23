## `session.id` and `device.id`, as the mobile SDKs keep them.
##
## A session ends after 30 minutes in the background (mobile), on `clear_user()`, and when the
## game starts again more than 30 minutes after it was last seen; a game restarted sooner keeps
## it. Both IDs are 32 random hex characters kept in `user://zharp/`.
extends RefCounted

const TIMEOUT_SECONDS := 30 * 60
const SAVE_EVERY_SECONDS := 60

var id := ""
var device_id := ""
var _dir := ""
var _background_since := -1.0
var _saved_at := 0.0
var _clock: Callable
## Called with the new ID when a session starts (not the first).
var on_new_session: Callable


func _init(dir: String, clock := Callable()) -> void:
	_dir = dir
	_clock = clock if clock.is_valid() else Callable(Time, "get_unix_time_from_system")
	device_id = _read_or_create(dir.path_join("device-id"))
	id = _load()
	if id == "":
		id = _random_id()
	save()


func now() -> float:
	return float(_clock.call())


## The ID for a record made now: a new one if the game was in the background too long.
func current() -> String:
	if _background_since >= 0.0 and now() - _background_since >= TIMEOUT_SECONDS:
		_rotate()
		_background_since = now()
	elif now() - _saved_at >= SAVE_EVERY_SECONDS:
		save()
	return id


func background() -> void:
	if _background_since < 0.0:
		_background_since = now()
	save()


func foreground() -> void:
	current()
	_background_since = -1.0
	save()


func reset() -> void:
	_rotate()


func _rotate() -> void:
	id = _random_id()
	save()
	if on_new_session.is_valid():
		on_new_session.call(id)


## Remember the time, so a game started again soon after keeps the session.
func save() -> void:
	_saved_at = now()
	if _dir == "":
		return
	DirAccess.make_dir_recursive_absolute(_dir)
	var file := FileAccess.open(_dir.path_join("session"), FileAccess.WRITE)
	if file != null:
		file.store_string(id + "\n" + str(int(_saved_at * 1000.0)))


func _load() -> String:
	if _dir == "":
		return ""
	var text := FileAccess.get_file_as_string(_dir.path_join("session"))
	var parts := text.split("\n")
	if parts.size() < 2 or parts[0].strip_edges().length() != 32 or not parts[1].strip_edges().is_valid_int():
		return ""
	var last_seen := float(parts[1].strip_edges().to_int()) / 1000.0
	return parts[0].strip_edges() if now() - last_seen < TIMEOUT_SECONDS else ""


static func _read_or_create(path: String) -> String:
	var saved := FileAccess.get_file_as_string(path).strip_edges() if FileAccess.file_exists(path) else ""
	if saved.length() == 32:
		return saved
	var made := _random_id()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(made)
	return made


static func _random_id() -> String:
	return Crypto.new().generate_random_bytes(16).hex_encode()
