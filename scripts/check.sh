#!/bin/bash
# One-stop check: formatting + build + tests.
set -eu -o pipefail
cd "$(dirname "$0")/.."

ZIG=${ZIG:-zig}

# Only first-party sources: zig-pkg/ is a dependency cache whose contents
# zig fmt may legitimately disagree with.
$ZIG fmt --check src tests build.zig build.zig.zon
$ZIG build
$ZIG build test
