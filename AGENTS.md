# AGENTS.md

## Toolchain

**Zig is pinned to 0.15.x**

## Commands

```shell
scripts/check.sh        # zig fmt --check + zig build + zig build test (run before every commit)
zig build               # build debug binary into zig-out/bin/spacedisplay
zig build test          # run all tests
UPDATE_SNAPSHOTS=1 zig build test   # regenerate golden snapshots
```

## Layout

```
src/
  main.zig        executable entry: allocator, panic handler; depends only on the lib module
  lib.zig         library root re-exporting the public API (owns the third-party imports)
  cli.zig         argument parsing, app startup
  logging.zig     stderr logging with allow_log kill switch
  platform.zig    mount stats / can-scan queries (statvfs, stat)
  core.zig        namespace for the pure logic and data in core/
  core/           pure logic and data (no vaxis, threads, or filesystem)
  runtime.zig     namespace for the drivers in runtime/
  runtime/        threaded, filesystem-backed drivers of core state machines (Scanner)
  ui.zig          namespace for the widgets in ui/
  ui/             vaxis vxfw widgets, generic over a comptime Ctx
tests/            end-to-end tests (UI, CLI) against the public API only
  ui/             per-widget tests + harness.zig (headless draw/events),
                  fixtures.zig, TestCtx.zig (fake disk + clock), snapshot.zig
  cli/            binary tests + harness.zig (spawns the built exe), fixtures.zig
  snapshots/      golden pairs: <name>.txt (layout) + <name>.ansi (styles)
```

## Testing conventions

- **Unit tests live next to the code they test**, as `test` blocks inside the
  same file. They can use private declarations. The build collects them
  automatically from the import graph.
- **End-to-end tests live in `tests/`** (rooted at `tests/tests.zig`). That
  module sees only the public API re-exported by `src/lib.zig` — never import
  source files from `tests/` by relative path.
- A namespace grouping several files (e.g. `src/ui.zig` for `ui/`) carries its
  own `test { std.testing.refAllDecls(@This()); }` block: test collection
  follows references one level deep, and without the block the tests of the
  files it imports are silently skipped.
- UI golden snapshots come in pairs — `<name>.txt` pins layout and content,
  `<name>.ansi` pins styles (SGR escapes; review with `cat` or
  `scripts/gallery.sh [name]`). Goldens are grouped in subdirectories by
  widget; regenerate with `UPDATE_SNAPSHOTS=1 zig build test`.

## Invariants

- Every commit must leave `scripts/check.sh` green.
- Keep commits small and independently reviewable.
- `core/` imports std only. `ui/` never touches the filesystem or threads;
  `runtime/` is the only place that spawns threads and reads directories.
- No runtime polymorphism: views take their data through a comptime Ctx
  (runtime.Scanner in production, TestCtx in tests).
- Tests must be deterministic: no network, no terminal required, no reliance on
  wall-clock time, every wait bounded by a timeout.
