#Requires -Version 7
# Test harness for statusline collapse cascade
# Patches $WIDTH in a temp copy of statusline.ps1, pipes mock JSON, checks every line fits.
# Usage: pwsh -NoProfile -File test_cascade.ps1
param()
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ansiRe = [regex]'\x1b\[[0-9;]*m'
$oscRe  = [regex]'\x1b\]0;[^\x07]*\x07'
function strip($s) { $oscRe.Replace($ansiRe.Replace($s, ''), '') }

$claudeDir = "$env:USERPROFILE\.claude"
$scriptPath = "$PSScriptRoot\statusline.ps1"
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$src = Get-Content $scriptPath -Raw

$base = @{
    model = @{ display_name = "Opus 4.6 (1M context)" }
    effort = @{ level = "max" }
    context_window = @{ used_percentage = 5; context_window_size = 1000000 }
    rate_limits = @{ five_hour = @{ used_percentage = 18.2 }; seven_day = @{ used_percentage = 34.1 } }
    workspace = @{ project_dir = "C:\Users\Rod\Desktop" }
    cwd = "C:\Users\Rod\Desktop"
}

$failures = 0
$widths = @(140, 130, 125, 122, 118, 115, 112, 110, 108, 105, 102, 100, 97, 95, 92, 90, 88, 85, 82, 80, 78, 76)
$totalSw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($w in $widths) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $sid = "test-cascade-$w"
    $epoch = $now - (36 * 60 + 7)
    "$epoch 3600" | Set-Content "$claudeDir\.sl_cache_$sid" -NoNewline
    Remove-Item "$claudeDir\.sl_compute_$sid" -Force -ErrorAction SilentlyContinue
    Remove-Item "$claudeDir\.sl_mtime_$sid" -Force -ErrorAction SilentlyContinue

    $base['transcript_path'] = "$claudeDir\$sid.jsonl"

    $patched = $src -replace '(?m)^\$WIDTH\s*=\s*\d+', "`$WIDTH = $w"
    $tmp = "$claudeDir\.test_w$w.ps1"
    $patched | Set-Content $tmp -NoNewline

    $json = $base | ConvertTo-Json -Depth 5
    $out = $json | pwsh -NoProfile -File $tmp 2>$null
    $lines = $out -split "`n"
    $s = strip $lines[0]
    if ($LASTEXITCODE -ne 0 -or $s -notmatch '\| (?:cache )?\d+m\d+s \| (?:🟢|⚪) 📁 ') {
        $failures++
        Write-Output "FAIL: cache must immediately precede folder at width $w"
    }
    $maxW = $w - 4
    $over = $s.Replace("`u{26AA}", "XX").Length - $maxW
    $tag = if ($over -le 0) { "  OK" } else { $failures++; "OVER" }

    $ms = $sw.ElapsedMilliseconds
    Write-Output ("W={0,3} max={1,3} len={2,3} [{3}] {4,5}ms: {5}" -f $w, $maxW, $s.Length, $tag, $ms, $s)

    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Remove-Item "$claudeDir\.sl_cache_$sid" -Force -ErrorAction SilentlyContinue
    Remove-Item "$claudeDir\.sl_compute_$sid" -Force -ErrorAction SilentlyContinue
    Remove-Item "$claudeDir\.sl_mtime_$sid" -Force -ErrorAction SilentlyContinue
}

$totalMs = $totalSw.ElapsedMilliseconds
Write-Output ""
Write-Output ("Cascade: {0} widths in {1}ms (avg {2}ms)" -f $widths.Count, $totalMs, [math]::Round($totalMs / $widths.Count))

Write-Output ""
# Cache timer format verification
$cases = @(
    @(245,  "4m5s"),
    @(3304, "55m4s"),
    @(300,  "5m0s"),
    @(59,   "59s"),
    @(0,    $null)
)
$timerOk = $true
foreach ($c in $cases) {
    $remain = $c[0]; $expect = $c[1]
    $m = [math]::Floor($remain / 60); $s = $remain % 60
    $got = if ($remain -gt 0) { if ($m -gt 0) { "${m}m${s}s" } else { "${s}s" } } else { $null }
    $pass = $got -eq $expect
    if (-not $pass) { $timerOk = $false; $failures++ }
    $tag = if ($pass) { "PASS" } else { "FAIL" }
    Write-Output "Timer ${remain}s -> '${got}' expect '${expect}' [$tag]"
}

# ── Workflow phase progress test ─────────────────────────
Write-Output ""
Write-Output "Workflow phase progress:"

$wfSid = "test-wf-phases"
$wfSessionDir = "$claudeDir\projects\test-wf-session\$wfSid"
$wfTranscript = "$wfSessionDir.jsonl"
$wfSubagentsDir = "$wfSessionDir\subagents\workflows\wf_test123"
$wfScriptDir = "$wfSessionDir\workflows\scripts"

