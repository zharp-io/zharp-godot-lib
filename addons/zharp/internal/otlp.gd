## OTLP/HTTP JSON: the shapes `POST {endpoint}/v1/traces` and `/v1/logs` accept.
## IDs are hex strings, 64-bit integers (timestamps) decimal strings, enums numbers.
extends RefCounted

const VERSION := "0.1.0"

## Values longer than this are cut; the server caps attributes at 16 KB anyway.
const MAX_ATTRIBUTE := 16 * 1024

const SEVERITY := {
	"trace": [1, "TRACE"],
	"debug": [5, "DEBUG"],
	"info": [9, "INFO"],
	"warn": [13, "WARN"],
	"error": [17, "ERROR"],
	"fatal": [21, "FATAL"],
}

const KIND_INTERNAL := 1
const KIND_CLIENT := 3
const STATUS_UNSET := 0
const STATUS_ERROR := 2


## Nanoseconds since the epoch as OTLP/JSON writes them.
static func now_nanos() -> String:
	return nanos(Time.get_unix_time_from_system())


static func nanos(unix_seconds: float) -> String:
	var micros := int(unix_seconds * 1000000.0)
	return "0" if micros <= 0 else str(micros) + "000"


## An attribute dictionary with values OTLP can carry: nulls dropped, others as text.
static func clean(attributes: Dictionary) -> Dictionary:
	var out := {}
	for key in attributes:
		var value = attributes[key]
		if value == null or str(key) == "":
			continue
		match typeof(value):
			TYPE_STRING, TYPE_STRING_NAME:
				var text := str(value)
				out[str(key)] = text.substr(0, MAX_ATTRIBUTE) if text.length() > MAX_ATTRIBUTE else text
			TYPE_BOOL, TYPE_INT:
				out[str(key)] = value
			TYPE_FLOAT:
				out[str(key)] = value if is_finite(value) else str(value)
			_:
				out[str(key)] = str(value).substr(0, MAX_ATTRIBUTE)
	return out


static func any_value(value) -> Dictionary:
	match typeof(value):
		TYPE_BOOL:
			return {"boolValue": value}
		TYPE_INT:
			return {"intValue": str(value)}
		TYPE_FLOAT:
			return {"doubleValue": value}
		TYPE_NIL:
			return {"stringValue": ""}
		_:
			return {"stringValue": str(value)}


static func key_values(attributes: Dictionary) -> Array:
	var out := []
	for key in attributes:
		out.append({"key": key, "value": any_value(attributes[key])})
	return out


## A log record (errors are log records with exception.* attributes).
static func log_record(level: String, body: String, attributes: Dictionary, time_nanos := "", trace_id := "", span_id := "") -> Dictionary:
	var severity: Array = SEVERITY.get(level, SEVERITY["info"])
	var at := time_nanos if time_nanos != "" else now_nanos()
	var record := {
		"timeUnixNano": at,
		"observedTimeUnixNano": at,
		"severityNumber": severity[0],
		"severityText": severity[1],
		"body": {"stringValue": body},
		"attributes": key_values(attributes),
	}
	if trace_id != "":
		record["traceId"] = trace_id
		record["spanId"] = span_id
	return record


static func logs_request(resource: Dictionary, records: Array) -> Dictionary:
	return {"resourceLogs": [{
		"resource": {"attributes": key_values(resource)},
		"scopeLogs": [{"scope": {"name": "zharp", "version": VERSION}, "logRecords": records}],
	}]}


static func traces_request(resource: Dictionary, spans: Array) -> Dictionary:
	return {"resourceSpans": [{
		"resource": {"attributes": key_values(resource)},
		"scopeSpans": [{"scope": {"name": "zharp", "version": VERSION}, "spans": spans}],
	}]}


## `count` random bytes as lowercase hex: 16 for a trace or session ID, 8 for a span ID.
## Its own generator, so a game that seeds the global one (`seed(42)`) doesn't repeat IDs.
static var _rng: RandomNumberGenerator


static func random_hex(count: int) -> String:
	if _rng == null:
		_rng = RandomNumberGenerator.new()
		_rng.randomize()
	var bytes := PackedByteArray()
	bytes.resize(count)
	for i in count:
		bytes[i] = _rng.randi() % 256
	var hex := bytes.hex_encode()
	# All zeros is an invalid OTLP ID.
	return hex if hex.count("0") < hex.length() else random_hex(count)
