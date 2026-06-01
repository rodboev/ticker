#!/usr/bin/env bash
# Test harness for statusline.sh collapse cascade
# Patches WIDTH, pipes mock JSON, checks every line fits.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/statusline.sh"
CLAUDE_DIR="$HOME/.claude"

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
vis_len() {
  printf '%s' "$1" | strip_ansi \
    | sed 's/▓/X/g;s/░/X/g;s/📁/X/g;s/↑/X/g;s/↓/X/g;s/→/X/g;s/✓/X/g' | wc -c
}

NOW=$(date +%s)

BASE_JSON=$(cat <<'JEOF'
{
  "model": {"display_name": "Opus 4.6 (1M context)"},
  "effort": {"level": "max"},
  "context_window": {"used_percentage": 5, "context_window_size": 1000000},
  "rate_limits": {"five_hour": {"used_percentage": 18.2}, "seven_day": {"used_percentage": 34.1}},
  "workspace": {"project_dir": "/home/user/Desktop"},
  "cwd": "/home/user/Desktop"
}
JEOF
)

failures=0
_ms() { echo $(( $(date +%s%N) / 1000000 )); }
total_start=$(_ms)

for w in 140 130 125 122 118 115 112 110 108 105 102 100 97 95 92 90 88 85 82 80 78 76; do
  t0=$(_ms)

  sid="test-cascade-$w"
  epoch=$(( NOW - 36*60 - 7 ))
  echo -n "$epoch 3600" > "$CLAUDE_DIR/.sl_cache_$sid"
  rm -f "$CLAUDE_DIR/.sl_compute_$sid" "$CLAUDE_DIR/.sl_mtime_$sid"

  json=$(echo "$BASE_JSON" | jq --arg tp "$CLAUDE_DIR/$sid.jsonl" '.transcript_path = $tp')

  tmp="$CLAUDE_DIR/.test_w${w}.sh"
  sed "s/^WIDTH=[0-9]*/WIDTH=$w/" "$SCRIPT" > "$tmp"
  chmod +x "$tmp"

  out=$(echo "$json" | bash "$tmp" 2>/dev/null)
  line1=$(echo "$out" | head -1)
  len=$(vis_len "$line1")
  max=$(( w - 4 ))

  if (( len <= max )); then
    tag="  OK"
  else
    tag="OVER"
    (( failures++ ))
  fi

  elapsed=$(( $(_ms) - t0 ))
  s=$(printf '%s' "$line1" | strip_ansi)
  printf "W=%3d max=%3d len=%3d [%s] %5dms: %s\n" "$w" "$max" "$len" "$tag" "$elapsed" "$s"

  rm -f "$tmp" "$CLAUDE_DIR/.sl_cache_$sid" "$CLAUDE_DIR/.sl_compute_$sid" "$CLAUDE_DIR/.sl_mtime_$sid"
done

total_elapsed=$(( $(_ms) - total_start ))
count=22
avg=$(( total_elapsed / count ))
echo ""
printf "Cascade: %d widths in %dms (avg %dms)\n" "$count" "$total_elapsed" "$avg"

echo ""
echo "=== Cache timer format ==="
for case in "245:4m5s" "3304:55m4s" "300:5m0s" "59:59s"; do
  remain=${case%%:*}
  expect=${case#*:}
  m=$(( remain / 60 ))
  s=$(( remain % 60 ))
  if (( m > 0 )); then got="${m}m${s}s"; else got="${s}s"; fi
  if [ "$got" = "$expect" ]; then
    echo "Timer ${remain}s -> '${got}' expect '${expect}' [PASS]"
  else
    echo "Timer ${remain}s -> '${got}' expect '${expect}' [FAIL]"
    (( failures++ ))
  fi
done

echo ""
if (( failures == 0 )); then
  echo "All tests passed."
else
  echo "$failures failure(s)."
  exit 1
fi