# Create mock directory structure
New-Item -ItemType Directory -Path $wfSubagentsDir -Force | Out-Null
New-Item -ItemType Directory -Path $wfScriptDir -Force | Out-Null

# Create the mock workflow script with phases
@"
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
"@ | Set-Content "$wfScriptDir\test-workflow-wf_test123.js"

# Create journal: 3 Find agents start, 2 complete, then 2 Verify agents start, 1 completes
$journalLines = @(
    '{"type":"started","key":"k1","agentId":"agent-a1"}'
    '{"type":"started","key":"k2","agentId":"agent-a2"}'
    '{"type":"started","key":"k3","agentId":"agent-a3"}'
    '{"type":"result","key":"k1","agentId":"agent-a1","result":{}}'
    '{"type":"result","key":"k2","agentId":"agent-a2","result":{}}'
    '{"type":"result","key":"k3","agentId":"agent-a3","result":{}}'
    '{"type":"started","key":"k4","agentId":"agent-a4"}'
    '{"type":"started","key":"k5","agentId":"agent-a5"}'
    '{"type":"result","key":"k4","agentId":"agent-a4","result":{}}'
)
$journalLines -join "`n" | Set-Content "$wfSubagentsDir\journal.jsonl"

# Create mock agent jsonl files (recent mtime so they pass the 120s freshness check)
$ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
foreach ($aid in @('a1','a2','a3','a4','a5')) {
    $meta = '{"agentType":"workflow-subagent"}'
    $meta | Set-Content "$wfSubagentsDir\agent-${aid}.meta.json"
    $content = "{`"message`":{`"role`":`"user`",`"content`":`"test`"},`"timestamp`":`"$ts`"}`n"
    $content += "{`"message`":{`"role`":`"assistant`",`"model`":`"claude-sonnet-4-6`",`"usage`":{`"output_tokens`":500},`"content`":`"ok`"},`"timestamp`":`"$ts`"}"
    $content | Set-Content "$wfSubagentsDir\agent-${aid}.jsonl"
}

# Create a minimal transcript file so the statusline finds it
"" | Set-Content $wfTranscript

# Prepare mock JSON for statusline
$wfBase = @{
    model = @{ display_name = "Opus 4.8" }
    effort = @{ level = "xhigh" }
    context_window = @{ used_percentage = 10; context_window_size = 1000000 }
    workspace = @{ project_dir = "C:\test\project" }
    transcript_path = $wfTranscript
}

Remove-Item "$claudeDir\.sl_compute_$wfSid" -Force -ErrorAction SilentlyContinue
Remove-Item "$claudeDir\.sl_agents_$wfSid" -Force -ErrorAction SilentlyContinue

$wfPatched = $src -replace '(?m)^\$WIDTH\s*=\s*\d+', '$WIDTH = 160'
$wfTmp = "$claudeDir\.test_wf.ps1"
$wfPatched | Set-Content $wfTmp -NoNewline

$wfJson = $wfBase | ConvertTo-Json -Depth 5
$wfOut = $wfJson | pwsh -NoProfile -File $wfTmp 2>$null
$wfLines = $wfOut -split "`n"

Write-Output "Output lines:"
foreach ($l in $wfLines) { Write-Output "  $(strip $l)" }

# Check: should have a workflow line and a phase line
$hasWorkflowLine = $false
$hasPhaseFind = $false
$hasPhaseVerify = $false
foreach ($l in $wfLines) {
    $plain = strip $l
    if ($plain -match '(test-workflow|wf_test123).*agents') { $hasWorkflowLine = $true }
    if ($plain -match 'Find\s+\d+/\d+') { $hasPhaseFind = $true }
    if ($plain -match 'Verify\s+\d+/\d+') { $hasPhaseVerify = $true }
}

$wfTests = @(
    @("Workflow line present", $hasWorkflowLine),
    @("Find phase shown",     $hasPhaseFind),
    @("Verify phase shown",   $hasPhaseVerify)
)
foreach ($t in $wfTests) {
    $tag = if ($t[1]) { "PASS" } else { $failures++; "FAIL" }
    Write-Output "$($t[0]) [$tag]"
}

# Cleanup
Remove-Item $wfTmp -Force -ErrorAction SilentlyContinue
Remove-Item "$claudeDir\.sl_compute_$wfSid" -Force -ErrorAction SilentlyContinue
Remove-Item "$claudeDir\.sl_agents_$wfSid" -Force -ErrorAction SilentlyContinue
Remove-Item "$claudeDir\projects\test-wf-session" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $wfTranscript -Force -ErrorAction SilentlyContinue

Write-Output ""
if ($failures -eq 0) { Write-Output "All tests passed." }
else { Write-Output "$failures failure(s)."; exit 1 }
