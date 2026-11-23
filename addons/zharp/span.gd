## A span: a piece of work with a start and an end, in a trace. Made by `Zharp.start_span()`
## and `Zharp.request()`; end it with `end()`.
##
##     var span := Zharp.start_span("load_level", {"level": 3})
##     ...
##     span.end()
class_name ZharpSpan
extends RefCounted

var trace_id := ""
var span_id := ""
var parent_span_id := ""
var name := ""
var kind := 1
var sampled := true
var attributes := {}
var status_code := 0
var status_message := ""
var ended := false
var _start := 0.0
var _events: Array = []
var _on_end: Callable


func _init(span_name := "", trace := "", parent := "", is_sampled := true, on_end := Callable()) -> void:
	name = span_name
	trace_id = trace
	parent_span_id = parent
	span_id = Crypto.new().generate_random_bytes(8).hex_encode() if is_sampled else "0000000000000000"
	sampled = is_sampled
	_start = Time.get_unix_time_from_system()
	_on_end = on_end


func set_attribute(key: String, value) -> ZharpSpan:
	if not ended:
		attributes[key] = value
	return self


## Mark the span failed.
func set_error(message := "") -> ZharpSpan:
	status_code = 2
	status_message = message
	return self


func add_event(event_name: String, event_attributes := {}) -> ZharpSpan:
	if not ended:
		_events.append({"name": event_name, "time": Time.get_unix_time_from_system(), "attributes": event_attributes})
	return self


## The W3C `traceparent` header value for a request made under this span.
func traceparent() -> String:
	return "00-%s-%s-%s" % [trace_id, span_id, "01" if sampled else "00"]


func end() -> void:
	if ended:
		return
	ended = true
	if _on_end.is_valid():
		_on_end.call(self)


## The span as OTLP/JSON.
func to_otlp(end_time: float, extra: Dictionary) -> Dictionary:
	var all := extra.duplicate()
	all.merge(Otlp.clean(attributes), true)
	var span := {
		"traceId": trace_id,
		"spanId": span_id,
		"name": name,
		"kind": kind,
		"startTimeUnixNano": Otlp.nanos(_start),
		"endTimeUnixNano": Otlp.nanos(end_time),
		"attributes": Otlp.key_values(all),
		"status": {"code": status_code},
	}
	if parent_span_id != "":
		span["parentSpanId"] = parent_span_id
	if status_message != "":
		span["status"]["message"] = status_message
	if not _events.is_empty():
		var events: Array = []
		for event in _events:
			events.append({"name": event.name, "timeUnixNano": Otlp.nanos(event.time), "attributes": Otlp.key_values(Otlp.clean(event.attributes))})
		span["events"] = events
	return span


const Otlp := preload("internal/otlp.gd")
