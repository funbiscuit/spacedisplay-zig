#!/bin/bash

set -eu -o pipefail
SCAN_PATH=$1
SPACE_DISPLAY_CMD="zig-out/bin/spacedisplay --no-ui $SCAN_PATH"
SPACE_DISPLAY_RS_CMD="zig-out/spacedisplay-rs --no-ui $SCAN_PATH"
# du will exit with non zero code if got permission denied on some paths
DU_CMD="du -sh $SCAN_PATH || exit 0"

zig build -Doptimize=ReleaseSafe

compare_file="zig-out/COMPARE.md"

echo "## $(uname -sr)" >$compare_file

if [ -f "zig-out/spacedisplay-rs" ]; then
  hyperfine --warmup 5 -m 10 \
    --export-markdown "zig-out/compare-temp.md" \
    -n spacedisplay-zig \
    "$SPACE_DISPLAY_CMD" \
    -n spacedisplay-rs \
    "$SPACE_DISPLAY_RS_CMD" \
    -n "du -sh" \
    "$DU_CMD"
else
  hyperfine --warmup 5 -m 10 \
    --export-markdown "zig-out/compare-temp.md" \
    -n spacedisplay-zig \
    "$SPACE_DISPLAY_CMD" \
    -n "du -sh" \
    "$DU_CMD"
fi

cat "zig-out/compare-temp.md" >>$compare_file
rm -f "zig-out/compare-temp.md"
