## Zharp for Godot: the `Zharp` autoload the plugin adds.
##
## It starts on its own with the key in Project Settings (`zharp/key`) and reports:
## - every script and engine error, with its backtrace and the code around it;
## - engine crashes, on the next launch, from the crash backtrace in the previous run's log;
## - hangs (the main thread stuck for 5 s);
## - sessions, the device, the scene as the screen, the user you set;
## - with `zharp/logs` on (or `ZHARP_LOGS=true`), what the game prints.
##
## Nothing here ever throws into the game.
extends Node

const VERSION := "0.1.0"
const DEFAULT_ENDPOINT := "https://api.zharp.io/api/v1/otlp"
const STORAGE := "user://zharp"
const MAX_BREADCRUMBS := 30

const ZharpLogger := preload("internal/logger.gd")
const Errors := preload("internal/errors.gd")
const Session := preload("internal/session.gd")
const Transport := preload("internal/transport.gd")
const Crash := preload("internal/crash.gd")
const Watchdog := preload("internal/watchdog.gd")
const Headers := preload("internal/headers.gd")
const Otlp := preload("internal/otlp.gd")

## Emitted (on the main thread) when a new session starts, with its ID. The C# glue listens.
signal session_changed(id: String)
## Emitted when the screen (the current scene) changes.
signal screen_changed(name: String)

## Whether Zharp is running.
var enabled := false
## What it runs with: key, endpoint, service, release, environment, logs, tracing,
## traces_sample_rate, detect_hangs, hang_threshold, source_context, debug.
var config := {}
var session_id: String:
	get: return _session.current() if _session != null else ""
var device_id: String:
	get: return _session.device_id if _session != null else ""
var screen_name: String:
	get: return _screen

var _logger: ZharpLogger
var _errors: Errors
var _session: Session
var _transport: Transport
var _watchdog: Watchdog
var _resource := {}
var _user := {}
var _tags := {}
var _screen := ""
var _scene_id := 0
var _spans: Array = []
var _breadcrumbs: Array = []
var _breadcrumb_mutex := Mutex.new()
var _warned := {}
var _closed := false
var _background := false
var _started_at := 0


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# As early as possible, so errors in the main scene's _ready are seen.
	if _setting("zharp/auto_start", true):
		start()


## Start Zharp. Called for you with Project Settings unless `zharp/auto_start` is off; call it
## yourself then, with any setting to override: `Zharp.start({"key": key, "environment": "beta"})`.
func start(options := {}) -> bool:
	if enabled:
		return true
	_closed = false
	config = _resolve(options)
	if not config.enabled:
		_debug("disabled (zharp/enabled): nothing will be sent")
		return false
	if config.key == "":
		_warn("No key in Project Settings (zharp/key) or ZHARP_KEY: nothing will be sent. Copy it from the app's Setup page in Zharp.")
		return false
	_errors = Errors.new()
	_session = Session.new(STORAGE)
	_session.on_new_session = func(id: String) -> void:
		_write_marker()
		session_changed.emit(id)
	_resource = _resource_attributes()
	_transport = Transport.new()
	_transport.name = "ZharpTransport"
	_transport.key = config.key
	_transport.endpoint = config.endpoint
	_transport.resource = _resource
	_transport.debug = config.debug
	_transport.dir = STORAGE.path_join("outbox")
	_transport.warn = _warn
	add_child(_transport)
	_logger = ZharpLogger.new()
	_logger.capture_messages = config.logs
	OS.add_logger(_logger)
	enabled = true
	_started_at = int(Time.get_unix_time_from_system()) - 1
	_check_previous_run()
	_write_marker()
	if config.detect_hangs and Watchdog.supported():
		_watchdog = Watchdog.new()
		_watchdog.threshold_msec = int(config.hang_threshold * 1000.0)
		_watchdog.on_hang = _on_hang
	_debug("started: service \"%s\", sending to %s" % [_resource.get("service.name", ""), config.endpoint])
	return true


