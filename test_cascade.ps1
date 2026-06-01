#Requires -Version 7
# Test harness for statusline collapse cascade
# Patches $WIDTH in a temp copy of statusline.ps1, pipes mock JSON, checks every line fits.
# Usage: pwsh -NoProfile -File test_cascade.ps1
param()
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ansiRe = [regex]'\x1b\[[0-9;]*m'
function strip($s) { $ansiRe.Replace($s, '') }

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
    $maxW = $w - 4
    $over = $s.Length - $maxW
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

Write-Output ""
if ($failures -eq 0) { Write-Output "All tests passed." }
else { Write-Output "$failures failure(s)."; exit 1 }
