#!/bin/bash
# Interactive viewer for .ansi golden snapshots.
#
# usage: scripts/gallery.sh [golden-name]
#
# Shows one golden per screen: a header line, then the styled body.
# Left/right switch goldens, q or Esc quits. The optional argument jumps
# to the golden whose name contains it.
set -eu -o pipefail
cd "$(dirname "$0")/.."

DIR=tests/snapshots

mapfile -t files < <(find "$DIR" -name '*.ansi' -type f | sort)
if (( ${#files[@]} == 0 )); then
  echo "no .ansi goldens found in $DIR" >&2
  exit 1
fi

cur=0
if (( $# > 0 )); then
  arg=${1%.ansi}
  for i in "${!files[@]}"; do
    base=$(basename "${files[$i]}" .ansi)
    if [[ $base == *"$arg"* ]]; then
      cur=$i
      break
    fi
  done
fi

render() {
  printf '\033[H\033[2J'
  printf '[%d/%d] %s  |  left/right: navigate  q: quit\n' \
    "$((cur + 1))" "${#files[@]}" "${files[$cur]}"
  local file="${files[$cur]}"
  local max=0 line clean
  while IFS= read -r line; do
    clean=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')
    if (( ${#clean} > max )); then max=${#clean}; fi
  done < "$file"
  local hline
  printf -v hline '─%.0s' $(seq 1 "$max")
  printf '┌%s┐\n' "$hline"
  while IFS= read -r line; do
    clean=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')
    printf '│%s%*s│\n' "$line" "$(( max - ${#clean} ))" ""
  done < "$file"
  printf '└%s┘\n' "$hline"
}

render
while true; do
  IFS= read -rsn1 char
  if [[ $char == $'\x1b' ]]; then
    if IFS= read -rsn2 -t 0.001 seq; then
      case $seq in
        '[C') if (( cur < ${#files[@]} - 1 )); then cur=$((cur + 1)); render; fi ;;
        '[D') if (( cur > 0 )); then cur=$((cur - 1)); render; fi ;;
      esac
    else
      break # bare Esc quits
    fi
    continue
  fi
  case $char in
    q|Q) break ;;
  esac
done
printf '\033[0m'