func _enter_tree() -> void:
	# A scene is the screen from the moment it's added, before its _ready runs.
	if not get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if enabled and node.get_parent() == get_tree().root and node != self and node.get_script() != get_script():
		var path := node.scene_file_path
		if path != "":
			_scene_id = node.get_instance_id()
			_screen_shown(path.get_file().get_basename())


func _process(_delta: float) -> void:
	if not enabled:
		return
	if _watchdog != null:
		# Watched from the first frame on: loading before it isn't a hang.
		_watchdog.start()
		_watchdog.beat()
	_check_scene()
	_drain()


func _notification(what: int) -> void:
	if not enabled:
		return
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			if _watchdog != null:
				_watchdog.paused = true
			_background = true
			_write_marker()
			_session.background()
			_drain()
			_transport.flush()
		NOTIFICATION_APPLICATION_RESUMED:
			_background = false
			_write_marker()
			_session.foreground()
			if _watchdog != null:
				_watchdog.paused = false
				_watchdog.beat()
		NOTIFICATION_WM_CLOSE_REQUEST:
			_drain()
			_transport.persist()


func _exit_tree() -> void:
	stop()


## Stop: what's waiting goes to the outbox, sent on the next launch if not before.
func stop() -> void:
	if not enabled or _closed:
		return
	_closed = true
	_drain()
	for span in _spans.duplicate():
		span.end()
	if _watchdog != null:
		_watchdog.stop()
	OS.remove_logger(_logger)
	_transport.persist()
	_session.save()
	# A clean exit: no crash to look for next time.
	DirAccess.remove_absolute(STORAGE.path_join("run.json"))
	enabled = false


# ─── Errors ──────────────────────────────────────────────────────────────────


## Report an error the game handled, with the script frames where this was called.
##     Zharp.capture_error("Save failed: disk full", {"slot": 2})
func capture_error(message: String, attributes := {}, type := "Error") -> void:
	if not enabled:
		return
	var description := _errors.describe_handled(message, type, Errors.current_frames())
	if _errors.is_repeat(description, Time.get_unix_time_from_system()):
		return
	_send_error(description, true, "manual", attributes, 0.0, _current_span())


## `span`: the span it happened in. Errors from the Logger are handled a frame later, when the
## current span may be another one, so they carry none.
func _send_error(description: Dictionary, handled: bool, mechanism: String, attributes := {}, time := 0.0, span: ZharpSpan = null) -> void:
	var record := attributes.duplicate()
	record.merge(_context(), true)
	record["exception.type"] = description.type
	record["exception.message"] = description.message
	record["exception.stacktrace"] = description.stacktrace
	record["zharp.handled"] = "true" if handled else "false"
	record["zharp.mechanism"] = mechanism
	if config.source_context:
		var code := _errors.source_context(description.frames)
		if code != "":
			record["zharp.source_context"] = code
	var crumbs := _breadcrumb_json()
	if crumbs != "":
		record["zharp.breadcrumbs"] = crumbs
	var body: String = description.type + (": " + str(description.message).split("\n")[0] if description.message != "" else "")
	_transport.add_log(Otlp.log_record("error", body, Otlp.clean(record), Otlp.nanos(time) if time > 0.0 else "",
		span.trace_id if span != null else "", span.span_id if span != null else ""))


func _drain() -> void:
	if _logger == null:
		return
	for event in _logger.take():
		if event.kind == "message":
			var text: String = event.message.strip_edges(false, true)
			if text != "":
				_transport.add_log(Otlp.log_record("error" if event.error else "info", text, Otlp.clean(_context()), Otlp.nanos(event.time)))
			continue
		if event.error_type == Errors.ERROR_TYPE_WARNING:
			var warning: String = event.rationale if event.rationale != "" else event.code
			_breadcrumb("warn", warning)
			if config.logs:
				_transport.add_log(Otlp.log_record("warn", warning, Otlp.clean(_context()), Otlp.nanos(event.time)))
			continue
		if _is_own(event):
			_debug("internal error: %s %s" % [event.code, event.rationale])
			continue
		var description := _errors.describe(event)
		if _errors.is_repeat(description, event.time):
			continue
		var extra := {"thread.name": "main" if event.main_thread else "worker"}
		_send_error(description, false, "logger", extra, event.time)


