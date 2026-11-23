# Changelog

## 0.1.0

First release, for Godot 4.5 and later (GDScript; C# games add the `Zharp.Godot` NuGet package).

- Errors through Godot's `Logger` (`OS.add_logger`): script errors, `push_error()` and engine
  errors with their backtraces (`[0] take_damage (res://player/player.gd:42)`) and the code around
  the game's frames (`zharp.source_context`), each sent once (the same error from the same place at
  most once a minute). Warnings as breadcrumbs. C# exceptions Godot catches in callbacks, with their
  .NET stack. `Zharp.capture_error()` for handled ones.
- Release exports keep backtraces: the plugin turns on `always_track_call_stacks`. The export
  plugin adds the scripts' text to the export, which Godot 4.3+ otherwise compiles to tokens.
- Engine crashes, sent on the next launch from the crash handler's report in the previous run's
  log, with that run's session, scene and player. Release templates have no crash handler: a run
  that didn't shut down is an `UncleanExit`, with the error logged just before it.
- Hangs: the main thread stuck for 5 s, reported from a watchdog thread straight to disk.
- `session.id`, `device.id`, the scene as `screen.name` (and a `screen` span), `enduser.*`, tags.
- `Zharp.request()`: HTTPRequest traced with `traceparent`, headers with secrets filtered.
- An outbox in `user://zharp/`: every batch on disk before it's sent; what's left goes on the next
  launch.
- Logs off by default; `zharp/logs` or `ZHARP_LOGS=true` sends what the game prints.

Known limits: GDScript runtime errors aren't reported by release export templates (Godot checks
them in debug builds only). Engine frames are addresses unless the export templates have debug
symbols; minidumps wait for the optional GDExtension. Hangs aren't detected on web exports without
threads.
