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
  main.zig        entry point: allocator, logging, panic handler
  lib.zig         library root re-exporting the public API (added with the test setup)
  cli.zig         argument parsing, app startup
  Scanner.zig     background scanner (worker thread + tree state)
  Tree.zig        scanned directory tree (pure data structure)
  StringPool.zig  string interning for tree node names
  queue.zig       thread-safe bounded LIFO queue
  platform.zig    mount stats / can-scan queries (statvfs, stat)
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

## Invariants

- Every commit must leave `scripts/check.sh` green.
- Keep commits small and independently reviewable.
- Tests must be deterministic: no network, no terminal required, no reliance on
  wall-clock time, every wait bounded by a timeout.
