# Statusline

Custom Claude Code status bar rendered by a hook in `~/.claude/settings.json`:
```json
"statusLine": {
  "type": "command",
  "command": "pwsh -NoProfile -File ~/.claude/statusline/statusline.ps1",
  "refreshInterval": 4
}
```

## Files

- `statusline.ps1` — PowerShell 7 implementation (primary, Windows)
- `statusline.sh` — Bash implementation (secondary, not kept in sync; see Parity section)
- `test_cascade.ps1` — test harness for collapse cascade and timer formatting
- `statusline.png` — reference screenshot

## Architecture

The script receives JSON on stdin from Claude Code with session state (model, context window, rate limits, workspace, transcript path) and outputs one or more ANSI-colored lines.

### Two-tier refresh

Full compute (transcript parsing, git branch, agent scanning) runs every `$FULL_INTERVAL` (10s) or `$AGENT_INTERVAL` (5s when agents are active). Between full computes, cheap ticks read from a per-session cache file (`.sl_compute_<sessionId>`) and only update the cache countdown.

### Segments (left to right)

1. **Model** — display name, optional `[1M]` marker for 1M context, effort level
2. **Project** — folder emoji, project name, git branch or "(untracked)"
3. **CWD** — relative path if different from project root
4. **Diff** — `+N/-M` lines added/removed
5. **Shell** — hourglass + elapsed time + description for in-flight Bash/PowerShell commands (`⏳ 45s Install deps`), shown only after 3s
6. **Context** — token count, progress bar, percentage
7. **5h rate** — progress bar, percentage, optional rate-of-change `(↑N%/hr)`
8. **7d rate** — progress bar, percentage
9. **Cache** — countdown timer (`cache 4m5s` or collapsed `-4m5s`)

### Collapse cascade

When the rendered line exceeds `$WIDTH - 4`, steps fire in order until it fits. Each step fires only if still over width:

| Step | What | Saves |
|------|------|-------|
| 1 | `cache 4m5s` -> `4m5s` | 6 chars |
| 2 | Shell description dropped, timer only | ~20 chars |
| 3 | ` [1M]` removed from model | 5 chars |
| 4-7 | Bars squeeze 8->7->6->5->4 | ~3 chars/step (1 per visible bar) |
| 8 | 5h rate string `(↑N%/hr)` dropped | ~10 chars |
| 9 | 7d bar -> text-only `7d: N%` | ~8 chars |
| 10 | 7d removed entirely | ~10 chars |
| 11 | 5h bar -> text-only `5h: N%` | ~8 chars |
| 12 | 5h removed entirely | ~10 chars |

When collapsed, only the countdown is shown with no prefix. Bars squeeze by 1 char at a time (recovering ~3 chars per step across all visible bars) down to minimum width 4 (half of the default 8).

The `rebuildBars` function preserves existing collapse state via `$script:rateDropped` so squeezing bars doesn't re-attach a previously dropped rate string.

### Active repo detection

When `project_dir` is not a git repo (or the transcript shows work in a different repo), the statusline overrides the project name and branch. During the 64KB cache scan, it captures the most recent transcript entry whose `cwd` differs from `project_dir` and has a non-empty `gitBranch`. These values (`$activeDir`, `$activeBranch`) are stored in the compute cache. At display time, if the active repo differs from `project_dir` (or `project_dir` has no git branch), the active repo's leaf name and branch replace the defaults. When the 64KB tail no longer contains diverging entries, the override clears and normal behavior resumes.

### Terminal title

The script emits an OSC escape sequence (`ESC]0;...BEL`) before each render to set the terminal title bar to `spinner project | sid` (first 8 chars of session ID). When idle, the spinner shows `✦`. When running (shell or agents active), it cycles through braille frames (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) using `Floor($now / $REFRESH_INTERVAL) % frameCount`, advancing one frame per refresh with no state file. The OSC sequence is written as a separate `[Console]::Write` call so `visLen` never sees it. The test harness strips OSC sequences via `$oscRe`.

### Cache timer format

No leading zeros on seconds: `4m5s`, `55m4s`, `5m0s` (not `4m05s`, `55m04s`).

### OAuth usage

When Claude Code doesn't provide `rate_limits` in the JSON, the script fetches from `https://api.anthropic.com/api/oauth/usage` using the token from `.credentials.json`. Only one session owns the fetch (lock file `.sl_oauth_owner`), and it runs as a background job to avoid blocking rendering.

