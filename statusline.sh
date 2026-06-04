#!/usr/bin/env bash

# Claude Code statusline — bashversion
# Two-tier refresh: full compute every N seconds, cheap ticks in between
# Adaptive agent refresh: full compute more often when agents are active

input=$(cat)

command -v jq &>/dev/null || { echo "jq required"; exit 0; }

# ── Tuning constants ────────────────────────────────────
WIDTH=120           # terminal width (default 120)
OAUTH_TTL=60        # seconds between OAuth usage API calls
FULL_INTERVAL=10    # seconds between full recomputes (no agents)
AGENT_INTERVAL=5    # seconds between full recomputes (agents active)

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

SEP=" ${C_SEP}| "

pct_color() {
  local p=$(awk "BEGIN { print int(${1:-0}+0.5) }")
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
  local f=$(awk "BEGIN { v=int($pct*$w/100+0.5); if(v>$w)v=$w; if(v<0)v=0; print v }")
  local e=$(( w - f ))
  local out="${C_BAR}"
  for ((i=0; i<f; i++)); do out+="▓"; done
  out+="${C_BAR_E}"
  for ((i=0; i<e; i++)); do out+="░"; done
  printf '%s' "$out"
}

_ESC=$'\x1b'
vis_len() {
  printf '%s' "$1" | sed "s/${_ESC}\[[0-9;]*m//g" \
    | sed 's/▓/X/g;s/░/X/g;s/📁/X/g;s/↑/X/g;s/↓/X/g;s/→/X/g;s/✓/X/g' | wc -c
}

fmt_tok() {
  awk "BEGIN {
    n = ${1:-0}
    if (n >= 1000000) printf \"%.1fM\", n/1000000
    else if (n >= 1000) printf \"%.0fk\", n/1000
    else printf \"%.0fk\", n/1000
  }"
}

# ── Extract fields always needed ─────────────────────────
TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // empty')
PROJECT_DIR=$(echo "$input" | jq -r '.workspace.project_dir // empty')
MODEL=$(echo "$input" | jq -r '.model.display_name // empty')
EFFORT=$(echo "$input" | jq -r '.effort.level // empty')
CTX_PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0')
CTX_SIZE=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
SEVEN_D=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

_now=$(date +%s)

# ── Session ID for per-session isolation ─────────────────
SESSION_ID=""
if [ -n "$TRANSCRIPT" ]; then
  SESSION_ID=$(basename "$TRANSCRIPT" .jsonl)
fi
COMPUTE_CACHE="$HOME/.claude/.sl_compute_${SESSION_ID}"

# ── Resolve this session's PID from session files ────────
_my_pid=0
_target_sid=$(echo "$input" | jq -r '.session_id // empty')
[ -z "$_target_sid" ] && _target_sid="$SESSION_ID"
if [ -n "$_target_sid" ]; then
  for _sf in "$HOME/.claude/sessions/"*.json; do
    [ -f "$_sf" ] || continue
    _sf_sid=$(jq -r '.sessionId // empty' "$_sf" 2>/dev/null)
    if [ "$_sf_sid" = "$_target_sid" ]; then
      _my_pid=$(jq -r '.pid // 0' "$_sf" 2>/dev/null)
      break
    fi
  done
fi

