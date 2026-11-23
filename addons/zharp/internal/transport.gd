## Sends to `{endpoint}/v1/logs` and `/v1/traces` as OTLP/JSON, through an outbox on disk.
##
## - Records wait in memory for at most `flush_interval` (or until 100 are waiting); then each
##   batch is written to `user://zharp/outbox/` before it's sent, and deleted once Zharp has it.
##   So nothing is lost to a crash, a quit or no network: what's left is sent on the next launch.
## - One request at a time, oldest first, gzipped.
## - Network failures, 408, 429 and 5xx are retried with backoff (1 s doubling to 5 min, or the
##   server's Retry-After); a batch the server keeps failing on goes after 5 tries.
## - 400 and other client errors drop the batch; 401/403 (a wrong or revoked key) print one
##   warning and drop what's queued, trying one batch again an hour later.
## - The outbox holds at most MAX_FILES batches; the oldest go first.
extends Node

const MAX_FILES := 200
const MAX_BATCH := 100
const MAX_SERVER_FAILURES := 5
const KEY_RETRY_SECONDS := 3600.0

var key := ""
var endpoint := ""
var resource := {}
var flush_interval := 5.0
var dir := "user://zharp/outbox"
var debug := false
var compress := true
## Called with a warning for the developer.
var warn: Callable

var _logs: Array = []
var _spans: Array = []
var _http: HTTPRequest
var _busy := false
var _busy_file := ""
var _retry_at := 0.0
var _failures := 0
var _server_failures := 0
var _key_rejected_until := 0.0
var _flush_at := 0.0
var _seq := 0
var _mutex := Mutex.new()
var _sent := 0


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	_http = HTTPRequest.new()
	_http.use_threads = false
	_http.timeout = 30.0
	add_child(_http)
	_http.request_completed.connect(_on_completed)
	pump()


func _process(_delta: float) -> void:
	var now := Time.get_unix_time_from_system()
	if (_logs.size() > 0 or _spans.size() > 0) and (now >= _flush_at or _logs.size() >= MAX_BATCH or _spans.size() >= MAX_BATCH):
		persist()
	if not _busy and now >= _retry_at:
		pump()


func add_log(record: Dictionary) -> void:
	if _logs.is_empty() and _spans.is_empty():
		_flush_at = Time.get_unix_time_from_system() + flush_interval
	_logs.append(record)


func add_span(span: Dictionary) -> void:
	if _logs.is_empty() and _spans.is_empty():
		_flush_at = Time.get_unix_time_from_system() + flush_interval
	_spans.append(span)


## Records waiting in memory and batches waiting on disk.
func pending() -> int:
	return _logs.size() + _spans.size() + _files().size()


## Write what waits in memory to the outbox. Safe on the way out: no network.
func persist() -> void:
	while _logs.size() > 0:
		var batch := _logs.slice(0, MAX_BATCH)
		_logs = _logs.slice(MAX_BATCH)
		write("logs", Otlp.logs_request(resource, batch))
	while _spans.size() > 0:
		var batch := _spans.slice(0, MAX_BATCH)
		_spans = _spans.slice(MAX_BATCH)
		write("traces", Otlp.traces_request(resource, batch))


## A request body straight to the outbox. Thread-safe (the hang watchdog writes from its thread).
func write(path: String, body: Dictionary) -> bool:
	_mutex.lock()
	_seq += 1
	var name := "%d-%06d-%s.json" % [int(Time.get_unix_time_from_system() * 1000.0), _seq, path]
	_mutex.unlock()
	DirAccess.make_dir_recursive_absolute(dir)
	var file := FileAccess.open(dir.path_join(name), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(body))
	file.close()
	_trim()
	return true


