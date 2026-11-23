## Request and response headers on HTTP client spans, as OpenTelemetry names them
## (`http.request.header.user-agent`). Secret headers are recorded as `[Filtered]`: sent, but the
## value never leaves the device. The same rules as every other Zharp SDK.
extends RefCounted

const FILTERED := "[Filtered]"
const MAX_HEADERS := 40
const MAX_VALUE := 512

const SECRET_HEADERS := ["authorization", "proxy-authorization", "cookie", "set-cookie", "x-api-key", "x-auth-token", "x-csrf-token", "x-xsrf-token"]
## Keys whose values never leave the app, compared without case, `-` or `_`.
const CONTAINS := ["password", "passwd", "passphrase", "secret", "token", "apikey", "accesskey", "privatekey",
	"authorization", "cookie", "creditcard", "cardnumber", "cvv", "cvc", "ssn", "iban", "sessionid", "signature", "credential"]
const EXACT := ["auth", "pin", "pwd", "otp", "card", "pan", "jwt", "sid", "codeverifier"]
## Also secret in a query string, where they are API keys and signed-URL signatures.
const URL_EXACT := ["key", "sig", "code", "state", "session"]


static func normalize(key: String) -> String:
	var out := ""
	for c in key.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
	return out


static func is_secret_key(key: String) -> bool:
	var k := normalize(key)
	if k == "":
		return false
	if k in EXACT:
		return true
	for part in CONTAINS:
		if k.contains(part):
			return true
	return false


## `http.<side>.header.<name>` attributes from Godot's "Name: value" header lines.
static func attributes(side: String, lines: PackedStringArray) -> Dictionary:
	var joined := {}
	for raw in lines:
		var at := raw.find(":")
		if at <= 0:
			continue
		var name := raw.substr(0, at).strip_edges().to_lower()
		var value := raw.substr(at + 1).strip_edges()
		if not joined.has(name):
			if joined.size() >= MAX_HEADERS:
				continue
			joined[name] = []
		joined[name].append(value)
	var out := {}
	for name in joined:
		var value: String = ", ".join(PackedStringArray(joined[name]))
		if name in SECRET_HEADERS or is_secret_key(name):
			value = FILTERED
		elif value.length() > MAX_VALUE:
			value = value.substr(0, MAX_VALUE) + "…"
		out["http.%s.header.%s" % [side, name]] = value
	return out


## A URL with secret query values and any user:password replaced.
static func redact_url(url: String) -> String:
	var out := url
	var scheme := out.find("://")
	if scheme >= 0:
		var rest_start := scheme + 3
		var slash := out.find("/", rest_start)
		var authority := out.substr(rest_start, (slash - rest_start) if slash >= 0 else -1)
		var at := authority.rfind("@")
		if at >= 0:
			out = out.substr(0, rest_start) + FILTERED + "@" + out.substr(rest_start + at + 1)
	var q := out.find("?")
	if q < 0:
		return out
	var hash_at := out.find("#", q)
	var query := out.substr(q + 1, (hash_at - q - 1) if hash_at >= 0 else -1)
	var parts := PackedStringArray()
	for pair in query.split("&"):
		var eq := pair.find("=")
		var key := (pair.substr(0, eq) if eq >= 0 else pair).uri_decode()
		if eq >= 0 and (is_secret_key(key) or normalize(key) in URL_EXACT):
			parts.append(pair.substr(0, eq) + "=" + FILTERED)
		else:
			parts.append(pair)
	return out.substr(0, q + 1) + "&".join(parts) + (out.substr(hash_at) if hash_at >= 0 else "")
