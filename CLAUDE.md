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
- `sl_test.ps1` — additional test harness
- `statusline.png` — reference screenshot

## Architecture

The script receives JSON on stdin from Claude Code with session state (model, context window, rate limits, workspace, transcript path) and outputs one or more ANSI-colored lines.

### Two-tier refresh

Full compute (transcript parsing, git branch, agent scanning) runs every `$FULL_INTERVAL` (10s) or `$AGENT_INTERVAL` (5s when agents are active). Between full computes, cheap ticks read from a per-session cache file (`.sl_compute_<sessionId>`) and only update the cache countdown.

### Segments (left to right)

1. **Model** — display name, optional `[1M]` marker for 1M context, effort level
2. **Cache** — countdown timer (`cache 4m5s` or collapsed `4m5s`)
3. **Project** — folder emoji, project name, git branch or "(untracked)"
4. **Diff** — `+N/-M` lines added/removed (only when in git)
5. **Shell** — hourglass + elapsed time + description for in-flight Bash/PowerShell commands (`⏳ 45s Install deps`), shown only after 3s; multiplier shown for parallel calls (`×2`)
6. **Context** — token count, progress bar, percentage
7. **5h rate** — progress bar, percentage, optional rate-of-change `(↑N%/hr)`
8. **7d rate** — progress bar, percentage

### Collapse cascade

When the rendered line exceeds `$WIDTH - 4`, steps fire in order until it fits. Each step fires only if still over width:

| Step | What | Saves |
|------|------|-------|
| 1 | `cache 4m5s` -> `4m5s` | 6 chars |
| 2 | Shell description dropped, timer only | ~20 chars |
| 3 | ` [1M]` removed from model | 5 chars |
| 4-7 | Bars squeeze 8->7->6->5->4 | ~3 chars/step (1 per visible bar) |
| 8 | 5h rate string `(↑N%/hr)` dropped | ~10 chars |
| 9 | All bars (ctx, 5h, 7d) -> text-only | ~20 chars |
| 10 | 7d removed entirely | ~10 chars |
| 11 | 5h removed entirely | ~10 chars |

When collapsed, only the countdown is shown with no prefix. Bars squeeze by 1 char at a time (recovering ~3 chars per step across all visible bars) down to minimum width 4 (half of the default 8). After squeezing, all three bars (ctx, 5h, 7d) convert to text-only in a single step before any segment is removed entirely.

The `rebuildBars` function preserves existing collapse state via `$script:rateDropped` so squeezing bars doesn't re-attach a previously dropped rate string.

### Active repo detection

When `project_dir` is not a git repo (or the transcript shows work in a different repo), the statusline overrides the project name and branch. During the 64KB tail scan, it captures the most recent transcript entry whose `cwd` differs from `project_dir` and has a non-empty `gitBranch`. These values (`$activeDir`, `$activeBranch`) are stored in the compute cache. At display time, if the active repo differs from `project_dir` (or `project_dir` has no git branch), the active repo's leaf name and branch replace the defaults. When the 64KB tail no longer contains diverging entries, the override clears and normal behavior resumes.

### Terminal title

The script emits an OSC escape sequence (`ESC]0;...BEL`) before each render to set the terminal title bar to `spinner project | sid` (first 8 chars of session ID). When idle, the spinner shows `✦`. When running (shell or agents active), it cycles through braille frames (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) using `Floor($now / $REFRESH_INTERVAL) % frameCount`, advancing one frame per refresh with no state file. The OSC sequence is written as a separate `[Console]::Write` call so `visLen` never sees it. The test harness strips OSC sequences via `$oscRe`.

### Cache timer format

No leading zeros on seconds: `4m5s`, `55m4s`, `5m0s` (not `4m05s`, `55m04s`).

### OAuth usage

When Claude Code doesn't provide `rate_limits` in the JSON (common when using an API key, even through a proxy), the script fetches from `https://api.anthropic.com/api/oauth/usage` using the token from `.credentials.json`. Only one session owns the fetch (lock file `.sl_oauth_owner`), throttled to one attempt per `$OAUTH_TTL` (60s). The fetch is synchronous (typically <200ms) since background jobs (`Start-Job`) die when the statusline process exits.

### Rate-of-change tracking

5h usage samples are recorded to `.statusline_rate_history` at most once per `$OAUTH_TTL` (60s). The `calcRate` function computes percentage-per-hour over the last 30 minutes, requiring at least 2 minutes of data.

### Shell timer

