"""Checks what the stand-in receiver got for one e2e scenario.
Usage: check.py <scenario> <received.jsonl> <requests.jsonl>"""
import json
import sys

scenario, received_path, requests_path = sys.argv[1], sys.argv[2], sys.argv[3]


def values(attributes):
    return {a["key"]: list(a["value"].values())[0] for a in attributes}


logs, spans, batches = [], [], []
for line in open(received_path):
    entry = json.loads(line)
    batches.append(entry)
    body = entry["body"]
    for rl in body.get("resourceLogs", []):
        resource = values(rl["resource"]["attributes"])
        for scope in rl["scopeLogs"]:
            for r in scope["logRecords"]:
                logs.append({"resource": resource, "severity": r["severityText"], "body": r["body"]["stringValue"],
                             "time": r["timeUnixNano"], "trace": r.get("traceId"), "a": values(r["attributes"])})
    for rs in body.get("resourceSpans", []):
        resource = values(rs["resource"]["attributes"])
        for scope in rs["scopeSpans"]:
            for s in scope["spans"]:
                spans.append({"resource": resource, "name": s["name"], "kind": s["kind"], "trace": s["traceId"],
                              "id": s["spanId"], "parent": s.get("parentSpanId"), "status": s["status"], "a": values(s["attributes"])})
requests = [json.loads(line) for line in open(requests_path)]
errors = [l for l in logs if "exception.type" in l["a"]]
problems = []


def expect(condition, what):
    if not condition:
        problems.append(what)


def of_type(t):
    return [e for e in errors if e["a"]["exception.type"] == t]


def common(error_list):
    for e in error_list:
        r = e["resource"]
        expect(r.get("service.name") == "Shop Quest", "service.name")
        expect(r.get("service.version") == "1.4.0", "service.version is the game's version")
        expect(r.get("telemetry.sdk.language") == "gdscript", "telemetry.sdk.language")
        expect(len(r.get("device.id", "")) == 32, "device.id")
        expect(len(e["a"].get("session.id", "")) == 32, "session.id")
        expect(e["a"].get("enduser.id") == "player-42", "enduser.id on " + e["body"])
    for b in batches:
        expect(b["auth"] == "Bearer zpk_e2e_test", "the key as a bearer token")
        expect(b["gzip"], "gzipped")


def frames(e):
    return e["a"]["exception.stacktrace"].split("\n")[1:]


def check_errors(runs, release=False):
    script = of_type("ScriptError")
    # Release export templates don't report GDScript runtime errors at all (the VM checks them
    # only in debug builds); push_error and the engine's errors still come, with backtraces.
    expect(len(script) == (0 if release else runs), "ScriptErrors: got %d" % len(script))
    for e in script:
        expect(frames(e)[:2] == ["[0] add_to_cart (res://shop/checkout.gd:36)", "[1] _ready (res://shop/checkout.gd:12)"],
               "script backtrace%s: %s" % (" in a release export" if release else "", frames(e)))
        expect(e["a"]["zharp.handled"] == "false", "unhandled")
        expect(e["a"].get("screen.name") == "level", "screen.name = the scene")
        context = json.loads(e["a"].get("zharp.source_context", "[]"))
        expect(context and context[0]["code"].strip() == "cart.append(item)", "the code that ran: %s" % context[:1])
        expect("Coupon SPRING expired" in e["a"].get("zharp.breadcrumbs", ""), "the warning as a breadcrumb")
    handled = of_type("Error")
    expect(sum(1 for e in handled if e["a"]["zharp.handled"] == "true") == runs, "capture_error once per run")
    expect(sum(1 for e in handled if e["a"]["zharp.handled"] == "false") == runs, "push_error once per run")
    engine = of_type("EngineError")
    expect(len(engine) == runs, "one EngineError per run")
    for e in engine:
        expect(frames(e)[1] == "[1] _ready (res://shop/checkout.gd:15)", "engine error's script frame")
    expect(len(errors) == (3 if release else 4) * runs, "each error once: got %d" % len(errors))
    for e in handled:
        expect(e["a"].get("screen.name") == "level", "screen.name on " + e["body"])
    sessions = {e["a"]["session.id"] for e in errors}
    expect(len(sessions) == 1, "a restart within 30 minutes keeps the session")
    devices = {e["resource"]["device.id"] for e in errors}
    expect(len(devices) == 1, "the same device.id across runs")
    gets = [s for s in spans if s["name"] == "GET"]
    expect(len(gets) == runs, "a client span per request")
    for s in gets:
        expect(s["kind"] == 3, "client span")
        expect(s["a"]["url.full"] == "http://localhost:4318/scores.json?api_key=[Filtered]", "URL secrets filtered")
        expect(s["a"]["http.request.header.authorization"] == "[Filtered]", "authorization filtered")
        expect(str(s["a"]["http.response.status_code"]) == "200", "status")
        parent = [p for p in spans if p["id"] == s["parent"]]
        expect(parent and parent[0]["name"] == "load_inventory", "inside the game's span")
    sent = [r for r in requests if r["path"].startswith("/scores.json")]
    expect(len(sent) == runs, "the game's requests reached the server")
    for r in sent:
        tp = r["headers"].get("traceparent", "")
        expect(any(tp.split("-")[1:3] == [s["trace"], s["id"]] for s in gets), "traceparent continues the client span")
        expect("session.id=" in r["headers"].get("baggage", ""), "session in baggage")
    screens = [s for s in spans if s["name"] == "screen level"]
    expect(len(screens) == runs, "a screen span per scene shown")
    info = [l for l in logs if l["body"] == "Checkout opened"]
    expect(len(info) == runs and str(info[0]["a"].get("items")) == "3", "Zharp.log_info")
    common(errors)