func _is_own(event: Dictionary) -> bool:
	if str(event.file).begins_with("res://addons/zharp/"):
		return true
	var frames: Array = event.frames
	return frames.size() > 0 and str(frames[0].file).begins_with("res://addons/zharp/")


func _breadcrumb(level: String, message: String) -> void:
	_breadcrumb_mutex.lock()
	_breadcrumbs.append({"time": Time.get_datetime_string_from_system(true) + "Z", "level": level, "message": message.substr(0, 300)})
	if _breadcrumbs.size() > MAX_BREADCRUMBS:
		_breadcrumbs.pop_front()
	_breadcrumb_mutex.unlock()


func _breadcrumb_json() -> String:
	_breadcrumb_mutex.lock()
	var text := JSON.stringify(_breadcrumbs) if not _breadcrumbs.is_empty() else ""
	_breadcrumb_mutex.unlock()
	return text


# ─── Crashes and hangs ───────────────────────────────────────────────────────


## The previous run didn't exit cleanly. If its log has the crash handler's backtrace, that's sent
## as the crash. Release export templates have no crash handler, so otherwise it's sent as an
## unclean exit, with the last error logged just before (OS.crash's message, a failed check),
## unless the game was in the background (the OS may stop it there) or run from the editor
## (stopping it there kills it).
func _check_previous_run() -> void:
	var marker_path := STORAGE.path_join("run.json")
	if not FileAccess.file_exists(marker_path):
		return
	var marker = JSON.parse_string(FileAccess.get_file_as_string(marker_path))
	DirAccess.remove_absolute(marker_path)
	if typeof(marker) != TYPE_DICTIONARY:
		return
	var log_path: String = ProjectSettings.get_setting("debug/file_logging/log_path", "user://logs/godot.log")
	var previous := Crash.previous_log(log_path)
	var text := ""
	var time := float(marker.get("seen", marker.get("started", 0)))
	if previous != "" and FileAccess.get_modified_time(previous) >= int(marker.get("started", 0)):
		text = Crash.read_tail(previous)
		time = float(FileAccess.get_modified_time(previous))
	var crash := Crash.parse(text)
	if crash.is_empty():
		if marker.get("editor", false) or marker.get("background", false):
			return
		crash = Crash.unclean_exit(text)
	var record := {}
	for key in marker.get("context", {}):
		record[key] = marker.context[key]
	record["exception.type"] = crash.type
	record["exception.message"] = crash.message
	record["exception.stacktrace"] = crash.stacktrace
	record["zharp.handled"] = "false"
	record["zharp.mechanism"] = crash.mechanism
	record["zharp.error.kind"] = "crash"
	if crash.engine != "":
		record["godot.engine_version"] = crash.engine
	if config.source_context:
		var code := _errors.source_context(crash.frames)
		if code != "":
			record["zharp.source_context"] = code
	var resource := _resource.duplicate()
	if str(marker.get("release", "")) != "":
		resource["service.version"] = marker.release
	var entry := Otlp.log_record("fatal", crash.type + ": " + crash.message, Otlp.clean(record), Otlp.nanos(time))
	_transport.write("logs", Otlp.logs_request(resource, [entry]))
	_debug("the previous run crashed (%s): sending it" % crash.type)


