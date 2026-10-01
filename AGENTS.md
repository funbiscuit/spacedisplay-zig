# AGENTS.md

## Toolchain

**Zig is pinned to 0.15.x**

## Commands

```shell
scripts/check.sh        # zig fmt --check + zig build + zig build test (run before every commit)
zig build               # build debug binary into zig-out/bin/spacedisplay
zig build test          # run all tests
UPDATE_SNAPSHOTS=1 zig build test   # regenerate UI golden snapshots (when they exist)
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
  runtime/        threaded, filesystem-backed drivers of core state machines
  ui.zig          namespace for the widgets in ui/
  ui/             vaxis vxfw widgets (AppView, FilesView, ProgressBar)
tests/            end-to-end tests (UI, CLI) against the public API only
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

## Invariants

- Every commit must leave `scripts/check.sh` green.
- Keep commits small and independently reviewable.
- Tests must be deterministic: no network, no terminal required, no reliance on
  wall-clock time, every wait bounded by a timeout.