# ── Two-tier: decide full vs cheap tick ──────────────────
_do_full=true
if [ -n "$SESSION_ID" ] && [ -f "$COMPUTE_CACHE" ]; then
  _cc_at=$(jq -r '.computed_at // 0' "$COMPUTE_CACHE" 2>/dev/null)
  _cc_agents=$(jq -r '.has_agents // false' "$COMPUTE_CACHE" 2>/dev/null)
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
  [ -f "$RATE_FILE" ] || { echo ""; return; }
  local now=$(date +%s) pct=$1
  local cutoff=$(( now - 1800 ))
  local oldest
  oldest=$(awk -v c="$cutoff" '$1 >= c { print; exit }' "$RATE_FILE" 2>/dev/null)
  [ -n "$oldest" ] || { echo ""; return; }
  local old_t old_p dt
  old_t=$(echo "$oldest" | awk '{print $1}')
  old_p=$(echo "$oldest" | awk '{print $2}')
  dt=$(( now - old_t ))
  (( dt < 120 )) && { echo ""; return; }
  awk "BEGIN { printf \"%.0f\", ($pct - $old_p) / ($dt / 3600.0) }"
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
      elif ! kill -0 "$_owner_pid" 2>/dev/null; then
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
          (
            _resp=$(curl -s -m 3 -H "Authorization: Bearer $_tok" \
              "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
            if [ -n "$_resp" ]; then
              echo "$_resp" | jq --argjson t "$(date +%s)" '{
                five_hour:  (.five_hour.utilization  // null),
                seven_day:  (.seven_day.utilization  // null),
                fetched_at: $t
              }' > "$USAGE_CACHE" 2>/dev/null
            fi
          ) &
        fi
      fi
    fi
  fi

  if [ -f "$USAGE_CACHE" ]; then
    FIVE_H=$(jq -r '.five_hour // empty' "$USAGE_CACHE" 2>/dev/null)
    SEVEN_D=$(jq -r '.seven_day // empty' "$USAGE_CACHE" 2>/dev/null)
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
  local _agents_json="[]"
  if (( _ac > 0 )); then
    _agents_json="["
    for (( _i=0; _i<_ac; _i++ )); do
      (( _i > 0 )) && _agents_json+=","
      _agents_json+="{\"short\":$(printf '%s' "${_a_descs[$_i]}" | jq -Rs .)"
      _agents_json+=",\"tokens\":${_a_toks[$_i]:-0}"
      _agents_json+=",\"rate\":${_a_rates[$_i]:-null}"
      _agents_json+=",\"model\":$(printf '%s' "${_a_models[$_i]}" | jq -Rs .)"
      _agents_json+=",\"workflow\":$(printf '%s' "${_a_workflows[$_i]}" | jq -Rs .)"
      _agents_json+=",\"subcount\":${_a_subcounts[$_i]:-0}"
      _agents_json+=",\"phases\":$(printf '%s' "${_a_phases[$_i]:-[]}" | jq -Rc .)}"
    done
    _agents_json+="]"
  fi
  local _has_agents=false
  (( _ac > 0 )) && _has_agents=true
  cat > "$COMPUTE_CACHE" <<CEOF
{
  "computed_at": $_now,
  "has_agents": $_has_agents,
  "lines_add": ${LINES_ADD:-0},
  "lines_del": ${LINES_DEL:-0},
  "branch": $(printf '%s' "$BRANCH" | jq -Rs .),
  "in_git": $IN_GIT,
  "cache_epoch": $CACHE_EPOCH,
  "cache_ttl": $CACHE_TTL,
  "agents": $_agents_json
}
CEOF
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
    (( _gc_age > 300 )) && _do_gc=true
  fi
  if $_do_gc; then
    echo -n "$_now" > "$_gc_marker"
    _live_sids=""
    for _sf in "$HOME/.claude/sessions/"*.json; do
      [ -f "$_sf" ] || continue
      _spid=$(jq -r '.pid // empty' "$_sf" 2>/dev/null)
      [ -n "$_spid" ] && kill -0 "$_spid" 2>/dev/null && \
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

  # Cheap fields from stdin JSON (instant)
  LINES_ADD=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
  LINES_DEL=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')

  # Seed expensive fields from stale cache (or defaults)
  CACHE_EPOCH=0; CACHE_TTL=300; BRANCH=""; IN_GIT=false
  _ac=0; _a_descs=() _a_toks=() _a_rates=() _a_models=() _a_workflows=() _a_subcounts=() _a_phases=()
  if [ -f "$COMPUTE_CACHE" ]; then
    BRANCH=$(jq -r '.branch // empty' "$COMPUTE_CACHE" 2>/dev/null)
    IN_GIT=$(jq -r '.in_git // false' "$COMPUTE_CACHE" 2>/dev/null)
    CACHE_EPOCH=$(jq -r '.cache_epoch // 0' "$COMPUTE_CACHE" 2>/dev/null)
    CACHE_TTL=$(jq -r '.cache_ttl // 300' "$COMPUTE_CACHE" 2>/dev/null)
    _agent_count=$(jq -r '.agents | length // 0' "$COMPUTE_CACHE" 2>/dev/null)
    for (( _i=0; _i<_agent_count; _i++ )); do
      _a_descs+=($(jq -r ".agents[$_i].short // \"agent\"" "$COMPUTE_CACHE" 2>/dev/null))
      _a_toks+=($(jq -r ".agents[$_i].tokens // 0" "$COMPUTE_CACHE" 2>/dev/null))
      _a_rates+=($(jq -r ".agents[$_i].rate // empty" "$COMPUTE_CACHE" 2>/dev/null))
      _a_models+=($(jq -r ".agents[$_i].model // empty" "$COMPUTE_CACHE" 2>/dev/null))
      _a_workflows+=($(jq -r ".agents[$_i].workflow // empty" "$COMPUTE_CACHE" 2>/dev/null))
      _a_subcounts+=($(jq -r ".agents[$_i].subcount // 0" "$COMPUTE_CACHE" 2>/dev/null))
    done
    _ac=${#_a_descs[@]}
  fi

  # Write partial cache immediately -- breaks the death loop
  _write_compute_cache

  # ── Cache countdown state from transcript ──────────────
  CACHE_STATE="$HOME/.claude/.sl_cache_${SESSION_ID}"
  CACHE_MTIME="$HOME/.claude/.sl_mtime_${SESSION_ID}"

  if [ -f "$TRANSCRIPT" ]; then
    _t_mtime=$(stat -c %Y "$TRANSCRIPT" 2>/dev/null || echo 0)
    _last_mtime=$(cat "$CACHE_MTIME" 2>/dev/null || echo 0)
    if [ "$_t_mtime" != "$_last_mtime" ]; then
      result=$(tail -100 "$TRANSCRIPT" 2>/dev/null | jq -rs '
        [.[] | select(
          ((.message.usage.cache_read_input_tokens // 0) > 0) or
          ((.message.usage.cache_creation_input_tokens // 0) > 0)
        )] | last |
        {
          timestamp: (.timestamp // empty),
          ttl: (if ((.message.usage.cache_creation.ephemeral_1h_input_tokens // 0) > 0)
                then 3600 else 300 end)
        }
      ' 2>/dev/null)
      if [ -n "$result" ]; then
        iso=$(echo "$result" | jq -r '.timestamp // empty')
        ttl=$(echo "$result" | jq -r '.ttl // 300')
        if [ -n "$iso" ]; then
          ts=$(date -d "$iso" +%s 2>/dev/null)
          if [ -n "$ts" ]; then
            CACHE_EPOCH=$ts; CACHE_TTL=$ttl
            echo "$ts $ttl" > "$CACHE_STATE"
          fi
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

  # ── Git branch ─────────────────────────────────────────
  if [ -n "$PROJECT_DIR" ]; then
    BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ -n "$BRANCH" ]; then IN_GIT=true; else BRANCH=""; IN_GIT=false; fi
  fi

  # ── Active agents (incremental parsing) ────────────────
  _ac=0
  _a_descs=() _a_toks=() _a_rates=() _a_models=() _a_workflows=() _a_subcounts=()
  if [ -n "$TRANSCRIPT" ]; then
    _sa_dir="${TRANSCRIPT%.jsonl}/subagents"
    _agent_cache="$HOME/.claude/.sl_agents_${SESSION_ID}"
    if [ -d "$_sa_dir" ]; then
      _agent_cache_dirty=false
      for _mf in "$_sa_dir"/agent-*.meta.json; do
        [ -f "$_mf" ] || continue
        _jf="${_mf%.meta.json}.jsonl"
        [ -f "$_jf" ] || continue
        _fm=$(stat -c %Y "$_jf" 2>/dev/null || echo 0)
        (( _now - _fm > 120 )) && continue
        _desc=$(jq -r '.description // "agent"' "$_mf" 2>/dev/null)
        _short=$(echo "$_desc" | awk '
          BEGIN { split("a,an,the,and,or,but,not,nor,for,yet,so,with,from,except,into,about,after,before,during,without",sw,",") }
          { n=NF; if(n>3)n=3
            while(n>1) { w=tolower($n); ok=1; for(k in sw) if(w==sw[k]){ok=0;break}; if(ok)break; n-- }
            for(i=1;i<=n;i++) printf "%s",(i>1?" ":"")$i
          }')

        _jf_name=$(basename "$_jf")
        _jf_size=$(stat -c %s "$_jf" 2>/dev/null || echo 0)

        # Read per-agent cache: name size tokens model first_ts
        _ca_size=0 _ca_tokens=0 _ca_model="" _ca_first_ts=""
        if [ -f "$_agent_cache" ]; then
          _ca_line=$(grep "^${_jf_name} " "$_agent_cache" 2>/dev/null)
          if [ -n "$_ca_line" ]; then
            read -r _ _ca_size _ca_tokens _ca_model _ca_first_ts <<< "$_ca_line"
          fi
        fi

        if [ "$_jf_size" = "$_ca_size" ] && [ "$_ca_size" != "0" ]; then
          _otok=$_ca_tokens
          _model=$_ca_model
          _first_ts_epoch=$_ca_first_ts
        else
          if [ "$_jf_size" -gt "${_ca_size:-0}" ] 2>/dev/null && [ "${_ca_size:-0}" -gt 0 ]; then
            # Incremental: read only new bytes, skip partial first line
            _new_tokens=$(tail -c +$((_ca_size + 1)) "$_jf" 2>/dev/null | \
              grep '"output_tokens"' | jq -s '[.[].message.usage.output_tokens // 0] | add // 0' 2>/dev/null)
            _otok=$(( ${_ca_tokens:-0} + ${_new_tokens:-0} ))
            _model=$_ca_model
            _first_ts_epoch=$_ca_first_ts
          else
            # Full read (new file or truncated)
            _otok=$(grep '"output_tokens"' "$_jf" 2>/dev/null | jq -s '[.[].message.usage.output_tokens // 0] | add // 0' 2>/dev/null)
            _otok=${_otok:-0}
            _first_ts=$(head -1 "$_jf" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null)
            _first_ts_epoch=""
            if [ -n "$_first_ts" ]; then
              _first_ts_epoch=$(date -d "$_first_ts" +%s 2>/dev/null)
            fi
            _model=$(grep -m1 '"assistant"' "$_jf" 2>/dev/null | jq -r '.message.model // empty' 2>/dev/null)
            _model=$(echo "$_model" | sed 's/claude-//;s/-[0-9].*//;s/\b\(.\)/\u\1/')
          fi
          _agent_cache_dirty=true
          # Update in-memory cache line (written after loop)
          if [ -f "$_agent_cache" ]; then
            grep -v "^${_jf_name} " "$_agent_cache" > "${_agent_cache}.tmp" 2>/dev/null || true
            mv "${_agent_cache}.tmp" "$_agent_cache" 2>/dev/null
          fi
          echo "${_jf_name} ${_jf_size} ${_otok} ${_model:-unknown} ${_first_ts_epoch:-0}" >> "$_agent_cache"
        fi

        _arate=""
        if [ -n "$_first_ts_epoch" ] && [ "$_first_ts_epoch" != "0" ]; then
          _elapsed=$(( _now - _first_ts_epoch ))
          if (( _elapsed >= 10 )); then
            _arate=$(awk "BEGIN { printf \"%.0f\", $_otok / ($_elapsed / 60.0) }")
          fi
        fi
        _a_descs+=("$_short")
        _a_toks+=("$_otok")
        _a_rates+=("$_arate")
        _a_models+=("$_model")
        _a_workflows+=("")
        _a_subcounts+=(0)
        _a_phases+=("[]")
      done

      # ── Workflow subagents (subagents/workflows/wf_*/) ──
      _wf_dir="$_sa_dir/workflows"
      if [ -d "$_wf_dir" ]; then
        _session_dir="${TRANSCRIPT%.jsonl}"
        _script_dir="$_session_dir/workflows/scripts"
        for _wf_folder in "$_wf_dir"/wf_*/; do
          [ -d "$_wf_folder" ] || continue
          _wf_id=$(basename "$_wf_folder")
          _wf_name="$_wf_id"
          if [ -d "$_script_dir" ]; then
            _script_match=$(ls "$_script_dir"/*-"${_wf_id}.js" 2>/dev/null | head -1)
            if [ -n "$_script_match" ]; then
              _wf_name=$(basename "$_script_match" | sed "s/-${_wf_id}\\.js$//")
            fi
          fi

          # Phase detection: try state JSON (completed), fall back to script+journal (running)
          _wf_phase_json="[]"
          _wf_state_file="$_session_dir/workflows/${_wf_id}.json"
          if [ -f "$_wf_state_file" ]; then
            _wf_phase_json=$(jq -c '
              (.phases // []) as $ph |
              if ($ph | length) == 0 then [] else
                [(.workflowProgress // []) | group_by(.phaseTitle) | .[] |
                  {t: .[0].phaseTitle, n: length, d: [.[] | select(.state == "done")] | length}
                ] | [($ph | .[].title) as $t | {t: $t, n: 0, d: 0}] as $empty |
                reduce ($empty[] + .[]) as $x ({}; .[$x.t].t = $x.t | .[$x.t].n += $x.n | .[$x.t].d += $x.d) |
                [($ph | .[].title) as $t | .[$t] // {t: $t, n: 0, d: 0}]
              end
            ' "$_wf_state_file" 2>/dev/null)
            _sn=$(jq -r '.workflowName // empty' "$_wf_state_file" 2>/dev/null)
            [ -n "$_sn" ] && _wf_name="$_sn"
          fi
          if [ "$_wf_phase_json" = "[]" ] || [ -z "$_wf_phase_json" ]; then
            _wf_script=$(ls "$_script_dir"/*-"${_wf_id}.js" 2>/dev/null | head -1)
            if [ -n "$_wf_script" ]; then
              _wf_phase_titles=$(sed -n "s/.*{ *title: *['\"]\\([^'\"]*\\)['\"].*/\\1/p" "$_wf_script" 2>/dev/null)
              if [ -n "$_wf_phase_titles" ]; then
                _journal="$_wf_folder/journal.jsonl"
                if [ -f "$_journal" ]; then
                  _wf_phase_json=$(awk -v titles="$_wf_phase_titles" '
                    BEGIN {
                      n = split(titles, ph, "\n")
                      for (i=1; i<=n; i++) { cnt[ph[i]]=0; done[ph[i]]=0; order[i]=ph[i] }
                      pidx=1; seen_result=0
                    }
                    {
                      if (match($0, /"type":"started".*"agentId":"([^"]+)"/, m)) {
                        if (seen_result && pidx < n) { pidx++; seen_result=0 }
                        cnt[order[pidx]]++
                        agent_ph[m[1]] = order[pidx]
                      }
                      if (match($0, /"type":"result".*"agentId":"([^"]+)"/, m)) {
                        seen_result=1
                        if (m[1] in agent_ph) done[agent_ph[m[1]]]++
                      }
                    }
                    END {
                      printf "["
                      for (i=1; i<=n; i++) {
                        if (i>1) printf ","
                        gsub(/"/, "\\\"", order[i])
                        printf "{\"t\":\"%s\",\"n\":%d,\"d\":%d}", order[i], cnt[order[i]], done[order[i]]
                      }
                      printf "]"
                    }
                  ' "$_journal" 2>/dev/null)
                fi
              fi
            fi
          fi
          [ -z "$_wf_phase_json" ] && _wf_phase_json="[]"

          _wf_total_tok=0 _wf_first_ts="" _wf_last_write=0 _wf_sub_count=0 _wf_model=""
          for _wjf in "$_wf_folder"agent-*.jsonl; do
            [ -f "$_wjf" ] || continue
            _wjf_write=$(stat -c %Y "$_wjf" 2>/dev/null || echo 0)
            (( _wjf_write > _wf_last_write )) && _wf_last_write=$_wjf_write
            (( _wf_sub_count++ ))

            _wjf_name=$(basename "$_wjf")
            _ck="${_wf_id}/${_wjf_name}"
            _wjf_size=$(stat -c %s "$_wjf" 2>/dev/null || echo 0)

            _ca_size=0 _ca_tokens=0 _ca_model="" _ca_first_ts=""
            if [ -f "$_agent_cache" ]; then
              _ca_line=$(grep "^${_ck} " "$_agent_cache" 2>/dev/null)
              if [ -n "$_ca_line" ]; then
                read -r _ _ca_size _ca_tokens _ca_model _ca_first_ts <<< "$_ca_line"
              fi
            fi

            if [ "$_wjf_size" = "$_ca_size" ] && [ "$_ca_size" != "0" ]; then
              _wf_total_tok=$(( _wf_total_tok + _ca_tokens ))
              [ -z "$_wf_model" ] && [ -n "$_ca_model" ] && _wf_model="$_ca_model"
              if [ -n "$_ca_first_ts" ] && [ "$_ca_first_ts" != "0" ]; then
                [ -z "$_wf_first_ts" ] && _wf_first_ts="$_ca_first_ts"
                (( _ca_first_ts < _wf_first_ts )) && _wf_first_ts="$_ca_first_ts"
              fi
            else
              _sub_tok=0 _sub_first_ts="" _sub_model=""
              if [ "$_wjf_size" -gt "${_ca_size:-0}" ] 2>/dev/null && [ "${_ca_size:-0}" -gt 0 ]; then
                _new_tok=$(tail -c +$((_ca_size + 1)) "$_wjf" 2>/dev/null | \
                  grep '"output_tokens"' | jq -s '[.[].message.usage.output_tokens // 0] | add // 0' 2>/dev/null)
                _sub_tok=$(( ${_ca_tokens:-0} + ${_new_tok:-0} ))
                _sub_model="$_ca_model"
                _sub_first_ts="$_ca_first_ts"
              else
                _sub_tok=$(grep '"output_tokens"' "$_wjf" 2>/dev/null | jq -s '[.[].message.usage.output_tokens // 0] | add // 0' 2>/dev/null)
                _sub_tok=${_sub_tok:-0}
                _ts=$(head -1 "$_wjf" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null)
                [ -n "$_ts" ] && _sub_first_ts=$(date -d "$_ts" +%s 2>/dev/null)
                _sub_model=$(grep -m1 '"assistant"' "$_wjf" 2>/dev/null | jq -r '.message.model // empty' 2>/dev/null)
                _sub_model=$(echo "$_sub_model" | sed 's/claude-//;s/-[0-9].*//;s/\b\(.\)/\u\1/')
              fi
              _agent_cache_dirty=true
              if [ -f "$_agent_cache" ]; then
                grep -v "^${_ck} " "$_agent_cache" > "${_agent_cache}.tmp" 2>/dev/null || true
                mv "${_agent_cache}.tmp" "$_agent_cache" 2>/dev/null
              fi
              echo "${_ck} ${_wjf_size} ${_sub_tok} ${_sub_model:-unknown} ${_sub_first_ts:-0}" >> "$_agent_cache"
              _wf_total_tok=$(( _wf_total_tok + _sub_tok ))
              [ -z "$_wf_model" ] && [ -n "$_sub_model" ] && _wf_model="$_sub_model"
              if [ -n "$_sub_first_ts" ] && [ "$_sub_first_ts" != "0" ]; then
                [ -z "$_wf_first_ts" ] && _wf_first_ts="$_sub_first_ts"
                (( _sub_first_ts < _wf_first_ts )) && _wf_first_ts="$_sub_first_ts"
              fi
            fi
          done

          (( _wf_sub_count == 0 )) && continue
          (( _now - _wf_last_write > 120 )) && continue

          _wf_rate=""
          if [ -n "$_wf_first_ts" ] && [ "$_wf_first_ts" != "0" ]; then
            _elapsed=$(( _now - _wf_first_ts ))
            if (( _elapsed >= 10 )); then
              _wf_rate=$(awk "BEGIN { printf \"%.0f\", $_wf_total_tok / ($_elapsed / 60.0) }")
            fi
          fi

          _a_descs+=("$_wf_name")
          _a_toks+=("$_wf_total_tok")
          _a_rates+=("$_wf_rate")
          _a_models+=("$_wf_model")
          _a_workflows+=("$_wf_id")
          _a_subcounts+=("$_wf_sub_count")
          _a_phases+=("$_wf_phase_json")
        done
      fi

      _ac=${#_a_descs[@]}
    fi
  fi

  # ── Write full cache (overwrites partial) ──────────────
  _write_compute_cache

else
  # ══════════════════════════════════════════════════════
  # CHEAP TICK — read cached values
  # ══════════════════════════════════════════════════════

  LINES_ADD=$(jq -r '.lines_add // 0' "$COMPUTE_CACHE" 2>/dev/null)
  LINES_DEL=$(jq -r '.lines_del // 0' "$COMPUTE_CACHE" 2>/dev/null)
  BRANCH=$(jq -r '.branch // empty' "$COMPUTE_CACHE" 2>/dev/null)
  IN_GIT=$(jq -r '.in_git // false' "$COMPUTE_CACHE" 2>/dev/null)
  CACHE_EPOCH=$(jq -r '.cache_epoch // 0' "$COMPUTE_CACHE" 2>/dev/null)
  CACHE_TTL=$(jq -r '.cache_ttl // 300' "$COMPUTE_CACHE" 2>/dev/null)

  _ac=0
  _a_descs=() _a_toks=() _a_rates=() _a_models=() _a_workflows=() _a_subcounts=() _a_phases=()
  _agent_count=$(jq -r '.agents | length // 0' "$COMPUTE_CACHE" 2>/dev/null)
  for (( _i=0; _i<_agent_count; _i++ )); do
    _a_descs+=($(jq -r ".agents[$_i].short // \"agent\"" "$COMPUTE_CACHE" 2>/dev/null))
    _a_toks+=($(jq -r ".agents[$_i].tokens // 0" "$COMPUTE_CACHE" 2>/dev/null))
    _a_rates+=($(jq -r ".agents[$_i].rate // empty" "$COMPUTE_CACHE" 2>/dev/null))
    _a_models+=($(jq -r ".agents[$_i].model // empty" "$COMPUTE_CACHE" 2>/dev/null))
    _a_workflows+=($(jq -r ".agents[$_i].workflow // empty" "$COMPUTE_CACHE" 2>/dev/null))
    _a_subcounts+=($(jq -r ".agents[$_i].subcount // 0" "$COMPUTE_CACHE" 2>/dev/null))
    _a_phases+=($(jq -rc ".agents[$_i].phases // []" "$COMPUTE_CACHE" 2>/dev/null))
  done
  _ac=${#_a_descs[@]}
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
    CACHE_ELAPSED_PCT=$(( 100 - (_remain * 100 / CACHE_TTL) ))
  fi
fi

# ── Build output ─────────────────────────────────────────
OUT=""

if [ -n "$MODEL" ]; then
  MODEL_STR="${MODEL/ (1M context)/}"
  OUT+="${C_MODEL}${MODEL_STR}"
  CTX_INT=$(awk "BEGIN { printf \"%.0f\", $CTX_SIZE }")
  (( CTX_INT >= 1000000 )) && OUT+=" ${C_DIM}[1M]"
  [ -n "$EFFORT" ] && OUT+=" ${C_GRAY}(${EFFORT})"
fi

PROJ=$(basename "$PROJECT_DIR" 2>/dev/null)
if [ -n "$PROJ" ]; then
  [ -n "$OUT" ] && OUT+="${SEP}"
  if [ "$IN_GIT" = "true" ]; then
    OUT+="${C_PROJ}📁 ${PROJ} ${C_GRAY}(${BRANCH})"
  else
    OUT+="${C_PROJ}📁 ${PROJ} ${C_DIM}(untracked)"
  fi
fi

LADD=$(awk "BEGIN { print int(${LINES_ADD:-0}) }")
LDEL=$(awk "BEGIN { print int(${LINES_DEL:-0}) }")
if [ "$IN_GIT" = "true" ] && (( LADD > 0 || LDEL > 0 )); then
  OUT+="${SEP}${C_ADD}+${LADD}${C_DEL}/-${LDEL}"
fi

CTX_P=$(awk "BEGIN { print int($CTX_PCT+0.5) }")
CTX_USED=$(awk "BEGIN { printf \"%.0f\", $CTX_SIZE * $CTX_PCT / 100 }")
U_FMT=$(fmt_tok "${CTX_USED}")
OUT+="${SEP}${C_GRAY}${U_FMT} $(make_bar "$CTX_PCT" 8) $(pct_color "$CTX_PCT")${CTX_P}%"

SEG_5H="" SEG_5H_MID="" SEG_5H_SHORT=""
if [ -n "$FIVE_H" ]; then
  P5=$(awk "BEGIN { print int($FIVE_H+0.5) }")
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
  SEG_5H="${SEP}${C_GRAY}5h $(make_bar "$FIVE_H" 8) $(pct_color "$FIVE_H")${P5}%${RATE_STR}"
  SEG_5H_MID="${SEP}${C_GRAY}5h $(make_bar "$FIVE_H" 8) $(pct_color "$FIVE_H")${P5}%"
  SEG_5H_SHORT="${SEP}${C_GRAY}5h: $(pct_color "$FIVE_H")${P5}%"
fi

SEG_7D="" SEG_7D_SHORT=""
if [ -n "$SEVEN_D" ]; then
  PW=$(awk "BEGIN { print int($SEVEN_D+0.5) }")
  SEG_7D="${SEP}${C_GRAY}7d $(make_bar "$SEVEN_D" 8) $(pct_color "$SEVEN_D")${PW}%"
  SEG_7D_SHORT="${SEP}${C_GRAY}7d: $(pct_color "$SEVEN_D")${PW}%"
fi

SEG_CACHE=""
if [ -n "$CACHE_REMAINING" ]; then
  SEG_CACHE="${SEP}${C_GRAY}cache $(pct_color "$CACHE_ELAPSED_PCT")${CACHE_REMAINING}"
fi

MAX_W=$(( WIDTH - 4 ))
_cur_bar=8
_rate_dropped=false

_over() { local l=$(vis_len "${OUT}${SEG_5H}${SEG_7D}${SEG_CACHE}"); (( l > MAX_W )); }

_rebuild_bars() {
  local _bw=$_cur_bar
  CTX_BAR_OUT="${SEP}${C_GRAY}${U_FMT} $(make_bar "$CTX_PCT" "$_bw") $(pct_color "$CTX_PCT")${CTX_P}%"
  # Rebuild OUT up to ctx (replace the ctx segment which is the last SEP-delimited piece before 5h)
  # Simpler: rebuild OUT from scratch since segments are appended
  OUT=""
  if [ -n "$MODEL" ]; then
    OUT+="${C_MODEL}${MODEL_STR}"
    (( CTX_INT >= 1000000 )) && ! $_1m_removed && OUT+=" ${C_DIM}[1M]"
    [ -n "$EFFORT" ] && OUT+=" ${C_GRAY}(${EFFORT})"
  fi
  if [ -n "$PROJ" ]; then
    [ -n "$OUT" ] && OUT+="${SEP}"
    if [ "$IN_GIT" = "true" ]; then
      OUT+="${C_PROJ}📁 ${PROJ} ${C_GRAY}(${BRANCH})"
    else
      OUT+="${C_PROJ}📁 ${PROJ} ${C_DIM}(untracked)"
    fi
  fi
  if [ "$IN_GIT" = "true" ] && (( LADD > 0 || LDEL > 0 )); then
    OUT+="${SEP}${C_ADD}+${LADD}${C_DEL}/-${LDEL}"
  fi
  OUT+="${SEP}${C_GRAY}${U_FMT} $(make_bar "$CTX_PCT" "$_bw") $(pct_color "$CTX_PCT")${CTX_P}%"

  if [ -n "$FIVE_H" ] && [ -n "$SEG_5H" ]; then
    if $_rate_dropped; then
      SEG_5H="${SEP}${C_GRAY}5h $(make_bar "$FIVE_H" "$_bw") $(pct_color "$FIVE_H")${P5}%"
    else
      SEG_5H="${SEP}${C_GRAY}5h $(make_bar "$FIVE_H" "$_bw") $(pct_color "$FIVE_H")${P5}%${RATE_STR}"
    fi
  fi
  if [ -n "$SEVEN_D" ] && [ -n "$SEG_7D" ]; then
    SEG_7D="${SEP}${C_GRAY}7d $(make_bar "$SEVEN_D" "$_bw") $(pct_color "$SEVEN_D")${PW}%"
  fi
}

_1m_removed=false

# Collapse cascade
# 1. cache label removed
if _over && [ -n "$SEG_CACHE" ]; then
  SEG_CACHE="${SEP}$(pct_color "$CACHE_ELAPSED_PCT")${CACHE_REMAINING}"
fi
# 2. [1M] removed
if _over && (( CTX_INT >= 1000000 )); then
  _1m_removed=true
  _rebuild_bars
fi
# 3-6. bars squeeze 8->7->6->5->4
for _target_bw in 7 6 5 4; do
  if _over && (( _cur_bar > _target_bw )); then
    _cur_bar=$_target_bw
    _rebuild_bars
  fi
done
# 7. 5h rate drop
if _over && [ -n "$SEG_5H" ] && [ -n "$FIVE_H" ]; then
  _rate_dropped=true
  SEG_5H="${SEP}${C_GRAY}5h $(make_bar "$FIVE_H" "$_cur_bar") $(pct_color "$FIVE_H")${P5}%"
fi
# 8. 7d -> text
if _over && [ -n "$SEG_7D" ]; then
  SEG_7D="$SEG_7D_SHORT"
fi
# 9. 7d remove
if _over; then SEG_7D=""; fi
# 10. 5h -> text
if _over && [ -n "$SEG_5H" ]; then
  SEG_5H="$SEG_5H_SHORT"
fi
# 11. 5h remove
if _over; then SEG_5H=""; fi

OUT="${OUT}${SEG_5H}${SEG_7D}${SEG_CACHE}"

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
    _parts=""
    for (( _i=0; _i<_reg_count; _i++ )); do
      (( _i > 0 )) && _parts+="${C_GRAY},"
      _tf=$(fmt_tok "${_reg_toks[$_i]}")
      _parts+=" ${C_GRAY}${_reg_descs[$_i]} ${C_MODEL}${_tf}"
      if [ -n "${_reg_rates[$_i]}" ] && [ "${_reg_rates[$_i]}" != "0" ]; then
        _rf=$(awk "BEGIN { n=${_reg_rates[$_i]}; if(n>=1000) printf \"%.0fk\", n/1000; else printf \"%.0f\", n }")
        _parts+=" $(agent_rate_color "${_reg_rates[$_i]}")${_rf}/m"
      fi
      if ! $_all_same && [ -n "${_reg_models[$_i]}" ]; then
        _parts+=" ${C_DIM}(${_reg_models[$_i]})"
      fi
    done
    AGENTS_LINE="${_header}${_parts}"
  fi

  for (( _i=0; _i<_wf_count; _i++ )); do
    _tf=$(fmt_tok "${_wf_toks[$_i]}")
    _wl="${C_GRAY}→ ${_wf_descs[$_i]} ${C_DIM}(${_wf_subcounts[$_i]} agents) ${C_MODEL}${_tf}"
    if [ -n "${_wf_rates[$_i]}" ] && [ "${_wf_rates[$_i]}" != "0" ]; then
      _rf=$(awk "BEGIN { n=${_wf_rates[$_i]}; if(n>=1000) printf \"%.0fk\", n/1000; else printf \"%.0f\", n }")
      _wl+=" $(agent_rate_color "${_wf_rates[$_i]}")${_rf}/m"
    fi
    [ -n "${_wf_models[$_i]}" ] && _wl+=" ${C_DIM}(${_wf_models[$_i]})"
    WORKFLOW_LINES+=$'\n'"${_wl}"

    _pj="${_wf_phases[$_i]}"
    if [ -n "$_pj" ] && [ "$_pj" != "[]" ]; then
      _phase_line="   "
      _pn=$(echo "$_pj" | jq -r 'length' 2>/dev/null)
      for (( _pi=0; _pi<_pn; _pi++ )); do
        _pt=$(echo "$_pj" | jq -r ".[$_pi].t" 2>/dev/null)
        _pd=$(echo "$_pj" | jq -r ".[$_pi].d" 2>/dev/null)
        _pc=$(echo "$_pj" | jq -r ".[$_pi].n" 2>/dev/null)
        (( _pi > 0 )) && _phase_line+="  "
        _phase_line+="${C_DIM}${_pt} ${C_GRAY}${_pd}/${_pc}"
        if (( _pc > 0 && _pd == _pc )); then
          _phase_line+=" $(fg 152 195 121)✓"
        fi
      done
      WORKFLOW_LINES+=$'\n'"${_phase_line}"
    fi
  done
fi

# ── Output ───────────────────────────────────────────────
printf '%s%s' "$OUT" "$RST"
[ -n "$AGENTS_LINE" ] && printf '\n%s%s' "$AGENTS_LINE" "$RST"
[ -n "$WORKFLOW_LINES" ] && printf '%s%s' "$WORKFLOW_LINES" "$RST"
exit 0
