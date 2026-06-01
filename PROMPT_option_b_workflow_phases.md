# Prompt: Add workflow phase breakdown (Option B) to statusline

## Context

The statusline at `~/.claude/statusline/statusline.ps1` already renders workflow one-liners (Option A):

```
→ deep-research (105 agents) 149k 12k/m (Sonnet)
```

This was implemented by scanning `<transcript>/subagents/workflows/wf_<id>/agent-*.jsonl` and aggregating tokens across all sub-agents. The workflow name is resolved from `<transcript>/workflows/scripts/<name>-<wf_id>.js`. See `~/.claude/statusline/CLAUDE.md` for full architecture.

## Task

Add a second line under each workflow one-liner showing phase progress:

```
→ deep-research (105 agents) 149k 12k/m (Sonnet)
   Scope 1/1 ✓  Search 5/5 ✓  Fetch 15/15 ✓  Verify 75/75 ✓  Synth 0/1
```

### Data sources

The workflow script at `<transcript>/workflows/scripts/<name>-<wf_id>.js` contains everything needed:

1. **Phase list**: `export const meta = { phases: [{title: "Scope"}, {title: "Search"}, ...] }` at the top of the script. This is a pure JSON literal, safe to extract with regex or `jq`.

2. **Agent-to-phase mapping**: Each `agent()` call has a `phase` option that names which phase it belongs to. Examples from deep-research:
   - `{ label: "scope", phase: undefined }` (defaults to current phase set by `phase("Scope")`)
   - `{ label: "search:...", phase: "Search" }`
   - `{ label: "fetch:...", phase: "Fetch" }`
   - `{ label: "v0:...", phase: "Verify" }`
   - `{ label: "synthesize", phase: undefined }` (under `phase("Synthesize")`)

3. **Agent-to-label mapping**: The `label` option on `agent()` calls also encodes the phase as a prefix. The label prefix before `:` maps to a phase: `search:` -> Search, `fetch:` -> Fetch, `v0:`/`v1:`/`v2:` -> Verify. For agents without explicit `phase`, the last `phase("...")` call before them sets the context.

4. **Completion detection**: An agent's `.jsonl` file exists once spawned. Completion can be detected by the presence of a final assistant message (the agent's return value). A pragmatic heuristic: if the file hasn't been modified in >30 seconds and has at least one assistant message with `usage.output_tokens`, it's done.

### The problem: labels aren't persisted in agent metadata

The `agent-*.meta.json` files only contain `{"agentType":"workflow-subagent"}`. The `label` and `phase` fields are NOT stored there. So mapping agents to phases requires one of:

**Approach A (recommended): Parse the workflow script to extract phase structure, then match agents by prompt content.**

1. Read `<transcript>/workflows/scripts/<name>-<wf_id>.js`
2. Extract `meta.phases` array (regex for the JSON array after `phases:`)
3. For each `agent-*.jsonl`, read the first line (user message) and match against known prompt patterns:
   - Contains `"Decompose this research"` -> Scope
   - Contains `"## Web Searcher:"` -> Search
   - Contains `"## Source Extractor"` -> Fetch
   - Contains `"## Adversarial Claim Verifier"` -> Verify
   - Contains `"## Synthesis"` -> Synthesize

This is fragile for arbitrary workflows. A better generic approach:

**Approach B (recommended, generic): Extract `label:` values from the script, build a label->phase map, then match agents by scanning each jsonl's first user message for those label substrings.**

1. Parse the workflow script to find all `agent(...)` calls and extract their `label` and `phase` options
2. Also track `phase("...")` calls to know the implicit phase for agents without explicit `phase`
3. For each agent jsonl, read the first user message and match against label strings from the prompt text. The prompt text in the jsonl IS the first argument to `agent()`, so specific substrings from the script's prompts can be matched.

Actually, the most robust approach:

**Approach C (simplest, most robust): Parse the script for `phase()` calls to get the phase sequence, then count agents by creation order.**

The workflow runtime executes `agent()` calls in order (respecting `pipeline`/`parallel` boundaries). Since `phase("Title")` is called before each group of agents, you can build an ordered list of phases with expected agent counts by static analysis of the script:
- `phase("Scope")` followed by 1 `agent()` call -> Scope expects 1
- `phase("Search")` block -> count the pipeline/parallel items
- etc.

But this requires understanding the script's control flow, which is too complex for static analysis.

**Recommended implementation: Approach B with fallback.**

Parse the script for `phase()` calls and `agent()` calls with `label`/`phase` options. For each agent jsonl, read the first line's `message.content` and try to match it against patterns derived from the script's agent prompts. If matching fails for any agent, fall back to showing just the Option A one-liner (no phase line).

### Implementation details

In `statusline.ps1`, the workflow scanning happens around line 440+ (search for `# ── Workflow subagents`). Currently it iterates `agent-*.jsonl` files and aggregates tokens. Extend this to also:

1. Read the workflow script once per workflow (cache the parsed phase map in `.sl_agents_<sessionId>`)
2. For each agent jsonl, read only the first line (already partially done for `$firstTs`), extract the user message content, and classify it into a phase
3. Track per-phase: agent count and completed count
4. Store the phase breakdown in the `$agentsData` entry (new field `Phases`)

For rendering (around line 700+, search for `foreach ($wf in $workflows)`), add a second line after the workflow one-liner:

```powershell
$phaseSegs = foreach ($ph in $wf.Phases) {
    $mark = if ($ph.Done -eq $ph.Total) { " `u{2713}" } else { "" }
    "${cDim}$($ph.Short) ${cGray}$($ph.Done)/$($ph.Total)${mark}"
}
$workflowLines += "   " + ($phaseSegs -join "  ")
```

Use abbreviated phase names (first 5 chars) if the full names make the line too long.

### Fallback

If the workflow script can't be read, or the `meta.phases` can't be parsed, or agent-to-phase matching fails for >50% of agents, skip the phase line entirely and show only the Option A one-liner. The one-liner already works and must not be broken.

### Cache considerations

Phase classification only needs to happen during full compute ticks (when `$doFullCompute` is true). The results should be stored in `writeComputeCache` alongside the existing agent data. On cheap ticks, read from cache.

### Testing

The test harness is at `~/.claude/statusline/test_cascade.ps1`. A real workflow session exists at `C:\Users\Rod\.claude\projects\C--Users-Rod-Desktop\c1d84942-6b6d-49d4-bf29-9e330bb96187\` with 105 agents across 5 phases (Scope 1, Search 5, Fetch ~15, Verify ~75, Synthesize 1). Use this to validate rendering. The workflow script is at `workflows/scripts/deep-research-wf_4753f5a0-e26.js` and subagent data under `subagents/workflows/wf_4753f5a0-e26/`.
