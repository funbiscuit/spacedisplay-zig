#!/bin/bash
# One-stop check: formatting + build + tests.
set -eu -o pipefail
cd "$(dirname "$0")/.."

ZIG=${ZIG:-zig}

$ZIG fmt --check .
$ZIG build
$ZIG build test