## What a crash in this run will be sent with.
func _write_marker() -> void:
	if not enabled:
		return
	DirAccess.make_dir_recursive_absolute(STORAGE)
	var file := FileAccess.open(STORAGE.path_join("run.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify({
			"started": _started_at,
			"seen": int(Time.get_unix_time_from_system()),
			"release": _resource.get("service.version", ""),
			"editor": OS.has_feature("editor"),
			"background": _background,
			"context": _context(),
		}))


## On the watchdog's thread: the main thread is stuck.
func _on_hang(seconds: float) -> void:
	var where := " on " + _screen if _screen != "" else ""
	var message := "The main thread was blocked for %s s%s" % [String.num(seconds, 1), where]
	var record := _context()
	record["exception.type"] = "ApplicationNotResponding"
	record["exception.message"] = message
	record["exception.stacktrace"] = "ApplicationNotResponding: " + message
	record["zharp.handled"] = "false"
	record["zharp.mechanism"] = "hang"
	record["zharp.error.kind"] = "anr"
	record["thread.name"] = "main"
	# Straight to disk: the player may kill the game while it's stuck.
	_transport.write("logs", Otlp.logs_request(_resource, [Otlp.log_record("error", "ApplicationNotResponding: " + message, Otlp.clean(record))]))


# ─── Logs ────────────────────────────────────────────────────────────────────


## A log record, sent whatever `zharp/logs` says (that setting is about what the game prints).
func log_debug(message: String, attributes := {}) -> void: _log("debug", message, attributes)
func log_info(message: String, attributes := {}) -> void: _log("info", message, attributes)
func log_warn(message: String, attributes := {}) -> void: _log("warn", message, attributes)
func log_error(message: String, attributes := {}) -> void: _log("error", message, attributes)


func _log(level: String, message: String, attributes: Dictionary) -> void:
	if not enabled:
		return
	var record := _context()
	record.merge(attributes, true)
	var span: ZharpSpan = _current_span()
	_transport.add_log(Otlp.log_record(level, message, Otlp.clean(record), "",
		span.trace_id if span != null else "", span.span_id if span != null else ""))


# ─── Context ─────────────────────────────────────────────────────────────────


## The signed-in player: `enduser.id`, `enduser.email`, `enduser.name` on everything from now on.
func set_user(id: String, email := "", user_name := "") -> void:
	if id.strip_edges() == "":
		clear_user()
		return
	_user = {"enduser.id": id.strip_edges()}
	if email != "":
		_user["enduser.email"] = email
	if user_name != "":
		_user["enduser.name"] = user_name
	_write_marker()


## Forget the player (sign-out), and start a new session for whoever comes next.
func clear_user() -> void:
	_user = {}
	if _session != null:
		_session.reset()
	_write_marker()


## An attribute on every error, log and span from now on; null removes it.
func set_tag(key: String, value) -> void:
	if value == null:
		_tags.erase(key)
	else:
		_tags[key] = value


## The screen, when the current scene doesn't say it well (a menu inside one scene).
func set_screen(screen: String) -> void:
	_screen_shown(screen)


func _check_scene() -> void:
	var scene := get_tree().current_scene
	var id := scene.get_instance_id() if scene != null else 0
	if id == _scene_id:
		return
	_scene_id = id
	if scene == null:
		return
	var path := scene.scene_file_path
	_screen_shown(path.get_file().get_basename() if path != "" else str(scene.name))


func _screen_shown(screen: String) -> void:
	if screen == "" or screen == _screen:
		return
	_screen = screen
	_write_marker()
	screen_changed.emit(screen)
	if enabled and config.tracing:
		var span := start_span("screen " + screen, {"screen.type": "scene"}, true)
		span.end()


func _context() -> Dictionary:
	var out := _tags.duplicate()
	out.merge(_user, true)
	if _session != null:
		out["session.id"] = _session.current()
	if _screen != "":
		out["screen.name"] = _screen
	return out


# ─── Spans and requests ──────────────────────────────────────────────────────