Detects in-flight Bash/PowerShell tool calls by scanning the last 16KB of the transcript. Handles parallel tool calls: scans backward collecting `tool_result` IDs until reaching the `assistant` message, then checks which shell `tool_use` entries have no matching result. The elapsed timer updates every tick since it's computed from `$now - $shellEpoch`. Only shown after 3 seconds of runtime. Description is truncated to 30 characters in the collapse cascade.

### Agent line wrapping

When the regular agents line exceeds `$MAX_W`, individual agent entries wrap to subsequent lines. The header (`N agents (Model):`) appears on the first line, and continuation lines are indented to align with the first agent entry. Each line respects `$MAX_W`.

### Agent tracking

Regular agents are detected under `<transcript>/subagents/agent-*.meta.json` with corresponding `.jsonl` files. Only agents active in the last 120 seconds are shown. Token counting uses incremental parsing: per-agent byte offsets are cached in `.sl_agents_<sessionId>` so only new bytes are read.

### Workflow tracking

Workflow subagents live under `<transcript>/subagents/workflows/wf_<id>/agent-*.jsonl`. The workflow name is resolved from the state file (`<transcript>/workflows/<wfId>.json`) or the script file (`<transcript>/workflows/scripts/<name>-<wf_id>.js`). Tokens are aggregated across all sub-agents in the workflow. Each workflow renders as two lines: a one-liner summary and a phase breakdown:

```
→ deep-research (105 agents) 149k 12k/m (Sonnet)
   Scope 1/1 ✓  Search 5/5 ✓  Fetch 23/23 ✓  Verify 75/75 ✓  Synthesize 0/1
```

Phase breakdown uses two strategies: for completed/running workflows with a state file, it reads `workflowProgress` entries directly; for running workflows without state, it parses `meta.phases` from the script and infers agent-to-phase mapping from `journal.jsonl` (detecting phase boundaries when a "started" event follows a "result" event). Phase and completion state are cached per-agent in `.sl_agents_<sid>`. If all phases have zero agents, the phase line is omitted.

The `Workflow`, `SubCount`, and `Phases` fields on agent data distinguish workflow entries from regular agents.

### Resume line

When `$SHOW_RESUME_LINE` is `$true` (default), a second line shows a copy-pasteable resume command: `cmd /c "cd /d <projectDir> && claude --resume <sessionId>"` (Windows paths) or `cd <projectDir> && claude --resume <sessionId>` (Unix paths).

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
| `.statusline_usage_cache` | Cached OAuth usage response (JSON) |
| `.statusline_rate_history` | 5h usage samples for rate-of-change |

GC runs at most every 5 minutes, removing `.sl_*` files for sessions whose PIDs are no longer running.

## PowerShell gotchas

- **`$pid` is read-only.** PowerShell reserves `$pid`, `$null`, `$true`, `$false`, `$args`, `$input`, `$this`, `$_`, `$PSItem`, `$Error`, `$Host`, `$Profile`, and other automatic variables. Function parameters must not shadow them; the assignment silently throws and the parameter stays at its type default. The `claimLock` function uses `$callerPid` for this reason.
- **`Start-Job` dies with parent.** Background jobs are child threads of the pwsh process; when the statusline process exits (every render cycle), pending jobs are killed. Use synchronous calls gated behind throttle files, or `Start-Process` for truly detached work.

## Testing

Both scripts have a test harness in this directory. Each creates temp copies with `$WIDTH` patched, sets up per-session cache state (36m7s remaining of 1h TTL), pipes mock JSON (Opus 4.6 1M, max effort, 5% context, 18% 5h, 34% 7d), and checks `len <= max` for every width from 140 down to 76. Cache timer formatting is also verified. All temp files are cleaned up.

- **PowerShell**: `pwsh -NoProfile -File test_cascade.ps1`
- **Bash**: `bash test_cascade.sh`

All lines must fit within `$WIDTH - 4`. Any overflow reports as `OVER` and exits with code 1.

Note: the bash `vis_len` function uses sed to replace known multi-byte characters (▓ ░ 📁 ↑ ↓ → ✓) with single-byte placeholders before `wc -c`, because MSYS2/Git Bash does not count UTF-8 characters correctly with `awk length` or `wc -m`.

## Parity: statusline.sh

The Bash implementation is behind the PowerShell version. Both have: no-leading-zero cache timer, full collapse cascade, proportional bar squeezing, workflow detection with 120s recency filter. PowerShell-only: workflow phase breakdown, shell timer, agent line wrapping, resume line.

Only backport changes to the Bash version when explicitly asked.
