# Zharp for Godot

Errors with their backtraces and the code that ran, engine crashes, hangs, sessions, scenes and
(optionally) logs from Godot games, sent to [Zharp](https://zharp.io).

A plain GDScript addon for **Godot 4.5 and later** (it's built on the `Logger` class that 4.5
added). Nothing to compile: it works on every platform Godot exports to, the web included.

## Install

**Asset Library:** search for "Zharp" in the editor's AssetLib tab, download, and install
`addons/zharp`. **Or by hand:** copy `addons/zharp` from this repository into your project.
**Or** `npm init zharp@latest` in the project folder: it finds `project.godot`, copies the addon,
enables it and writes your key.

Then enable it in **Project › Project Settings › Plugins**, and paste your app's key (from its
Setup page in Zharp) into **Project Settings › Zharp › Key** — it's saved in `project.godot`:

```ini
[zharp]
key="zpk_…"
```

That's all: the `Zharp` autoload the plugin adds starts with the game.

## What it reports

- **Errors:** every script error, `push_error()` and engine error, with the GDScript backtrace
  (`[0] take_damage (res://player/player.gd:42)`) and the lines around the game's frames. Each is
  sent once: the same error from the same place at most once a minute (an error in `_process`
  happens every frame). Warnings become breadcrumbs on the next error.
- **Release exports:** the plugin turns on `debug/settings/gdscript/always_track_call_stacks`, so
  release builds keep their backtraces (at a small cost in speed). Godot's release templates don't
  report GDScript runtime errors (a call on `null`, a bad index) at all — the VM checks them only in
  debug builds — so in release exports you get `push_error()`, engine errors, crashes and hangs.
- **The code that ran:** Godot 4.3+ exports scripts as compiled tokens, so the export plugin adds
  each script's text to the export (`res://.zharp/sources/`) for the addon to read the lines around
  an error. Turn `zharp/source_context` off to leave your export alone.
- **Engine crashes:** Godot's crash handler writes the backtrace to the log; on the next launch the
  addon reads the previous run's log and sends the crash (`SIGSEGV`, `SIGILL`…) with that run's
  session, scene and player. The official **release** templates have no crash handler: there, a run
  that ended without shutting down is sent as `UncleanExit`, with the error Godot logged just before
  (`OS.crash`'s message, a failed check) and its backtrace. Engine frames are addresses unless your
  export templates were built with debug symbols. Crashes need file logging, which the plugin turns
  on for every platform (`debug/file_logging/enable_file_logging`).
- **Hangs:** the main thread not getting through a frame for 5 s (`zharp/hang_threshold`) is
  reported once per freeze (`ApplicationNotResponding`), from a watchdog thread, straight to disk —
  so it's sent even if the player kills the game. Not on web exports without threads, nor under
  the debugger.
- **Sessions, device, screens:** `session.id` (a new one after 30 minutes in the background, or on
  `clear_user()`), a random `device.id` kept in `user://zharp/`, the current scene as `screen.name`
  (with a `screen <name>` span each time one is shown), and the player you set as `enduser.*`.
- **Offline:** every batch is written to `user://zharp/outbox/` before it's sent and deleted once
  Zharp has it, so what couldn't be sent (no network, a crash, a quit) goes on the next launch.
- **Logs:** off by default. With `zharp/logs` on (or `ZHARP_LOGS=true`), what the game prints is
  sent: `print()` as info, `printerr()` as errors, warnings as warnings.

## API

```gdscript
Zharp.set_user("player-42", "ada@example.com", "Ada")   # enduser.* on everything
Zharp.clear_user()                                        # sign-out: a new session
Zharp.set_tag("level", "forest-2")                        # an attribute on everything from now on

Zharp.capture_error("Save failed: disk full", {"slot": 2})   # a handled error, with where it was called
Zharp.log_info("Checkout opened", {"items": 3})              # also log_debug, log_warn, log_error

var span := Zharp.start_span("load_level", {"level": 3})     # a span; what starts inside is in it
span.end()

# HTTPRequest, traced: method, URL, status, headers (secrets filtered), and traceparent so your
# server's trace continues it.
Zharp.request($HTTPRequest, "https://api.example.com/scores")

Zharp.flush()   # send what's waiting now
```

## Settings

Project Settings › Zharp (`[zharp]` in `project.godot`). Each can be overridden by an environment
variable on desktop, or by `Zharp.start({...})` when `zharp/auto_start` is off.

| Setting | Environment | Default | |
|---|---|---|---|
| `zharp/key` | `ZHARP_KEY` | | the app's key |
| `zharp/environment` | `ZHARP_ENVIRONMENT` | `development` when run from the editor | |
| `zharp/release` | `ZHARP_RELEASE` | `application/config/version` | |
| `zharp/service` | `ZHARP_SERVICE` | `application/config/name` | |
| `zharp/logs` | `ZHARP_LOGS` | off | send what the game prints |
| `zharp/tracing` | `ZHARP_TRACING` | on | spans (scenes, requests, yours) |
| `zharp/traces_sample_rate` | | 1.0 | |
| `zharp/detect_hangs` | `ZHARP_DETECT_HANGS` | on | |
| `zharp/hang_threshold` | | 5 s | |
| `zharp/source_context` | | on | ship scripts' text for the code that ran |
| `zharp/release_backtraces` | | on | lets the plugin turn on call stacks and file logging |
| `zharp/enabled` | `ZHARP_ENABLED` | on | |
| `zharp/auto_start` | | on | off: call `Zharp.start()` yourself |
| `zharp/debug` | `ZHARP_DEBUG` | off | print what Zharp does |
| `zharp/endpoint` | `ZHARP_ENDPOINT` | `https://api.zharp.io/api/v1/otlp` | |

## C#

Godot .NET games keep the addon for script and engine errors, crashes, hangs and scenes, and add
the [`Zharp.Godot`](https://www.nuget.org/packages/Zharp.Godot) NuGet package for the C# side:
exceptions that end the game (on any thread; saved to disk and sent on the next launch), exceptions
you catch (with their .NET stack and the code that ran), and `ILogger` lines with logs on — all on
the addon's session, device, scene and player.

```sh
dotnet add package Zharp.Godot
```

```csharp
public partial class Main : Node
{
    public override void _Ready() => Zharp.Godot.ZharpGodot.Start(this);
}
```

`ZharpGodot.SetUser(...)`, `ClearUser()` and `CaptureException(e)` set or report on both sides.
Exceptions Godot catches in your callbacks (`_Ready`, `_Process`, signals) are reported by the addon
with their .NET stack, without the package. Godot loads games into their own load context, where
the runtime's `HttpClient` diagnostics can't be seen; trace requests with
`new HttpClient(ZharpGodot.HttpHandler())`.

## Not yet

- Readable engine frames and minidumps (other threads included) wait for an optional GDExtension
  built on Zharp's native SDK.
- Godot 3 and 4.0–4.4 aren't supported: the `Logger` class arrived in 4.5.

## Development

```sh
# Unit tests (the repository is a Godot project with the addon in it)
godot --headless --import && godot --headless -s res://tests/run.gd

# End to end, in Docker: Godot 4.5.1 headless against a stand-in receiver — debug runs, a Linux
# release export and the web export in headless Chromium
docker build -t zharp-godot-test:4.5.1 e2e/docker
docker run --rm -v "$PWD:/src:ro" zharp-godot-test:4.5.1 bash /src/e2e/run.sh
```

## License

MIT
