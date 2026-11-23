extends RefCounted

const Headers := preload("res://addons/zharp/internal/headers.gd")
var t


func test_secret_headers_are_filtered() -> void:
	var a := Headers.attributes("request", PackedStringArray(["Authorization: Bearer x", "X-Session-Token: y", "Accept: application/json", "accept: text/plain"]))
	t.eq(a["http.request.header.authorization"], "[Filtered]")
	t.eq(a["http.request.header.x-session-token"], "[Filtered]")
	t.eq(a["http.request.header.accept"], "application/json, text/plain")


func test_urls() -> void:
	t.eq(Headers.redact_url("https://u:p@api.example.com/x?page=2&api_key=abc&sig=1#top"), "https://[Filtered]@api.example.com/x?page=2&api_key=[Filtered]&sig=[Filtered]#top")
	t.eq(Headers.redact_url("https://api.example.com/scores"), "https://api.example.com/scores")