## A span for a piece of work; what's started before it ends is inside it. End it with `end()`.
func start_span(span_name: String, attributes := {}, root := false) -> ZharpSpan:
	var parent: ZharpSpan = null if root else _current_span()
	var trace := parent.trace_id if parent != null else Otlp.random_hex(16)
	var sampled: bool = parent.sampled if parent != null else (enabled and config.tracing and randf() < config.traces_sample_rate)
	var span := ZharpSpan.new(span_name, trace, parent.span_id if parent != null else "", sampled, _span_ended)
	span.attributes = attributes.duplicate()
	_spans.append(span)
	return span


func _current_span() -> ZharpSpan:
	for i in range(_spans.size() - 1, -1, -1):
		if not _spans[i].ended:
			return _spans[i]
	return null


func _span_ended(span: ZharpSpan) -> void:
	_spans.erase(span)
	if enabled and span.sampled:
		_transport.add_span(span.to_otlp(Time.get_unix_time_from_system(), Otlp.clean(_context())))


## `HTTPRequest.request()`, traced: a client span with the method, URL, status and headers (secrets
## filtered), and `traceparent` so your server's trace continues it.
##     Zharp.request($HTTPRequest, "https://api.example.com/scores")
func request(http: HTTPRequest, url: String, custom_headers := PackedStringArray(), method := HTTPClient.METHOD_GET, request_data := "") -> Error:
	var methods := ["GET", "HEAD", "POST", "PUT", "DELETE", "OPTIONS", "TRACE", "CONNECT", "PATCH"]
	var verb: String = methods[method] if method >= 0 and method < methods.size() else "GET"
	if not enabled or url.begins_with(str(config.get("endpoint", "-"))):
		return http.request(url, custom_headers, method, request_data)
	var span := start_span(verb, {
		"http.request.method": verb,
		"url.full": Headers.redact_url(url),
		"server.address": _host_of(url),
	})
	span.kind = Otlp.KIND_CLIENT
	var headers := PackedStringArray(custom_headers)
	if span.sampled or config.tracing:
		headers.append("traceparent: " + span.traceparent())
		var baggage := "session.id=" + session_id
		if _user.has("enduser.id"):
			baggage += ",enduser.id=" + str(_user["enduser.id"]).uri_encode()
		headers.append("baggage: " + baggage)
	span.attributes.merge(Headers.attributes("request", custom_headers), true)
	var done := func(result: int, status: int, response_headers: PackedStringArray, _body: PackedByteArray) -> void:
		if result != HTTPRequest.RESULT_SUCCESS:
			span.set_attribute("error.type", "result_%d" % result)
			span.set_error("HTTPRequest result %d" % result)
		else:
			span.set_attribute("http.response.status_code", status)
			span.attributes.merge(Headers.attributes("response", response_headers), true)
			if status >= 400:
				span.set_attribute("error.type", str(status))
				span.set_error()
		span.end()
	http.request_completed.connect(done, CONNECT_ONE_SHOT)
	var err := http.request(url, headers, method, request_data)
	if err != OK:
		http.request_completed.disconnect(done)
		span.set_attribute("error.type", error_string(err))
		span.set_error(error_string(err))
		span.end()
	return err


static func _host_of(url: String) -> String:
	var rest := url.substr(url.find("://") + 3) if url.contains("://") else url
	var end := rest.length()
	for c in ["/", "?", "#"]:
		var i := rest.find(c)
		if i >= 0 and i < end:
			end = i
	var host := rest.substr(0, end)
	host = host.substr(host.rfind("@") + 1)
	return host.substr(0, host.rfind(":")) if host.contains(":") and not host.ends_with("]") else host


## Send everything waiting now.
func flush() -> void:
	if enabled:
		_drain()
		_transport.flush()


# ─── Settings ────────────────────────────────────────────────────────────────


