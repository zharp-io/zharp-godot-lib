extends RefCounted

const Otlp := preload("res://addons/zharp/internal/otlp.gd")
const Session := preload("res://addons/zharp/internal/session.gd")
var t
var now := 1000000.0


func test_log_record() -> void:
	var r := Otlp.log_record("error", "boom", Otlp.clean({"a": 1, "b": true, "c": null, "d": 1.5}), "1700000000000000000")
	t.eq(r.severityNumber, 17)
	t.eq(r.severityText, "ERROR")
	t.eq(r.timeUnixNano, "1700000000000000000")
	t.eq(r.attributes, [{"key": "a", "value": {"intValue": "1"}}, {"key": "b", "value": {"boolValue": true}}, {"key": "d", "value": {"doubleValue": 1.5}}])


func test_nanos() -> void:
	t.eq(Otlp.nanos(1700000000.25), "1700000000250000000")


func test_ids() -> void:
	t.eq(Otlp.random_hex(16).length(), 32)
	t.ok(Otlp.random_hex(8) != Otlp.random_hex(8))


func test_session_rotates_after_30_minutes_in_the_background() -> void:
	DirAccess.make_dir_recursive_absolute("user://test-session")
	var s := Session.new("user://test-session", func() -> float: return now)
	var first := s.current()
	t.eq(first.length(), 32)
	t.eq(s.device_id.length(), 32)
	s.background()
	now += 29 * 60
	t.eq(s.current(), first, "29 minutes away keeps it")
	now += 2 * 60
	t.ok(s.current() != first, "31 minutes away starts a new one")


func test_restart_keeps_a_recent_session() -> void:
	var a := Session.new("user://test-session-2", func() -> float: return now)
	var b := Session.new("user://test-session-2", func() -> float: return now + 60)
	t.eq(b.id, a.id)
	t.eq(b.device_id, a.device_id)
	var c := Session.new("user://test-session-2", func() -> float: return now + 60 + 31 * 60)
	t.ok(c.id != a.id)
	t.eq(c.device_id, a.device_id)