if scenario in ("error", "release-error", "web"):
    # The web export is a release build too; it runs once (each Chromium launch is a new profile).
    runs = 1 if scenario == "web" else 2
    check_errors(runs, release=scenario != "error")
    if scenario == "release-error":
        expect(all(e["resource"]["godot.build"] == "release" for e in errors), "a release build")
    if scenario == "web":
        expect(all(e["resource"]["os.name"] == "web" for e in errors), "os.name web")
elif scenario == "logs":
    printed = [l for l in logs if "exception.type" not in l["a"]]
    bodies = sorted((l["severity"], l["body"]) for l in printed if l["body"] in ("Player bought a sword", "Low on gold"))
    expect(bodies == [("ERROR", "Low on gold"), ("INFO", "Player bought a sword")],
           "printed lines sent once, only with ZHARP_LOGS=true: %s" % bodies)
    expect(not any(l["body"].startswith("[Zharp]") for l in printed), "Zharp's own lines aren't sent")
elif scenario == "hang":
    anr = of_type("ApplicationNotResponding")
    expect(len(anr) == 2, "one hang per run, got %d" % len(anr))
    for e in anr:
        expect(e["a"]["zharp.error.kind"] == "anr", "kind anr")
        expect(e["a"]["exception.message"].startswith("The main thread was blocked for "), e["a"]["exception.message"])
        expect(e["a"]["exception.message"].endswith(" on level"), "the scene it froze on")
    common(anr)
elif scenario == "release-crash":
    # Release templates have no crash handler: an unclean exit, with the error logged just before.
    crashes = of_type("UncleanExit")
    expect(len(crashes) == 2, "one unclean exit per crashed run: got %d" % len(crashes))
    for e in crashes:
        expect(e["a"]["zharp.error.kind"] == "crash", "kind crash")
        expect(e["a"]["exception.message"] == "The game ended without shutting down after: Inventory corrupted", e["a"]["exception.message"])
        expect(frames(e)[:2] == ["[0] explode (res://shop/checkout.gd:40)", "[1] _ready (res://shop/checkout.gd:29)"], "script frames: %s" % frames(e)[:3])
        expect(e["a"].get("screen.name") == "level", "the crashed run's scene")
        context = json.loads(e["a"].get("zharp.source_context", "[]"))
        expect(context and "OS.crash" in context[0]["code"], "the code that ran (from the export's copy)")
    common(crashes)
elif scenario == "crash":
    crashes = of_type("SIGILL")
    expect(len(crashes) == 2, "one crash per crashed run, sent on the next launch: got %d" % len(crashes))
    for e in crashes:
        expect(e["a"]["zharp.error.kind"] == "crash", "kind crash")
        expect(e["severity"] == "FATAL", "fatal")
        expect(e["a"]["exception.message"].startswith("Inventory corrupted (Program crashed with signal 4"), e["a"]["exception.message"])
        expect(frames(e)[:2] == ["[0] explode (res://shop/checkout.gd:40)", "[1] _ready (res://shop/checkout.gd:29)"], "script frames: %s" % frames(e)[:3])
        expect(any("godot" in f or "shop_quest" in f or "libc" in f for f in frames(e)[2:]), "engine frames follow")
        expect(e["a"].get("screen.name") == "level", "the crashed run's scene")
        expect(e["resource"].get("service.version") == "1.4.0", "the crashed run's release")
        context = json.loads(e["a"].get("zharp.source_context", "[]"))
        expect(context and "OS.crash" in context[0]["code"], "the code that ran")
    expect(len({e["a"]["session.id"] for e in crashes}) == 1, "the crashed run's session")
    common(crashes)
elif scenario == "offline-nothing":
    expect(not batches, "nothing reached the receiver while offline")
elif scenario == "offline":
    expect(len(of_type("ScriptError")) == 1, "the offline run's error, sent from the outbox")
    expect(len(of_type("ApplicationNotResponding")) == 1, "the offline run's hang, sent from the outbox")
else:
    problems.append("unknown scenario " + scenario)

for p in problems:
    print("  -", p)
sys.exit(1 if problems else 0)