func _resolve(options: Dictionary) -> Dictionary:
	var c := {
		"key": _text("zharp/key", "ZHARP_KEY"),
		"endpoint": _text("zharp/endpoint", "ZHARP_ENDPOINT"),
		"service": _text("zharp/service", "ZHARP_SERVICE"),
		"release": _text("zharp/release", "ZHARP_RELEASE"),
		"environment": _text("zharp/environment", "ZHARP_ENVIRONMENT"),
		"enabled": _switch("zharp/enabled", "ZHARP_ENABLED", true),
		"logs": _switch("zharp/logs", "ZHARP_LOGS", false),
		"tracing": _switch("zharp/tracing", "ZHARP_TRACING", true),
		"traces_sample_rate": float(_setting("zharp/traces_sample_rate", 1.0)),
		"detect_hangs": _switch("zharp/detect_hangs", "ZHARP_DETECT_HANGS", true),
		"hang_threshold": float(_setting("zharp/hang_threshold", 5.0)),
		"source_context": bool(_setting("zharp/source_context", true)),
		"debug": _switch("zharp/debug", "ZHARP_DEBUG", false),
	}
	for key in options:
		c[key] = options[key]
	c.key = str(c.key).strip_edges()
	c.endpoint = str(c.endpoint).strip_edges().rstrip("/")
	if c.endpoint == "":
		c.endpoint = DEFAULT_ENDPOINT
	if c.service == "":
		c.service = str(ProjectSettings.get_setting("application/config/name", ""))
	if c.service == "":
		c.service = "godot-game"
	if c.release == "":
		c.release = str(ProjectSettings.get_setting("application/config/version", ""))
	if c.environment == "" and OS.has_feature("editor"):
		c.environment = "development"
	return c


static func _setting(name: String, fallback):
	return ProjectSettings.get_setting(name, fallback)


static func _text(name: String, env: String) -> String:
	var from_env := OS.get_environment(env).strip_edges()
	return from_env if from_env != "" else str(_setting(name, "")).strip_edges()


static func _switch(name: String, env: String, fallback: bool) -> bool:
	var from_env := OS.get_environment(env).strip_edges().to_lower()
	if from_env in ["1", "true", "yes", "on"]:
		return true
	if from_env in ["0", "false", "no", "off"]:
		return false
	return bool(_setting(name, fallback))


func _resource_attributes() -> Dictionary:
	var info := Engine.get_version_info()
	var os_names := {"Windows": "windows", "macOS": "darwin", "Linux": "linux", "FreeBSD": "freebsd",
		"Android": "android", "iOS": "ios", "Web": "web", "visionOS": "visionos"}
	var r := {
		"service.name": config.service,
		"telemetry.sdk.name": "zharp",
		"telemetry.sdk.language": "gdscript",
		"telemetry.sdk.version": VERSION,
		"process.runtime.name": "godot",
		"process.runtime.version": "%d.%d.%d" % [info.major, info.minor, info.patch],
		"godot.version": str(info.string),
		"godot.build": "debug" if OS.is_debug_build() else "release",
		"os.name": os_names.get(OS.get_name(), OS.get_name().to_lower()),
		"os.type": os_names.get(OS.get_name(), OS.get_name().to_lower()),
		"os.version": OS.get_version(),
		"host.arch": Engine.get_architecture_name(),
		"device.id": _session.device_id,
	}
	var model := OS.get_model_name()
	if model != "" and model != "GenericDevice":
		r["device.model.identifier"] = model
		r["device.model.name"] = model
	var renderer := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", ""))
	if renderer != "":
		r["godot.renderer"] = renderer
	if config.release != "":
		r["service.version"] = config.release
	if config.environment != "":
		r["deployment.environment.name"] = config.environment
	return Otlp.clean(r)


func _warn(message: String) -> void:
	if _warned.has(message):
		return
	_warned[message] = true
	print("[Zharp] " + message)


func _debug(message: String) -> void:
	if config.get("debug", false):
		print("[Zharp] " + message)