## Send the oldest batch on disk, if nothing is being sent.
func pump(force := false) -> void:
	if _busy or key == "" or (not force and Time.get_unix_time_from_system() < _retry_at):
		return
	if Time.get_unix_time_from_system() < _key_rejected_until:
		return
	var files := _files()
	if files.is_empty():
		return
	var name: String = files[0]
	var path := "logs" if name.ends_with("-logs.json") else "traces"
	var data := FileAccess.get_file_as_bytes(dir.path_join(name))
	if data.is_empty():
		DirAccess.remove_absolute(dir.path_join(name))
		return
	var headers := PackedStringArray(["Content-Type: application/json", "Authorization: Bearer " + key])
	if compress:
		var gz := data.compress(FileAccess.COMPRESSION_GZIP)
		if gz.size() > 0:
			data = gz
			headers.append("Content-Encoding: gzip")
	_busy = true
	_busy_file = name
	var err := _http.request_raw(endpoint + "/v1/" + path, headers, HTTPClient.METHOD_POST, data)
	if err != OK:
		_busy = false
		_retry(false, 0.0)


## Send the outbox now, ignoring a backoff wait once.
func flush() -> void:
	persist()
	_retry_at = 0.0
	pump(true)


func _on_completed(result: int, status: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	var file := dir.path_join(_busy_file)
	if result != HTTPRequest.RESULT_SUCCESS:
		_log("sending %s failed (result %d); will retry" % [_busy_file, result])
		_retry(false, 0.0)
		return
	if status == 401 or status == 403:
		if _key_rejected_until == 0.0 and warn.is_valid():
			warn.call("Zharp rejected the key (HTTP %d%s): nothing is being sent. Check zharp/key in Project Settings." % [status, _reason(body)])
		_key_rejected_until = Time.get_unix_time_from_system() + KEY_RETRY_SECONDS
		# A rejected key won't start working soon: what's queued is dropped, not kept.
		for name in _files():
			DirAccess.remove_absolute(dir.path_join(name))
		return
	if _key_rejected_until > 0.0 and status >= 200 and status < 300 and warn.is_valid():
		warn.call("Zharp accepted the key again: telemetry is being sent.")
	_key_rejected_until = 0.0
	if status >= 200 and status < 300:
		DirAccess.remove_absolute(file)
		_sent += 1
		_failures = 0
		_server_failures = 0
		_retry_at = 0.0
		pump()
		return
	if status == 408 or status == 429 or status >= 500:
		var wait := 0.0
		for header in headers:
			if header.to_lower().begins_with("retry-after:"):
				wait = float(header.substr(12).strip_edges().to_int())
		_server_failures += 1
		if _server_failures >= MAX_SERVER_FAILURES:
			DirAccess.remove_absolute(file)
			_server_failures = 0
		_log("sending got HTTP %d; will retry" % status)
		_retry(true, wait)
		return
	_log("Zharp refused a batch (HTTP %d%s); dropped" % [status, _reason(body)])
	DirAccess.remove_absolute(file)
	pump()


func _retry(_server: bool, retry_after: float) -> void:
	_failures += 1
	var wait := retry_after
	if wait <= 0.0:
		wait = minf(1.0 * pow(2.0, mini(_failures - 1, 20)), 300.0) * randf_range(0.8, 1.2)
	_retry_at = Time.get_unix_time_from_system() + wait


func _files() -> PackedStringArray:
	var names := PackedStringArray()
	for name in DirAccess.get_files_at(dir):
		if name.ends_with(".json"):
			names.append(name)
	names.sort()
	return names


func _trim() -> void:
	var files := _files()
	var extra := files.size() - MAX_FILES
	for i in max(0, extra):
		if files[i] != _busy_file:
			DirAccess.remove_absolute(dir.path_join(files[i]))


func _reason(body: PackedByteArray) -> String:
	var text := body.get_string_from_utf8().strip_edges()
	if text == "" or text == "{}":
		return ""
	return ": " + text.substr(0, 200)


func _log(message: String) -> void:
	if debug:
		print("[Zharp] " + message)


const Otlp := preload("otlp.gd")
