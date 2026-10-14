#!/usr/bin/env bash

# Claude Code statusline — Bash version
# Two-tier refresh: full compute every N seconds, cheap ticks in between
# Adaptive agent refresh: full compute more often when agents are active

input=$(cat)

command -v jq &>/dev/null || { echo "jq required"; exit 0; }

# ── Tuning constants ────────────────────────────────────
# Reorder or omit main-row elements; collapse priority stays fixed.
SEGMENT_ORDER=(MODEL CACHE PROJECT DIFF SHELL CTX 5H 7D)
WIDTH=96            # terminal width (default 120)
OAUTH_TTL=60        # seconds between OAuth usage API calls
FULL_INTERVAL=10    # seconds between full recomputes (no agents)
AGENT_INTERVAL=5    # seconds between full recomputes (agents active)
REFRESH_INTERVAL=10 # match statusLine.refreshInterval in settings.json
SHOW_RESUME_LINE=true

fg() { printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"; }
RST=$'\033[0m'

C_MODEL=$(fg 113 172 255)
C_PROJ=$(fg 255 215 90)
C_ADD=$(fg 152 195 121)
C_DEL=$(fg 210 110 130)
C_GRAY=$(fg 170 170 176)
C_DIM=$(fg 100 100 115)
C_SEP=$(fg 60 60 80)
C_BAR=$(fg 170 170 176)
C_BAR_E=$(fg 100 100 108)
C_SHELL=$(fg 180 160 255)

SEP=" ${C_SEP}| "

pct_color() {
  local p=$(awk "BEGIN { printf \"%.0f\", ${1:-0} }")
  if   (( p >= 80 )); then fg 255 144 144
  elif (( p >= 60 )); then fg 255 184 120
  elif (( p >= 30 )); then fg 255 241 150
  else                     fg 185 255 164
  fi
}

rate_color() {
  local r=$(awk "BEGIN { r=${1:-0}; if(r<0)r=-r; printf \"%.0f\", r }")
  if   (( r >= 15 )); then fg 255 144 144
  elif (( r >= 10 )); then fg 255 184 120
  elif (( r >= 5 ));  then fg 255 241 150
  else                     fg 185 255 164
  fi
}

agent_rate_color() {
  local r=$(awk "BEGIN { printf \"%.0f\", ${1:-0} }")
  if   (( r >= 10000 )); then fg 255 144 144
  elif (( r >= 5000 ));  then fg 255 184 120
  elif (( r >= 2000 ));  then fg 255 241 150
  else                        fg 185 255 164
  fi
}

make_bar() {
  local pct=${1:-0} w=${2:-8}
  local f=$(awk "BEGIN { v=$pct*$w/100; if(v>$w)v=$w; if(v<0)v=0; printf \"%.0f\", v }")
  local e=$(( w - f ))
  local out="${C_BAR}"
  for ((i=0; i<f; i++)); do out+="▓"; done
  out+="${C_BAR_E}"
  for ((i=0; i<e; i++)); do out+="░"; done
  printf '%s' "$out"
}

vis_len() {
  local s=$1 ansi=$'\033['
  while [[ $s == *"$ansi"*m* ]]; do
    local rest=${s#*"$ansi"}
    s=${s%%"$ansi"*}${rest#*m}
  done
  # Count UTF-8 code points even in Git Bash's C locale; these emoji occupy two columns.
  local LC_ALL=C green white folder extra
  green=${s//🟢/}; white=${s//⚪/}; folder=${s//📁/}
  extra=$(( (${#s} - ${#green}) / 4 + (${#s} - ${#white}) / 3 + (${#s} - ${#folder}) / 4 ))
  s=${s//[$'\200'-$'\277']/}
  printf '%d' "$(( ${#s} + extra ))"
}

fmt_tok() {
  awk "BEGIN {
    n = ${1:-0}
    if (n >= 1000000) printf \"%.1fM\", n/1000000
    else if (n >= 1000) printf \"%.0fk\", n/1000
    else printf \"0k\"
  }"
}

round_ratio() {
  local d=$2 q=$(( $1 / $2 )) r=$(( $1 % $2 ))
  REPLY=$(( q + (r * 2 > d || (r * 2 == d && q % 2)) ))
}

pid_alive() {
  [[ $1 =~ ^[0-9]+$ ]] && (( $1 > 0 )) || return 1
  if [[ $OSTYPE == msys* || $OSTYPE == cygwin* ]]; then
    # Session files contain native Windows PIDs, which kill -0 can't resolve.
    if [ -z "${_windows_pids+x}" ]; then
      _windows_pids="$(ps -W 2>/dev/null | awk 'NR > 1 { printf " %s %s", $1, $4 }') "
    fi
    [[ $_windows_pids == *" $1 "* ]]
  else
    kill -0 "$1" 2>/dev/null
  fi
}

# ── Extract fields always needed ─────────────────────────
mapfile -d '' -t _fields < <(printf '%s' "$input" | jq -sj 'select(length == 1) | .[0] | select(type == "object") |
  [.transcript_path // "", .workspace.project_dir // "", .model.display_name // "",
   .effort.level // "", .context_window.used_percentage // 0,
   .context_window.context_window_size // 200000,
   .rate_limits.five_hour.used_percentage // "", .rate_limits.seven_day.used_percentage // "",
   .session_id // "", .cost.total_lines_added // 0, .cost.total_lines_removed // 0]
  | .[] | tostring, "\u0000"' 2>/dev/null)
(( ${#_fields[@]} == 11 )) || exit 0
TRANSCRIPT=${_fields[0]//\\//} PROJECT_DIR=${_fields[1]}
MODEL=${_fields[2]} EFFORT=${_fields[3]} CTX_PCT=${_fields[4]} CTX_SIZE=${_fields[5]}
FIVE_H=${_fields[6]} SEVEN_D=${_fields[7]} _target_sid=${_fields[8]}
_input_add=${_fields[9]} _input_del=${_fields[10]}

_now=$(date +%s)

# ── Session ID for per-session isolation ─────────────────
SESSION_ID=""
if [ -n "$TRANSCRIPT" ]; then
  SESSION_ID=$(basename "$TRANSCRIPT" .jsonl)
fi
COMPUTE_CACHE="$HOME/.claude/.sl_compute_${SESSION_ID}"

# ── Resolve this session's PID from session files ────────
_my_pid=0
[ -z "$_target_sid" ] && _target_sid="$SESSION_ID"
RESUME_SESSION_ID=$_target_sid
if [ -n "$_target_sid" ]; then
  for _sf in "$HOME/.claude/sessions/"*.json; do
    [ -f "$_sf" ] || continue
    _sf_pid=$(jq -r --arg sid "$_target_sid" 'select(.sessionId == $sid) | .pid // 0' "$_sf" 2>/dev/null)
    if [ -n "$_sf_pid" ]; then
      _my_pid=$_sf_pid
      break
    fi
  done
fi

# ── Two-tier: decide full vs cheap tick ──────────────────
_do_full=true
_cc='{}'
if [ -n "$SESSION_ID" ] && [ -f "$COMPUTE_CACHE" ]; then
  _cc=$(cat "$COMPUTE_CACHE" 2>/dev/null)
fi
mapfile -d '' -t _cached < <(printf '%s' "$_cc" | jq -j '
  [.computed_at // 0, .has_agents // false, .lines_add // 0, .lines_del // 0,
   .branch // "", .in_git // false, .cache_epoch // 0, .cache_ttl // 300,
   .shell_epoch // 0, .shell_desc // "", .shell_count // 0,
   .active_dir // "", .active_branch // ""],
  ((.agents // [])[] | with_entries(.key |= ascii_downcase) |
   [.short // "agent", .tokens // 0, .rate // "", .model // "", .workflow // "",
    .subcount // 0, ((.phases // []) | if type == "string" then fromjson else . end
      | map(with_entries(.key |= ascii_downcase)
        | {t: (.t // .title), d: (.d // .done), n: (.n // .total)}) | tojson)])
  | .[] | tostring, "\u0000"' 2>/dev/null)
_cc_at=${_cached[0]:-0} _cc_agents=${_cached[1]:-false}
LINES_ADD=${_cached[2]:-0} LINES_DEL=${_cached[3]:-0}
BRANCH=${_cached[4]} IN_GIT=${_cached[5]:-false}
CACHE_EPOCH=${_cached[6]:-0} CACHE_TTL=${_cached[7]:-300}
SHELL_EPOCH=${_cached[8]:-0} SHELL_DESC=${_cached[9]} SHELL_COUNT=${_cached[10]:-0}
ACTIVE_DIR=${_cached[11]} ACTIVE_BRANCH=${_cached[12]}
_ac=0; _a_descs=() _a_toks=() _a_rates=() _a_models=() _a_workflows=() _a_subcounts=() _a_phases=()
for (( _i=13; _i<${#_cached[@]}; _i+=7 )); do
  _a_descs+=("${_cached[_i]}") _a_toks+=("${_cached[_i+1]}") _a_rates+=("${_cached[_i+2]}")
  _a_models+=("${_cached[_i+3]}") _a_workflows+=("${_cached[_i+4]}")
  _a_subcounts+=("${_cached[_i+5]}") _a_phases+=("${_cached[_i+6]}")
  (( _ac++ ))
done
if (( _cc_at > 0 )); then
  _cc_age=$(( _now - _cc_at ))
  if [ "$_cc_agents" = "true" ]; then
    _interval=$AGENT_INTERVAL
  else
    _interval=$FULL_INTERVAL
  fi
  if (( _cc_age < _interval )); then
    _do_full=false
  fi
fi

# ── 5h rate-of-change tracking ───────────────────────────
RATE_FILE="$HOME/.claude/.statusline_rate_history"
RATE_LAST_WRITE="$HOME/.claude/.sl_rate_last_write"

_calc_rate() {
  [ -f "$RATE_FILE" ] || return
  awk -v now="$_now" -v pct="$1" '$1 >= now - 1800 {
    dt = now - $1
    if (dt >= 120) printf "%.0f", (pct - $2) / (dt / 3600.0)
    exit
  }' "$RATE_FILE" 2>/dev/null
}

# ── OAuth usage (only when CC doesn't provide rate_limits) ──
USAGE_CACHE="$HOME/.claude/.statusline_usage_cache"

if [ -z "$FIVE_H" ]; then
  OAUTH_OWNER="$HOME/.claude/.sl_oauth_owner"
  OAUTH_LAST_ATTEMPT="$HOME/.claude/.sl_oauth_last_attempt"

  _is_owner=false
  if (( _my_pid > 0 )); then
    if [ -f "$OAUTH_OWNER" ]; then
      _owner_pid=$(cat "$OAUTH_OWNER" 2>/dev/null | tr -d '[:space:]')
      if [ "$_owner_pid" = "$_my_pid" ]; then
        _is_owner=true
      elif ! pid_alive "$_owner_pid"; then
        echo -n "$_my_pid" > "$OAUTH_OWNER"
        _is_owner=true
      fi
    else
      echo -n "$_my_pid" > "$OAUTH_OWNER"
      _is_owner=true
    fi
  fi

  if $_is_owner; then
    _do_oauth=false
    if [ ! -f "$USAGE_CACHE" ]; then
      _do_oauth=true
    else
      _fetched_at=$(jq -r '.fetched_at // empty' "$USAGE_CACHE" 2>/dev/null)
      if [ -z "$_fetched_at" ]; then
        _do_oauth=true
      else
        _cache_age=$(( _now - _fetched_at ))
        if (( _cache_age > OAUTH_TTL )); then
          _do_oauth=true
        fi
      fi
    fi

    if $_do_oauth && [ -f "$OAUTH_LAST_ATTEMPT" ]; then
      _last_attempt=$(cat "$OAUTH_LAST_ATTEMPT" 2>/dev/null | tr -d '[:space:]')
      if [ -n "$_last_attempt" ] && (( (_now - _last_attempt) < OAUTH_TTL )); then
        _do_oauth=false
      fi
    fi

    if $_do_oauth; then
      echo -n "$_now" > "$OAUTH_LAST_ATTEMPT"
      _creds="$HOME/.claude/.credentials.json"
      if [ -f "$_creds" ]; then
        _tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$_creds" 2>/dev/null)
        if [ -n "$_tok" ]; then
          # The fetch must finish before this statusline process exits.
          {
            _resp=$(curl -s -m 3 -H "Authorization: Bearer $_tok" \
              "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
            if [ -n "$_resp" ]; then
              echo "$_resp" | jq --argjson t "$(date +%s)" '{
                five_hour:  (.five_hour.utilization  // null),
                seven_day:  (.seven_day.utilization  // null),
                fetched_at: $t
              }' > "$USAGE_CACHE" 2>/dev/null
            fi
          }
        fi
      fi
    fi
  fi

  if [ -f "$USAGE_CACHE" ]; then
    mapfile -d '' -t _usage < <(jq -j '[.five_hour // "", .seven_day // ""] | .[] | tostring, "\u0000"' "$USAGE_CACHE" 2>/dev/null)
    FIVE_H=${_usage[0]} SEVEN_D=${_usage[1]}
  fi
fi

# Record rate sample (at most once per OAUTH_TTL)
if [ -n "$FIVE_H" ]; then
  _write_rate=true
  if [ -f "$RATE_LAST_WRITE" ]; then
    _lw=$(cat "$RATE_LAST_WRITE" 2>/dev/null | tr -d '[:space:]')
    [ -n "$_lw" ] && (( (_now - _lw) < OAUTH_TTL )) && _write_rate=false
  fi
  if $_write_rate; then
    echo -n "$_now" > "$RATE_LAST_WRITE"
    echo "$_now $FIVE_H" >> "$RATE_FILE"
    _cutoff=$(( _now - 3600 ))
    if [ -f "$RATE_FILE" ]; then
      awk -v c="$_cutoff" '$1 >= c' "$RATE_FILE" > "${RATE_FILE}.tmp" && mv "${RATE_FILE}.tmp" "$RATE_FILE"
    fi
  fi
fi

_write_compute_cache() {
  {
    printf '%s\0' "$_now" "$LINES_ADD" "$LINES_DEL" "$BRANCH" "$IN_GIT" \
      "$CACHE_EPOCH" "$CACHE_TTL" "$SHELL_EPOCH" "$SHELL_DESC" "$SHELL_COUNT" "$ACTIVE_DIR" "$ACTIVE_BRANCH"
    for (( _i=0; _i<_ac; _i++ )); do
      printf '%s\0' "${_a_descs[_i]}" "${_a_toks[_i]}" "${_a_rates[_i]}" "${_a_models[_i]}" \
        "${_a_workflows[_i]}" "${_a_subcounts[_i]}" "${_a_phases[_i]}"
    done
  } | jq -Rs '
    split("\u0000")[:-1] | . as $v |
    {computed_at: ($v[0]|tonumber), lines_add: ($v[1]|tonumber), lines_del: ($v[2]|tonumber),
     branch: $v[3], in_git: ($v[4] == "true"), cache_epoch: ($v[5]|tonumber), cache_ttl: ($v[6]|tonumber),
     shell_epoch: ($v[7]|tonumber), shell_desc: $v[8], shell_count: ($v[9]|tonumber),
     active_dir: $v[10], active_branch: $v[11], has_agents: (($v|length) > 12),
     agents: [range(12; $v|length; 7) as $i |
       {Short: $v[$i], Tokens: ($v[$i+1]|tonumber), Rate: ($v[$i+2]|tonumber? // null),
        Model: $v[$i+3], Workflow: $v[$i+4], SubCount: ($v[$i+5]|tonumber),
        Phases: ($v[$i+6]|fromjson|map({Title: .t, Done: .d, Total: .n}))}]}
  ' > "$COMPUTE_CACHE"
}

if $_do_full; then
  # ══════════════════════════════════════════════════════
  # FULL COMPUTE — transcript parsing, git, agents
  # ══════════════════════════════════════════════════════

  # ── GC stale per-session files (runs at most once per 5 min) ──
  _gc_marker="$HOME/.claude/.sl_last_gc"
  _do_gc=false
  if [ ! -f "$_gc_marker" ]; then
    _do_gc=true
  else
    _gc_age=$(( _now - $(cat "$_gc_marker" 2>/dev/null | tr -d '[:space:]') ))
    (( _gc_age >= 300 )) && _do_gc=true
  fi
  if $_do_gc; then
    echo -n "$_now" > "$_gc_marker"
    _live_sids=""
    for _sf in "$HOME/.claude/sessions/"*.json; do
      [ -f "$_sf" ] || continue
      _spid=$(jq -r '.pid // empty' "$_sf" 2>/dev/null)
      [ -n "$_spid" ] && pid_alive "$_spid" && \
        _live_sids="$_live_sids $(jq -r '.sessionId // empty' "$_sf" 2>/dev/null)"
    done
    for _stale in "$HOME/.claude/"\.sl_compute_* "$HOME/.claude/"\.sl_cache_* \
                  "$HOME/.claude/"\.sl_mtime_* "$HOME/.claude/"\.sl_agents_*; do
      [ -f "$_stale" ] || continue
      _uuid="${_stale##*_}"
      case "$_uuid" in [a-f0-9]*-[a-f0-9]*-[a-f0-9]*-[a-f0-9]*-[a-f0-9]*)
        case " $_live_sids " in *" $_uuid "*) ;; *) rm -f "$_stale" ;; esac
      ;; esac
    done
  fi

  LINES_ADD=$_input_add LINES_DEL=$_input_del

  # Write partial cache immediately -- breaks the death loop
  _write_compute_cache

  # ── Cache countdown state from transcript ──────────────
  CACHE_STATE="$HOME/.claude/.sl_cache_${SESSION_ID}"
  CACHE_MTIME="$HOME/.claude/.sl_mtime_${SESSION_ID}"

  if [ -f "$TRANSCRIPT" ]; then
    _t_mtime=$(stat -c %y "$TRANSCRIPT" 2>/dev/null || echo 0)
    _last_mtime=$(cat "$CACHE_MTIME" 2>/dev/null || echo 0)
    if [ "$_t_mtime" != "$_last_mtime" ]; then
      # Parse bounded tails in one jq pass; ignore a partial first or last record.
      mapfile -d '' -t _tail < <(tail -c 65536 "$TRANSCRIPT" 2>/dev/null | jq -Rjn --arg project "$PROJECT_DIR" '
        [inputs | fromjson?] as $entries |
        ([$entries[] | select(((.message.usage.cache_read_input_tokens // 0) > 0) or
          ((.message.usage.cache_creation_input_tokens // 0) > 0))] | last) as $cache |
        ([$entries[] | select(.gitBranch != null and .gitBranch != "" and .cwd != null and .cwd != $project)] | last) as $repo |
        [$cache.timestamp // "", (if ($cache.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) > 0
          then 3600 else 300 end), $repo.cwd // "", $repo.gitBranch // ""]
        | .[] | tostring, "\u0000"')
      ACTIVE_DIR=${_tail[2]} ACTIVE_BRANCH=${_tail[3]}
      if [ -n "${_tail[0]}" ]; then
        ts=$(date -d "${_tail[0]}" +%s 2>/dev/null)
        if [ -n "$ts" ]; then
          CACHE_EPOCH=$ts CACHE_TTL=${_tail[1]}
          printf '%s %s' "$CACHE_EPOCH" "$CACHE_TTL" > "$CACHE_STATE"
        fi
      fi
      echo "$_t_mtime" > "$CACHE_MTIME"
    fi
  fi

  if [ "$CACHE_EPOCH" = "0" ] && [ -f "$CACHE_STATE" ]; then
    read -r CACHE_EPOCH CACHE_TTL < "$CACHE_STATE" 2>/dev/null
    CACHE_EPOCH=${CACHE_EPOCH:-0}
    CACHE_TTL=${CACHE_TTL:-300}
  fi

  # ── In-flight shell calls ──────────────────────────────
  SHELL_EPOCH=0 SHELL_DESC="" SHELL_COUNT=0
  if [ -f "$TRANSCRIPT" ]; then
    mapfile -d '' -t _shell < <(tail -c 16384 "$TRANSCRIPT" 2>/dev/null | jq -Rjn '
      [inputs | fromjson?] | reverse |
      reduce .[] as $e ({done: {}, calls: [], found: false};
        if .found then .
        elif $e.message.role == "user" and ($e.message.content | type) == "array" then
          reduce ($e.message.content[] | select(.type == "tool_result")) as $b (.; .done[$b.tool_use_id] = true)
        elif $e.message.role == "assistant" and $e.message.content then
          .found = true | .done as $done |
          .timestamp = $e.timestamp |
          .calls = [$e.message.content | arrays | .[] |
            select(.type == "tool_use" and (.name == "Bash" or .name == "PowerShell") and ($done[.id] != true))]
        else . end) |
      [if (.calls|length) > 0 then .timestamp else "" end,
       .calls[0].input.description // "", (.calls|length)] | .[] | tostring, "\u0000"')
    if [ -n "${_shell[0]}" ]; then
      SHELL_EPOCH=$(date -d "${_shell[0]}" +%s 2>/dev/null) SHELL_DESC=${_shell[1]} SHELL_COUNT=${_shell[2]}
      SHELL_EPOCH=${SHELL_EPOCH:-0}
    fi
  fi

  # ── Git branch ─────────────────────────────────────────
  if [ -n "$PROJECT_DIR" ]; then
    BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$BRANCH" ]; then IN_GIT=true; else BRANCH=""; IN_GIT=false; fi
  fi

  if [ -n "$ACTIVE_BRANCH" ] && [ -n "$ACTIVE_DIR" ]; then
    BRANCH=$ACTIVE_BRANCH IN_GIT=true
  fi

  # ── Active agents (incremental parsing) ────────────────
  _ac=0
  _a_descs=() _a_toks=() _a_rates=() _a_models=() _a_workflows=() _a_subcounts=() _a_phases=()
  _sa_dir="${TRANSCRIPT%.jsonl}/subagents"
  _agent_cache="$HOME/.claude/.sl_agents_${SESSION_ID}"
  if [ -n "$TRANSCRIPT" ] && [ -d "$_sa_dir" ]; then
    declare -A _sizes=() _tokens=() _models=() _firsts=()
    while IFS= read -r -d '' _key && IFS= read -r -d '' _size && IFS= read -r -d '' _tok &&
          IFS= read -r -d '' _model && IFS= read -r -d '' _first; do
      _sizes["$_key"]=$_size _tokens["$_key"]=$_tok _models["$_key"]=$_model _firsts["$_key"]=$_first
    done < <(jq -j 'to_entries[] | [.key, .value.size, .value.tokens, .value.model, .value.first_ts]
      | .[] | tostring, "\u0000"' "$_agent_cache" 2>/dev/null)

    _agent_stats() {
      local file=$1 key=$2 size=$3 offset=${_sizes[$2]:-0} prior=0 first=0 model=""
      if (( size == offset && offset > 0 )); then
        _otok=${_tokens[$key]} _model=${_models[$key]} _first_ts_epoch=${_firsts[$key]}
      else
        if (( size > offset && offset > 0 )); then
          prior=${_tokens[$key]} first=${_firsts[$key]} model=${_models[$key]}
        else
          offset=0
        fi
        local stats=() iso
        mapfile -d '' -t stats < <(tail -c +$(( offset + 1 )) "$file" 2>/dev/null | jq -Rjn \
          --argjson prior "$prior" --arg model "$model" '
          reduce (inputs | fromjson?) as $e ({tokens: $prior, model: $model, first: ""};
            .tokens += ($e.message.usage.output_tokens // 0) |
            if .model == "" then .model = ($e.message.model // "") else . end |
            if .first == "" then .first = ($e.timestamp // "") else . end) |
          [.tokens, .model, .first] | .[] | tostring, "\u0000"')
        _otok=${stats[0]:-0} _model=${stats[1]} _first_ts_epoch=$first
        _model=${_model#claude-}; _model=${_model%%-[0-9]*}; _model=${_model^}
        if (( first == 0 )) && [ -n "${stats[2]}" ]; then
          _first_ts_epoch=$(date -d "${stats[2]}" +%s 2>/dev/null)
          _first_ts_epoch=${_first_ts_epoch:-0}
        fi
        _sizes["$key"]=$size _tokens["$key"]=$_otok _models["$key"]=$_model _firsts["$key"]=$_first_ts_epoch
      fi
      _arate=""
      if (( _first_ts_epoch > 0 && _now - _first_ts_epoch >= 10 )); then
        round_ratio "$(( _otok * 60 ))" "$(( _now - _first_ts_epoch ))"
        _arate=$REPLY
      fi
    }

    for _mf in "$_sa_dir"/agent-*.meta.json; do
      [ -f "$_mf" ] || continue
      _jf="${_mf%.meta.json}.jsonl"
      read -r _size _mtime < <(stat -c '%s %Y' "$_jf" 2>/dev/null)
      [ -n "$_mtime" ] || continue
      (( _now - _mtime > 120 )) && continue
      _short=$(jq -r '
        (.description | if . == null or . == "" then "agent" else . end |
          [splits("\\s+") | select(length > 0)][:3]) |
        ["a","an","the","and","or","but","not","nor","for","yet","so",
         "with","from","except","into","about","after","before","during","without"] as $stop |
        until(length <= 1 or ((.[-1] | ascii_downcase) as $word | ($stop | index($word)) == null); .[:-1]) |
        join(" ")' "$_mf" 2>/dev/null) || continue
      _agent_stats "$_jf" "${_jf##*/}" "$_size"
      _a_descs+=("$_short") _a_toks+=("$_otok") _a_rates+=("$_arate") _a_models+=("$_model")
      _a_workflows+=("") _a_subcounts+=(0) _a_phases+=("[]")
    done

    _session_dir="${TRANSCRIPT%.jsonl}"
    _script_dir="$_session_dir/workflows/scripts"
    for _wf_folder in "$_sa_dir"/workflows/wf_*; do
      [ -d "$_wf_folder" ] || continue
      _wf_id=${_wf_folder##*/} _wf_script=""
      _wf_total_tok=0 _wf_first_ts=0 _wf_last_write=0 _wf_sub_count=0 _wf_model=""
      for _wjf in "$_wf_folder"/agent-*.jsonl; do
        [ -f "$_wjf" ] || continue
        read -r _size _mtime < <(stat -c '%s %Y' "$_wjf" 2>/dev/null)
        (( _mtime > _wf_last_write )) && _wf_last_write=$_mtime
        (( _wf_sub_count++ ))
        _agent_stats "$_wjf" "${_wf_id}/${_wjf##*/}" "$_size"
        (( _wf_total_tok += _otok ))
        [ -z "$_wf_model" ] && _wf_model=$_model
        if (( _first_ts_epoch > 0 && (_wf_first_ts == 0 || _first_ts_epoch < _wf_first_ts) )); then
          _wf_first_ts=$_first_ts_epoch
        fi
      done
      (( _wf_sub_count == 0 || _now - _wf_last_write > 120 )) && continue
      _wf_name=$_wf_id
      for _match in "$_script_dir"/*-"${_wf_id}.js"; do
        [ -f "$_match" ] || continue
        _wf_script=$_match _wf_name=${_match##*/}
        _wf_name=${_wf_name%-"${_wf_id}.js"}
        break
      done
      # State and journal are parsed once per workflow, including every phase.
      mapfile -d '' -t _wf_info < <(
        { printf '%s\0' "$(cat "$_session_dir/workflows/${_wf_id}.json" 2>/dev/null)" \
            "$(cat "$_wf_script" 2>/dev/null)" "$(cat "$_wf_folder/journal.jsonl" 2>/dev/null)"; } |
        jq -Rjs --arg name "$_wf_name" '
          split("\u0000") as $v | (try ($v[0]|fromjson) catch {}) as $state |
          (if ($state.workflowName // "") != "" then $state.workflowName else $name end),
          (if ($state.phases|length) > 0 and ($state.workflowProgress|length) > 0 then
            [$state.phases[].title as $title |
              [$state.workflowProgress[] | select(.type == "workflow_agent" and .phaseTitle == $title)] as $agents |
              {t: $title, n: ($agents|length), d: ([$agents[]|select(.state == "done")]|length)}]
          else
            ([try ($v[1] | capture("phases\\s*:\\s*\\[(?<ph>.*?)\\]"; "m").ph |
              scan("title\\s*:\\s*[\"\u0027]([^\"\u0027]+)[\"\u0027]") | .[0]) catch empty]) as $titles |
            if ($titles|length) == 0 then [] else
              reduce ($v[2]|split("\n")[]|fromjson?) as $e
                ({idx: 0, seen: false, agents: {}, done: {}, counts: {}};
                if $e.type == "started" and $e.agentId then
                  if .seen and .idx < ($titles|length) - 1 then .idx += 1 | .seen = false else . end |
                  .agents[$e.agentId] = $titles[.idx] | .counts[$titles[.idx]] += 1
                elif $e.type == "result" then
                  .seen = true | if $e.agentId then .done[$e.agentId] = true else . end
                else . end) as $journal |
              [$titles[] as $t | {t: $t, n: ($journal.counts[$t] // 0),
                d: ([$journal.done|keys[]|select($journal.agents[.] == $t)]|length)}]
            end
          end | tojson) | ., "\u0000"')
      _wf_rate=""
      if (( _wf_first_ts > 0 && _now - _wf_first_ts >= 10 )); then
        round_ratio "$(( _wf_total_tok * 60 ))" "$(( _now - _wf_first_ts ))"
        _wf_rate=$REPLY
      fi
      _a_descs+=("${_wf_info[0]}") _a_toks+=("$_wf_total_tok") _a_rates+=("$_wf_rate") _a_models+=("$_wf_model")
      _a_workflows+=("$_wf_id") _a_subcounts+=("$_wf_sub_count") _a_phases+=("${_wf_info[1]:-[]}")
    done
    _ac=${#_a_descs[@]}
    if (( ${#_sizes[@]} > 0 )); then
      {
        for _key in "${!_sizes[@]}"; do
          printf '%s\0' "$_key" "${_sizes[$_key]}" "${_tokens[$_key]}" "${_models[$_key]}" "${_firsts[$_key]}"
        done
      } | jq -Rs 'split("\u0000")[:-1] | . as $v | [range(0; length; 5) as $i |
        {key: $v[$i], value: {size: ($v[$i+1]|tonumber), tokens: ($v[$i+2]|tonumber),
          model: $v[$i+3], first_ts: ($v[$i+4]|tonumber)}}] | from_entries' > "$_agent_cache"
    fi
  fi

  # ── Write full cache (overwrites partial) ──────────────
  _write_compute_cache

fi

# ── Cache countdown (computed from epoch every tick) ─────
CACHE_REMAINING=""
CACHE_ELAPSED_PCT=0
if (( CACHE_EPOCH > 0 )); then
  _remain=$(( CACHE_TTL - (_now - CACHE_EPOCH) ))
  if (( _remain > 0 )); then
    _min=$(( _remain / 60 )) _sec=$(( _remain % 60 ))
    if (( _min > 0 )); then
      CACHE_REMAINING="${_min}m${_sec}s"
    else
      CACHE_REMAINING="${_sec}s"
    fi
    round_ratio "$(( _remain * 100 ))" "$CACHE_TTL"
    CACHE_ELAPSED_PCT=$(( 100 - REPLY ))
  fi
fi

# ── Build output ─────────────────────────────────────────
SEG_MODEL=""
CTX_INT=${CTX_SIZE%.*}

if [ -n "$MODEL" ]; then
  MODEL_STR="${MODEL/ (1M context)/}"
  SEG_MODEL+="${C_MODEL}${MODEL_STR}"
  CTX_INT=$(awk "BEGIN { printf \"%.0f\", $CTX_SIZE }")
  (( CTX_INT >= 1000000 )) && SEG_MODEL+=" ${C_DIM}[1M]"
  [ -n "$EFFORT" ] && SEG_MODEL+=" ${C_GRAY}${EFFORT}"
fi

SEG_PROJECT=""
DISPLAY_DIR=$PROJECT_DIR
[ -n "$ACTIVE_BRANCH" ] && [ -n "$ACTIVE_DIR" ] && DISPLAY_DIR=$ACTIVE_DIR
DISPLAY_DIR=${DISPLAY_DIR//\\//}; DISPLAY_DIR=${DISPLAY_DIR%/}
PROJ=${DISPLAY_DIR##*/}
if [ -n "$PROJ" ]; then
  if [ "$IN_GIT" = "true" ]; then
    SEG_PROJECT="${C_PROJ}🟢 📁 ${PROJ}"
    if [[ -n "$BRANCH" && "$BRANCH" != main && "$BRANCH" != master ]]; then
      SEG_PROJECT+=" ${C_GRAY}(${BRANCH})"
    fi
  else
    SEG_PROJECT="${C_PROJ}⚪ 📁 ${PROJ}"
  fi
fi

SEG_DIFF=""
LADD=$(awk "BEGIN { print int(${LINES_ADD:-0}) }")
LDEL=$(awk "BEGIN { print int(${LINES_DEL:-0}) }")
if [ "$IN_GIT" = "true" ] && (( LADD > 0 || LDEL > 0 )); then
  SEG_DIFF="${C_ADD}+${LADD}${C_DEL}/-${LDEL}"
fi

SEG_SHELL="" SHELL_SHORT=""
if (( SHELL_EPOCH > 0 && SHELL_COUNT > 0 && _now - SHELL_EPOCH >= 3 )); then
  _shell_sec=$(( _now - SHELL_EPOCH ))
  if (( _shell_sec >= 60 )); then
    _shell_elapsed="$(( _shell_sec / 60 ))m$(( _shell_sec % 60 ))s"
  else
    _shell_elapsed="${_shell_sec}s"
  fi
  SHELL_SHORT="${C_SHELL}⏳ ${_shell_elapsed}"
  (( SHELL_COUNT > 1 )) && SHELL_SHORT+=" ${C_DIM}×${SHELL_COUNT}"
  SEG_SHELL=$SHELL_SHORT
  _desc_trunc=${SHELL_DESC//$'\n'/ }; _desc_trunc=${_desc_trunc//$'\r'/ }
  if (( ${#_desc_trunc} > 30 )); then _desc_trunc="${_desc_trunc:0:27}..."; fi
  [ -n "$_desc_trunc" ] && SEG_SHELL+=" ${C_DIM}${_desc_trunc}"
fi

CTX_P=$(awk "BEGIN { printf \"%.0f\", $CTX_PCT }")
CTX_USED=$(awk "BEGIN { printf \"%.0f\", $CTX_SIZE * $CTX_PCT / 100 }")
U_FMT=$(fmt_tok "${CTX_USED}")
SEG_CTX="${C_GRAY}${U_FMT} $(make_bar "$CTX_PCT" 8) $(pct_color "$CTX_PCT")${CTX_P}%"
SEG_CTX_SHORT="${C_GRAY}${U_FMT} $(pct_color "$CTX_PCT")${CTX_P}%"

SEG_5H="" SEG_5H_MID="" SEG_5H_SHORT=""
if [ -n "$FIVE_H" ]; then
  P5=$(awk "BEGIN { printf \"%.0f\", $FIVE_H }")
  RATE=$(_calc_rate "$FIVE_H")
  RATE_STR=""
  if [ -n "$RATE" ] && [ "$RATE" != "0" ]; then
    ARROW="↑" ; R_ABS="$RATE"
    if awk "BEGIN { exit ($RATE < 0) ? 0 : 1 }"; then
      ARROW="↓"
      R_ABS=$(awk "BEGIN { printf \"%.0f\", -1*$RATE }")
    fi
    RATE_STR=" ${C_GRAY}($(rate_color "$R_ABS")${ARROW}${R_ABS}%${C_GRAY}/hr)"
  fi
  SEG_5H="${C_GRAY}5h $(make_bar "$FIVE_H" 8) $(pct_color "$FIVE_H")${P5}%${RATE_STR}"
  SEG_5H_MID="${C_GRAY}5h $(make_bar "$FIVE_H" 8) $(pct_color "$FIVE_H")${P5}%"
  SEG_5H_SHORT="${C_GRAY}5h: $(pct_color "$FIVE_H")${P5}%"
fi

SEG_7D="" SEG_7D_SHORT=""
if [ -n "$SEVEN_D" ]; then
  PW=$(awk "BEGIN { printf \"%.0f\", $SEVEN_D }")
  SEG_7D="${C_GRAY}7d $(make_bar "$SEVEN_D" 8) $(pct_color "$SEVEN_D")${PW}%"
  SEG_7D_SHORT="${C_GRAY}7d: $(pct_color "$SEVEN_D")${PW}%"
fi

SEG_CACHE=""
if [ -n "$CACHE_REMAINING" ]; then
  SEG_CACHE="${C_GRAY}cache $(pct_color "$CACHE_ELAPSED_PCT")${CACHE_REMAINING}"
fi

MAX_W=$(( WIDTH - 4 ))
_cur_bar=8
_rate_dropped=false

_compose() {
  OUT=""
  local key name value
  for key in "${SEGMENT_ORDER[@]}"; do
    name="SEG_$key"
    value=${!name}
    [ -n "$value" ] || continue
    [ -n "$OUT" ] && OUT+="$SEP"
    OUT+="$value"
  done
}

_over() { _compose; local l=$(vis_len "$OUT"); (( l > MAX_W )); }

_rebuild_bars() {
  local _bw=$_cur_bar
  SEG_MODEL=""
  if [ -n "$MODEL" ]; then
    SEG_MODEL+="${C_MODEL}${MODEL_STR}"
    (( CTX_INT >= 1000000 )) && ! $_1m_removed && SEG_MODEL+=" ${C_DIM}[1M]"
    [ -n "$EFFORT" ] && SEG_MODEL+=" ${C_GRAY}${EFFORT}"
  fi
  SEG_CTX="${C_GRAY}${U_FMT} $(make_bar "$CTX_PCT" "$_bw") $(pct_color "$CTX_PCT")${CTX_P}%"

  if [ -n "$FIVE_H" ] && [ -n "$SEG_5H" ]; then
    if $_rate_dropped; then
      SEG_5H="${C_GRAY}5h $(make_bar "$FIVE_H" "$_bw") $(pct_color "$FIVE_H")${P5}%"
    else
      SEG_5H="${C_GRAY}5h $(make_bar "$FIVE_H" "$_bw") $(pct_color "$FIVE_H")${P5}%${RATE_STR}"
    fi
  fi
  if [ -n "$SEVEN_D" ] && [ -n "$SEG_7D" ]; then
    SEG_7D="${C_GRAY}7d $(make_bar "$SEVEN_D" "$_bw") $(pct_color "$SEVEN_D")${PW}%"
  fi
}

_1m_removed=false

# Collapse cascade
# 1. cache label removed
if _over && [ -n "$SEG_CACHE" ]; then
  SEG_CACHE="$(pct_color "$CACHE_ELAPSED_PCT")${CACHE_REMAINING}"
fi
# 2. Shell description removed
if _over && [ -n "$SEG_SHELL" ]; then SEG_SHELL=$SHELL_SHORT; fi
# 3. [1M] removed
if _over && (( CTX_INT >= 1000000 )); then
  _1m_removed=true
  _rebuild_bars
fi
# 4-7. bars squeeze 8->7->6->5->4
for _target_bw in 7 6 5 4; do
  if _over && (( _cur_bar > _target_bw )); then
    _cur_bar=$_target_bw
    _rebuild_bars
  fi
done
# 8. 5h rate drop
if _over && [ -n "$SEG_5H" ] && [ -n "$FIVE_H" ]; then
  _rate_dropped=true
  SEG_5H="${C_GRAY}5h $(make_bar "$FIVE_H" "$_cur_bar") $(pct_color "$FIVE_H")${P5}%"
fi
# 9. All bars become text together
if _over; then
  SEG_CTX=$SEG_CTX_SHORT SEG_5H=$SEG_5H_SHORT SEG_7D=$SEG_7D_SHORT
fi
# 10. 7d remove
if _over; then SEG_7D=""; fi
# 11. 5h remove
if _over; then SEG_5H=""; fi

_compose

# ── Agents line ──────────────────────────────────────────
AGENTS_LINE=""
WORKFLOW_LINES=""
if (( _ac > 0 )); then
  # Split regular agents from workflows
  _reg_count=0 _reg_descs=() _reg_toks=() _reg_rates=() _reg_models=()
  _wf_count=0 _wf_descs=() _wf_toks=() _wf_rates=() _wf_models=() _wf_subcounts=() _wf_phases=()
  for (( _i=0; _i<_ac; _i++ )); do
    if [ -n "${_a_workflows[$_i]}" ]; then
      _wf_descs+=("${_a_descs[$_i]}")
      _wf_toks+=("${_a_toks[$_i]}")
      _wf_rates+=("${_a_rates[$_i]}")
      _wf_models+=("${_a_models[$_i]}")
      _wf_subcounts+=("${_a_subcounts[$_i]}")
      _wf_phases+=("${_a_phases[$_i]}")
      (( _wf_count++ ))
    else
      _reg_descs+=("${_a_descs[$_i]}")
      _reg_toks+=("${_a_toks[$_i]}")
      _reg_rates+=("${_a_rates[$_i]}")
      _reg_models+=("${_a_models[$_i]}")
      (( _reg_count++ ))
    fi
  done

  if (( _reg_count > 0 )); then
    _all_same=true
    for _m in "${_reg_models[@]}"; do
      [ "$_m" = "${_reg_models[0]}" ] || { _all_same=false; break; }
    done
    _header="${C_GRAY}${_reg_count} agent"
    (( _reg_count > 1 )) && _header+="s"
    if $_all_same && [ -n "${_reg_models[0]}" ]; then
      _header+=" ${C_DIM}(${_reg_models[0]})"
    fi
    _header+="${C_DIM}:"
    _header_len=$(vis_len "$_header")
    printf -v _indent '%*s' "$_header_len" ''
    _cur_line=$_header
    for (( _i=0; _i<_reg_count; _i++ )); do
      _tf=$(fmt_tok "${_reg_toks[$_i]}")
      _part=" ${C_GRAY}${_reg_descs[$_i]} ${C_MODEL}${_tf}"
      if [ -n "${_reg_rates[$_i]}" ] && [ "${_reg_rates[$_i]}" != "0" ]; then
        _rf=$(awk "BEGIN { n=${_reg_rates[$_i]}; if(n>=1000) printf \"%.0fk\", n/1000; else printf \"%.0f\", n }")
        _part+=" $(agent_rate_color "${_reg_rates[$_i]}")${_rf}/m"
      fi
      if ! $_all_same && [ -n "${_reg_models[$_i]}" ]; then
        _part+=" ${C_DIM}(${_reg_models[$_i]})"
      fi
      _candidate=$_cur_line
      (( _i > 0 )) && _candidate+="${C_GRAY},"
      _candidate+=$_part
      if (( _i > 0 && $(vis_len "$_candidate") > MAX_W )); then
        AGENTS_LINE+="${_cur_line}${C_GRAY},"$'\n'
        _cur_line="${_indent}${_part}"
      else
        _cur_line=$_candidate
      fi
    done
    AGENTS_LINE+=$_cur_line
  fi

  for (( _i=0; _i<_wf_count; _i++ )); do
    _tf=$(fmt_tok "${_wf_toks[$_i]}")
    _wl="${C_GRAY}→ ${_wf_descs[$_i]} ${C_DIM}(${_wf_subcounts[$_i]} agents) ${C_MODEL}${_tf}"
    if [ -n "${_wf_rates[$_i]}" ] && [ "${_wf_rates[$_i]}" != "0" ]; then
      _rf=$(awk "BEGIN { n=${_wf_rates[$_i]}; if(n>=1000) printf \"%.0fk\", n/1000; else printf \"%.0f\", n }")
      _wl+=" $(agent_rate_color "${_wf_rates[$_i]}")${_rf}/m"
    fi
    [ -n "${_wf_models[$_i]}" ] && _wl+=" ${C_DIM}(${_wf_models[$_i]})"
    WORKFLOW_LINES+=$'\n'"${_wl}${RST}"

    _pj="${_wf_phases[$_i]}"
    if [ -n "$_pj" ] && [ "$_pj" != "[]" ]; then
      _phase_line=""
      while IFS= read -r -d '' _pt && IFS= read -r -d '' _pd && IFS= read -r -d '' _pc; do
        [ -n "$_phase_line" ] && _phase_line+="  "
        _phase_line+="${C_DIM}${_pt} ${C_GRAY}${_pd}/${_pc}"
        if (( _pd == _pc )); then _phase_line+=" ${C_ADD}✓"; fi
      done < <(printf '%s' "$_pj" | jq -j '.[] | select(.n > 0) | [.t, .d, .n] | .[] | tostring, "\u0000"')
      [ -n "$_phase_line" ] && WORKFLOW_LINES+=$'\n'"   ${_phase_line}${RST}"
    fi
  done
fi

# ── Resume command ───────────────────────────────────────
RESUME_LINE=""
if $SHOW_RESUME_LINE && [ -n "$RESUME_SESSION_ID" ]; then
  printf -v _resume_sid '%q' "$RESUME_SESSION_ID"
  RESUME_LINE="claude --resume $_resume_sid"
  if [[ $PROJECT_DIR =~ ^[A-Za-z]:\\ ]]; then
    RESUME_LINE="cmd /c \"cd /d $PROJECT_DIR && $RESUME_LINE\""
  elif [ -n "$PROJECT_DIR" ]; then
    # Quote shell metacharacters too, so the command can be pasted safely.
    if [[ $PROJECT_DIR == "$HOME" ]]; then
      _resume_dir="~"
    elif [[ $PROJECT_DIR == "$HOME"/* ]]; then
      printf -v _resume_dir '%q' "${PROJECT_DIR#"$HOME"/}"
      _resume_dir="~/$_resume_dir"
    else
      printf -v _resume_dir '%q' "$PROJECT_DIR"
    fi
    RESUME_LINE="cd $_resume_dir && $RESUME_LINE"
  fi
fi

# ── Output ───────────────────────────────────────────────
_spinner=✦
if (( SHELL_COUNT > 0 || _ac > 0 )); then
  _frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  _spinner=${_frames[(_now / REFRESH_INTERVAL) % ${#_frames[@]}]}
fi
printf '\033]0;%s %s | %s\007' "$_spinner" "${PROJ:-claude}" "${RESUME_SESSION_ID:0:8}"
printf '%s%s' "$OUT" "$RST"
[ -n "$RESUME_LINE" ] && printf '\n%s%s%s' "$C_DIM" "$RESUME_LINE" "$RST"
[ -n "$AGENTS_LINE" ] && printf '\n%s%s' "$AGENTS_LINE" "$RST"
[ -n "$WORKFLOW_LINES" ] && printf '%s' "$WORKFLOW_LINES"
exit 0
