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
  if [[ ! "$s" =~ \|\ (cache\ )?[0-9]+m[0-9]+s\ \|\ 📁\  ]]; then
    echo "FAIL: cache must immediately precede folder at width $w"
    (( failures++ ))
  fi
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

# ── Workflow phase progress test ─────────────────────────
echo ""
echo "Workflow phase progress:"

wf_sid="test-wf-phases"
wf_session_dir="$CLAUDE_DIR/projects/test-wf-session/$wf_sid"
wf_transcript="$wf_session_dir.jsonl"
wf_subagents_dir="$wf_session_dir/subagents/workflows/wf_test123"
wf_script_dir="$wf_session_dir/workflows/scripts"

mkdir -p "$wf_subagents_dir" "$wf_script_dir"

cat > "$wf_script_dir/test-workflow-wf_test123.js" <<'SEOF'
export const meta = {
  name: 'test-workflow',
  description: 'Test workflow with two phases',
  phases: [
    { title: 'Find', detail: 'search agents' },
    { title: 'Verify', detail: 'verify agents' },
  ],
}
phase('Find')
const results = await parallel(items.map(d => () => agent(d.prompt, { phase: 'Find', schema: S })))
phase('Verify')
const verified = await parallel(toVerify.map(c => () => agent(c.prompt, { phase: 'Verify', schema: V })))
SEOF

cat > "$wf_subagents_dir/journal.jsonl" <<'JEOF'
{"type":"started","key":"k1","agentId":"agent-a1"}
{"type":"started","key":"k2","agentId":"agent-a2"}
{"type":"started","key":"k3","agentId":"agent-a3"}
{"type":"result","key":"k1","agentId":"agent-a1","result":{}}
{"type":"result","key":"k2","agentId":"agent-a2","result":{}}
{"type":"result","key":"k3","agentId":"agent-a3","result":{}}
{"type":"started","key":"k4","agentId":"agent-a4"}
{"type":"started","key":"k5","agentId":"agent-a5"}
{"type":"result","key":"k4","agentId":"agent-a4","result":{}}
JEOF

ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
for aid in a1 a2 a3 a4 a5; do
  echo '{"agentType":"workflow-subagent"}' > "$wf_subagents_dir/agent-${aid}.meta.json"
  printf '{"message":{"role":"user","content":"test"},"timestamp":"%s"}\n' "$ts" > "$wf_subagents_dir/agent-${aid}.jsonl"
  printf '{"message":{"role":"assistant","model":"claude-sonnet-4-6","usage":{"output_tokens":500},"content":"ok"},"timestamp":"%s"}\n' "$ts" >> "$wf_subagents_dir/agent-${aid}.jsonl"
done

touch "$wf_transcript"

wf_json=$(cat <<WEOF
{
  "model": {"display_name": "Opus 4.8"},
  "effort": {"level": "xhigh"},
  "context_window": {"used_percentage": 10, "context_window_size": 1000000},
  "workspace": {"project_dir": "/test/project"},
  "transcript_path": "$wf_transcript"
}
WEOF
)

rm -f "$CLAUDE_DIR/.sl_compute_$wf_sid" "$CLAUDE_DIR/.sl_agents_$wf_sid"

wf_tmp="$CLAUDE_DIR/.test_wf.sh"
sed "s/^WIDTH=[0-9]*/WIDTH=160/" "$SCRIPT" > "$wf_tmp"
chmod +x "$wf_tmp"

wf_out=$(echo "$wf_json" | bash "$wf_tmp" 2>/dev/null)

echo "Output lines:"
while IFS= read -r l; do
  echo "  $(printf '%s' "$l" | strip_ansi)"
done <<< "$wf_out"

has_wf=false has_find=false has_verify=false
while IFS= read -r l; do
  plain=$(printf '%s' "$l" | strip_ansi)
  echo "$plain" | grep -qE '(test-workflow|wf_test123).*agents' && has_wf=true
  echo "$plain" | grep -qE 'Find [0-9]+/[0-9]+' && has_find=true
  echo "$plain" | grep -qE 'Verify [0-9]+/[0-9]+' && has_verify=true
done <<< "$wf_out"

for pair in "Workflow line present:$has_wf" "Find phase shown:$has_find" "Verify phase shown:$has_verify"; do
  name=${pair%%:*}; val=${pair#*:}
  if [ "$val" = "true" ]; then
    echo "$name [PASS]"
  else
    echo "$name [FAIL]"
    (( failures++ ))
  fi
done

rm -f "$wf_tmp" "$CLAUDE_DIR/.sl_compute_$wf_sid" "$CLAUDE_DIR/.sl_agents_$wf_sid"
rm -rf "$CLAUDE_DIR/projects/test-wf-session" "$wf_transcript"

echo ""
if (( failures == 0 )); then
  echo "All tests passed."
else
  echo "$failures failure(s)."
  exit 1
fi