### Rate-of-change tracking

5h usage samples are recorded to `.statusline_rate_history` at most once per `$OAUTH_TTL` (60s). The `calcRate` function computes percentage-per-hour over the last 30 minutes, requiring at least 2 minutes of data.

### Shell timer

Detects in-flight Bash/PowerShell tool calls by scanning the last 16KB of the transcript. If the last entry with a `message.role` is an `assistant` with a `tool_use` for Bash or PowerShell (no subsequent `tool_result`), the shell epoch and description are cached. The elapsed timer updates every tick since it's computed from `$now - $shellEpoch`. Only shown after 3 seconds of runtime. Description is truncated to 30 characters in the collapse cascade.

### Agent line wrapping

When the regular agents line exceeds `$MAX_W`, individual agent entries wrap to subsequent lines. The header (`N agents (Model):`) appears on the first line, and continuation lines are indented to align with the first agent entry. Each line respects `$MAX_W`.

### Agent tracking

Regular agents are detected under `<transcript>/subagents/agent-*.meta.json` with corresponding `.jsonl` files. Only agents active in the last 120 seconds are shown. Token counting uses incremental parsing: per-agent byte offsets are cached in `.sl_agents_<sessionId>` so only new bytes are read.

### Workflow tracking

Workflow subagents live under `<transcript>/subagents/workflows/wf_<id>/agent-*.jsonl`. The workflow name is resolved from `<transcript>/workflows/scripts/<name>-<wf_id>.js`. Tokens are aggregated across all sub-agents in the workflow. Each workflow renders as two lines: a one-liner summary and a phase breakdown:

```
→ deep-research (105 agents) 149k 12k/m (Sonnet)
   Scope 1/1 ✓  Search 5/5 ✓  Fetch 23/23 ✓  Verify 75/75 ✓  Synthesize 0/1
```

Phase breakdown is derived by parsing `meta.phases` from the workflow script, then classifying each agent by matching its first user message against known prompt prefixes (e.g. `## Web Searcher` -> Search, `## Source Extractor` -> Fetch). Phase and completion state are cached per-agent in `.sl_agents_<sid>`. If >50% of agents can't be classified, the phase line is omitted and only the one-liner is shown.

The `Workflow`, `SubCount`, and `Phases` fields on agent data distinguish workflow entries from regular agents.

### Per-session state files

All prefixed with `.sl_` in `~/.claude/`:

| Pattern | Purpose |
|---------|---------|
| `.sl_compute_<sid>` | Full compute cache (JSON) |
| `.sl_cache_<sid>` | Cache epoch and TTL |
| `.sl_mtime_<sid>` | Transcript mtime for change detection |
| `.sl_agents_<sid>` | Per-agent token/size cache |
| `.sl_rate_last_write` | Throttle for rate history writes |
| `.sl_last_gc` | Throttle for GC of stale session files |
| `.sl_oauth_owner` | Lock file for OAuth fetch ownership |
| `.sl_oauth_last_attempt` | Throttle for OAuth fetch attempts |

GC runs at most every 5 minutes, removing `.sl_*` files for sessions whose PIDs are no longer running.

## Testing

Both scripts have a test harness in this directory. Each creates temp copies with `$WIDTH` patched, sets up per-session cache state (36m7s remaining of 1h TTL), pipes mock JSON (Opus 4.6 1M, max effort, 5% context, 18% 5h, 34% 7d), and checks `len <= max` for every width from 140 down to 76. Cache timer formatting is also verified. All temp files are cleaned up.

- **PowerShell**: `pwsh -NoProfile -File test_cascade.ps1`
- **Bash**: `bash test_cascade.sh`

All lines must fit within `$WIDTH - 4`. Any overflow reports as `OVER` and exits with code 1.

Note: the bash `vis_len` function uses sed to replace known multi-byte characters (▓ ░ 📁 ↑ ↓ → ✓) with single-byte placeholders before `wc -c`, because MSYS2/Git Bash does not count UTF-8 characters correctly with `awk length` or `wc -m`.

## Parity: statusline.sh

The Bash implementation is behind the PowerShell version. Both have: no-leading-zero cache timer, full collapse cascade, proportional bar squeezing, workflow detection with 120s recency filter. PowerShell-only: workflow phase breakdown, shell timer, agent line wrapping.

Only backport changes to the Bash version when explicitly asked.
