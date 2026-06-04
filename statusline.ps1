#Requires -Version 7

# Claude Code statusline — PowerShell 7 version
# Two-tier refresh: full compute every N seconds, cheap ticks in between
# Adaptive agent refresh: full compute more often when agents are active

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ── Tuning constants ────────────────────────────────────
$WIDTH            = 120     # terminal width (default 120)
$OAUTH_TTL        = 60      # seconds between OAuth usage API calls
$FULL_INTERVAL    = 10      # seconds between full recomputes (no agents)
$AGENT_INTERVAL   = 5       # seconds between full recomputes (agents active)

$rawInput = [Console]::In.ReadToEnd()
if (-not $rawInput) { exit 0 }
try { $d = $rawInput | ConvertFrom-Json -ErrorAction Stop }
catch { exit 0 }

# ── Colors ───────────────────────────────────────────────
$e = [char]27
function fg($r,$g,$b) { "$e[38;2;${r};${g};${b}m" }

$cModel = fg 113 172 255
$cProj  = fg 255 215 90
$cAdd   = fg 152 195 121
$cDel   = fg 210 110 130
$cGray  = fg 170 170 176
$cDim   = fg 100 100 115
$cSep   = fg 60 60 80
$cBar   = fg 170 170 176
$cBarE  = fg 100 100 108
$rst    = "$e[0m"
$sep    = " ${cSep}| "

# ── Helpers ──────────────────────────────────────────────
function tierColor([double]$v, [double[]]$thresholds) {
    $v = [math]::Round($v)
    $colors = @((fg 185 255 164), (fg 255 241 150), (fg 255 184 120), (fg 255 144 144))
    for ($i = $thresholds.Count - 1; $i -ge 0; $i--) {
        if ($v -ge $thresholds[$i]) { return $colors[$i + 1] }
    }
    return $colors[0]
}

function makeBar([double]$pct, [int]$w = 8) {
    $f = [math]::Min([math]::Max([math]::Round($pct * $w / 100), 0), $w)
    "${cBar}$([string]::new([char]0x2593, $f))${cBarE}$([string]::new([char]0x2591, $w - $f))"
}

function fmtTok([double]$n) {
    if     ($n -ge 1000000) { "{0:F1}M" -f ($n / 1e6) }
    elseif ($n -ge 1000)    { "{0:F0}k" -f ($n / 1000) }
    else                    { "0k" }
}

$script:_ansiRe = [regex]'\x1b\[[0-9;]*m'
function visLen([string]$s) { $script:_ansiRe.Replace($s, '').Length }

function isStale([string]$file, [int]$ttl) {
    if (-not (Test-Path $file)) { return $true }
    try {
        $ts = [int64](Get-Content $file -Raw).Trim()
        return ($now - $ts) -ge $ttl
    } catch { return $true }
}

function parseAgentsCache($agents) {
    $result = @()
    foreach ($a in $agents) {
        $phases = @()
        if ($a.Phases) {
            foreach ($ph in $a.Phases) {
                $phases += [PSCustomObject]@{ Title = $ph.Title; Done = [int]$ph.Done; Total = [int]$ph.Total }
            }
        }
        $result += [PSCustomObject]@{
            Short = $a.Short; Tokens = [int]$a.Tokens; Rate = $a.Rate; Model = $a.Model
            Workflow = if ($a.Workflow) { $a.Workflow } else { "" }
            SubCount = if ($a.SubCount) { [int]$a.SubCount } else { 0 }
            Phases = $phases
        }
    }
    return $result
}

function claimLock([string]$lockFile, [int]$pid) {
    if ($pid -le 0) { return $false }
    if (Test-Path $lockFile) {
        try {
            $owner = [int](Get-Content $lockFile -Raw).Trim()
            if ($owner -eq $pid) { return $true }
            if (Get-Process -Id $owner -ErrorAction SilentlyContinue) { return $false }
        } catch {}
    }
    "$pid" | Set-Content $lockFile -NoNewline
    return $true
}

function writeComputeCache {
    $ccData = [ordered]@{
        computed_at  = $now
        has_agents   = ($agentsData.Count -gt 0)
        lines_add    = $linesAdd
        lines_del    = $linesDel
        branch       = $branch
        in_git       = $inGit
        cache_epoch  = $cacheEpoch
        cache_ttl    = $cacheTtl
        agents       = @($agentsData | ForEach-Object {
            $entry = [ordered]@{ Short = $_.Short; Tokens = $_.Tokens; Rate = $_.Rate; Model = $_.Model
                        Workflow = $_.Workflow; SubCount = $_.SubCount }
            if ($_.Phases -and $_.Phases.Count -gt 0) {
                $entry['Phases'] = @($_.Phases | ForEach-Object {
                    [ordered]@{ Title = $_.Title; Done = $_.Done; Total = $_.Total }
                })
            }
            $entry
        })
    }
    $ccData | ConvertTo-Json -Depth 4 | Set-Content $computeCacheFile -NoNewline
}

# ── Extract fields ───────────────────────────────────────
$transcript = $d.transcript_path
$projectDir = $d.workspace.project_dir
$model      = $d.model.display_name
$effort     = $d.effort.level
$ctxPct     = if ($null -ne $d.context_window.used_percentage)    { [double]$d.context_window.used_percentage }    else { 0 }
$ctxSize    = if ($null -ne $d.context_window.context_window_size) { [double]$d.context_window.context_window_size } else { 200000 }
$fiveH      = $d.rate_limits.five_hour.used_percentage
$sevenD     = $d.rate_limits.seven_day.used_percentage

$claudeDir = "$env:USERPROFILE\.claude"
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$sessionId = if ($transcript) { [System.IO.Path]::GetFileNameWithoutExtension($transcript) } else { "" }

# ── Resolve this session's PID from session files ────────
$myPid = 0
$_targetSid = if ($d.session_id) { $d.session_id } else { $sessionId }
if ($_targetSid) {
    foreach ($sf in Get-ChildItem "$claudeDir\sessions\*.json" -ErrorAction SilentlyContinue) {
        try {
            $sj = Get-Content $sf -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($sj.sessionId -eq $_targetSid) { $myPid = [int]$sj.pid; break }
        } catch {}
    }
}

# ── Two-tier cache: decide full vs cheap tick ────────────
$computeCacheFile = "$claudeDir\.sl_compute_$sessionId"
$doFullCompute = $true

if ($sessionId -and (Test-Path $computeCacheFile)) {
    try {
        $cc = Get-Content $computeCacheFile -Raw | ConvertFrom-Json -ErrorAction Stop
        $age = $now - $cc.computed_at
        $interval = if ($cc.has_agents) { $AGENT_INTERVAL } else { $FULL_INTERVAL }
        if ($age -lt $interval) { $doFullCompute = $false }
    } catch {}
}

# ── OAuth usage (only when CC doesn't provide rate_limits) ──
$usageCache = "$claudeDir\.statusline_usage_cache"

if ($null -eq $fiveH) {
    $oauthOwnerFile = "$claudeDir\.sl_oauth_owner"

    $_isOwner = claimLock $oauthOwnerFile $myPid

    if ($_isOwner) {
        $oauthLastAttempt = "$claudeDir\.sl_oauth_last_attempt"
        $_doOAuthFetch = $false
        if (-not (Test-Path $usageCache)) {
            $_doOAuthFetch = $true
        } else {
            try {
                $cached = Get-Content $usageCache -Raw | ConvertFrom-Json
                if ($null -eq $cached.fetched_at) { throw "corrupt" }
                if (($now - $cached.fetched_at) -gt $OAUTH_TTL) { $_doOAuthFetch = $true }
            } catch { $_doOAuthFetch = $true }
        }

        if ($_doOAuthFetch -and -not (isStale $oauthLastAttempt $OAUTH_TTL)) { $_doOAuthFetch = $false }

        if ($_doOAuthFetch) {
            "$now" | Set-Content $oauthLastAttempt -NoNewline
            $credsFile = "$claudeDir\.credentials.json"
            if (Test-Path $credsFile) {
                try {
                    $tok = (Get-Content $credsFile -Raw | ConvertFrom-Json -ErrorAction Stop).claudeAiOauth.accessToken
                } catch { $tok = $null }
                if ($tok) {
                    Start-Job -ScriptBlock {
                        param($token, $cachePath)
                        try {
                            $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' `
                                -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 3 -ErrorAction Stop
                            [ordered]@{
                                five_hour  = $r.five_hour.utilization
                                seven_day  = $r.seven_day.utilization
                                fetched_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                            } | ConvertTo-Json | Set-Content $cachePath -NoNewline
                        } catch {}
                    } -ArgumentList $tok, $usageCache | Out-Null
                }
            }
        }
    }

    if (Test-Path $usageCache) {
        try {
            $cached = Get-Content $usageCache -Raw | ConvertFrom-Json
            $fiveH  = $cached.five_hour
            $sevenD = $cached.seven_day
        } catch {}
    }
}

# ── 5h rate-of-change tracking ───────────────────────────
$rateFile = "$claudeDir\.statusline_rate_history"

if ($null -ne $fiveH) {
    $rateLastWrite = "$claudeDir\.sl_rate_last_write"
    $_writeRate = isStale $rateLastWrite $OAUTH_TTL
    if ($_writeRate) {
        "$now" | Set-Content $rateLastWrite -NoNewline
        Add-Content -Path $rateFile -Value "$now $fiveH"
        $cutoff = $now - 3600
        if (Test-Path $rateFile) {
            $kept = Get-Content $rateFile | Where-Object {
                $p = $_ -split ' ',2; $p.Count -ge 1 -and [int64]$p[0] -ge $cutoff
            }
            if ($kept) { $kept | Set-Content $rateFile } else { Remove-Item $rateFile -Force }
        }
    }
}

function calcRate([double]$pct) {
    if (-not (Test-Path $rateFile)) { return $null }
    $cutoff = $now - 1800
    $oldest = Get-Content $rateFile | Where-Object {
        $parts = $_ -split ' ',2
        $parts.Count -ge 2 -and [int64]$parts[0] -ge $cutoff
    } | Select-Object -First 1
    if (-not $oldest) { return $null }
    $parts = $oldest -split ' ',2
    $oldT = [int64]$parts[0]
    $oldP = [double]$parts[1]
    $dt = $now - $oldT
    if ($dt -lt 120) { return $null }
    [math]::Round(($pct - $oldP) / ($dt / 3600.0))
}

if ($doFullCompute) {
    # ══════════════════════════════════════════════════════
    # FULL COMPUTE — transcript parsing, git, agents
    # ══════════════════════════════════════════════════════

    # ── GC stale per-session files (runs at most once per 5 min) ──
    $gcMarker = "$claudeDir\.sl_last_gc"
    $_doGc = isStale $gcMarker 300
    if ($_doGc) {
        "$now" | Set-Content $gcMarker -NoNewline
        $liveSids = @{}
        foreach ($sf in Get-ChildItem "$claudeDir\sessions\*.json" -ErrorAction SilentlyContinue) {
            try {
                $sj = Get-Content $sf -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($sj.pid -and (Get-Process -Id $sj.pid -ErrorAction SilentlyContinue)) {
                    $liveSids[$sj.sessionId] = $true
                }
            } catch {}
        }
        foreach ($stale in Get-ChildItem "$claudeDir\.sl_*" -ErrorAction SilentlyContinue) {
            if ($stale.Name -match '\.sl_(?:compute|cache|mtime|agents)_([a-f0-9-]{36})$') {
                if (-not $liveSids.ContainsKey($Matches[1])) {
                    Remove-Item $stale.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    # Extract cheap fields from stdin JSON (instant)
    $linesAdd = 0; $linesDel = 0
    if ($null -ne $d.cost.total_lines_added)   { try { $linesAdd = [int]$d.cost.total_lines_added   } catch {} }
    if ($null -ne $d.cost.total_lines_removed) { try { $linesDel = [int]$d.cost.total_lines_removed } catch {} }

    # Seed defaults for expensive fields; read stale cache if available
    $cacheEpoch = 0; $cacheTtl = 300; $branch = ""; $inGit = $false; $agentsData = @()
    if ($cc) {
        $branch = if ($cc.branch) { $cc.branch } else { "" }
        $inGit = [bool]$cc.in_git
        $cacheEpoch = if ($cc.cache_epoch) { [int64]$cc.cache_epoch } else { 0 }
        $cacheTtl = if ($cc.cache_ttl) { [int]$cc.cache_ttl } else { 300 }
        if ($cc.agents) { $agentsData = parseAgentsCache $cc.agents }
    }

    # Write partial cache immediately -- breaks the death loop
    writeComputeCache

    # ── Cache countdown (per-session) ────────────────────
    $cacheStateFile = "$claudeDir\.sl_cache_$sessionId"
    $cacheMtimeFile = "$claudeDir\.sl_mtime_$sessionId"

    if ($transcript -and (Test-Path $transcript)) {
        $tMtime = (Get-Item $transcript).LastWriteTimeUtc.Ticks
        $lastMtime = if (Test-Path $cacheMtimeFile) { (Get-Content $cacheMtimeFile -Raw).Trim() } else { "0" }
        if ($tMtime -ne $lastMtime) {
            try {
                # Seek to last ~64KB instead of Get-Content -Tail (which reads the entire file)
                $fs = [System.IO.File]::Open($transcript, 'Open', 'Read', 'ReadWrite')
                try {
                    $tailBytes = [math]::Min($fs.Length, 65536)
                    $null = $fs.Seek(-$tailBytes, 'End')
                    $reader = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
                    $null = $reader.ReadLine()  # skip partial first line
                    $lines = @()
                    while ($null -ne ($line = $reader.ReadLine())) { $lines += $line }
                } finally { $fs.Dispose() }

                for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                    try {
                        $entry = $lines[$i] | ConvertFrom-Json -ErrorAction Stop
                        $usage = $entry.message.usage
                        if ($null -eq $usage) { continue }
                        $hasCache = (($usage.cache_read_input_tokens -gt 0) -or
                                     ($usage.cache_creation_input_tokens -gt 0))
                        if ($hasCache) {
                            $cacheTtl = if ($usage.cache_creation.ephemeral_1h_input_tokens -gt 0) { 3600 } else { 300 }
                            $cacheEpoch = [DateTimeOffset]::new([DateTime]::Parse($entry.timestamp), [TimeSpan]::Zero).ToUnixTimeSeconds()
                            "$cacheEpoch $cacheTtl" | Set-Content $cacheStateFile -NoNewline
                            break
                        }
                    } catch { continue }
                }
            } catch {}
            "$tMtime" | Set-Content $cacheMtimeFile -NoNewline
        }
    }

    if ($cacheEpoch -eq 0 -and (Test-Path $cacheStateFile)) {
        $parts = (Get-Content $cacheStateFile -Raw).Trim() -split ' '
        if ($parts.Count -ge 1 -and $parts[0]) {
            $cacheEpoch = [int64]$parts[0]
            if ($parts.Count -ge 2) { $cacheTtl = [int]$parts[1] }
        }
    }

    # ── Git branch ───────────────────────────────────────
    if ($projectDir) {
        $branch = git -C $projectDir rev-parse --abbrev-ref HEAD 2>$null
        if ($branch) { $inGit = $true } else { $branch = ""; $inGit = $false }
    }

    # ── Active agents (incremental parsing) ────────────
    $agentsData = @()
    if ($transcript) {
        $saDir = ($transcript -replace '\.jsonl$','') + "/subagents"
        if (Test-Path $saDir) {
            $agentCacheFile = "$claudeDir\.sl_agents_$sessionId"
            $atc = @{}
            if (Test-Path $agentCacheFile) {
                try { $atc = Get-Content $agentCacheFile -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $atc = @{} }
            }

            $stopwords = @('a','an','the','and','or','but','not','nor','for','yet','so',
                           'with','from','except','into','about','after','before','during','without')
            foreach ($mf in Get-ChildItem "$saDir/agent-*.meta.json" -ErrorAction SilentlyContinue) {
                $jf = $mf.FullName -replace '\.meta\.json$','.jsonl'
                if (-not (Test-Path $jf)) { continue }
                $jfItem = Get-Item $jf
                if (($now - ([DateTimeOffset]$jfItem.LastWriteTimeUtc).ToUnixTimeSeconds()) -gt 120) { continue }

                try { $meta = Get-Content $mf -Raw | ConvertFrom-Json } catch { continue }
                $desc = if ($meta.description) { $meta.description } else { "agent" }
                $words = ($desc -split '\s+') | Select-Object -First 3
                while ($words.Count -gt 1 -and $words[-1].ToLower() -in $stopwords) {
                    $words = $words[0..($words.Count - 2)]
                }
                $short = $words -join ' '

                $jfSize = $jfItem.Length
                $ck = $jfItem.Name
                $ca = $atc[$ck]
                $caSize = if ($ca) { [int64]$ca.size } else { 0 }

                $oTok = 0; $firstTs = $null; $agentModel = ""

                if ($jfSize -eq $caSize -and $caSize -gt 0) {
                    $oTok = [int]$ca.tokens
                    $agentModel = if ($ca.model) { $ca.model } else { "" }
                    if ($ca.first_ts -and [int64]$ca.first_ts -gt 0) { $firstTs = [int64]$ca.first_ts }
                } else {
                    $seekPos = if ($jfSize -gt $caSize -and $caSize -gt 0) { $caSize } else { 0 }
                    $oTok = if ($seekPos -gt 0) { [int]$ca.tokens } else { 0 }
                    if ($seekPos -gt 0) {
                        $agentModel = if ($ca.model) { $ca.model } else { "" }
                        if ($ca.first_ts -and [int64]$ca.first_ts -gt 0) { $firstTs = [int64]$ca.first_ts }
                    }

                    try {
                        $fs = [System.IO.File]::Open($jf, 'Open', 'Read', 'ReadWrite')
                        try {
                            $reader = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
                            if ($seekPos -gt 0) {
                                $null = $fs.Seek($seekPos, 'Begin')
                                $reader.DiscardBufferedData()
                            }
                            while ($null -ne ($line = $reader.ReadLine())) {
                                try {
                                    $entry = $line | ConvertFrom-Json -ErrorAction Stop
                                    if (-not $firstTs -and $entry.timestamp) {
                                        $firstTs = [DateTimeOffset]::new([DateTime]::Parse($entry.timestamp), [TimeSpan]::Zero).ToUnixTimeSeconds()
                                    }
                                    if ($entry.message.usage.output_tokens) {
                                        $oTok += [int]$entry.message.usage.output_tokens
                                    }
                                    if (-not $agentModel -and $entry.message.model) {
                                        $agentModel = $entry.message.model -replace '^claude-' -replace '-\d.*'
                                        $agentModel = (Get-Culture).TextInfo.ToTitleCase($agentModel)
                                    }
                                } catch { continue }
                            }
                        } finally { $fs.Dispose() }
                    } catch {}

                    $atc[$ck] = @{
                        size = $jfSize; tokens = $oTok
                        model = $agentModel
                        first_ts = if ($firstTs) { $firstTs } else { 0 }
                    }
                }

                $aRate = $null
                if ($firstTs) {
                    $elapsed = $now - $firstTs
                    if ($elapsed -ge 10) {
                        $aRate = [math]::Round($oTok / ($elapsed / 60.0))
                    }
                }

                $agentsData += [PSCustomObject]@{
                    Short = $short; Tokens = $oTok; Rate = $aRate; Model = $agentModel
                    Workflow = ""; SubCount = 0; Phases = @()
                }
            }

            # ── Workflow subagents (subagents/workflows/wf_*/) ──
            $wfDir = "$saDir/workflows"
            if (Test-Path $wfDir) {
                $sessionDir = Split-Path $saDir -Parent
                $scriptDir = "$sessionDir/workflows/scripts"

                foreach ($wfFolder in Get-ChildItem "$wfDir/wf_*" -Directory -ErrorAction SilentlyContinue) {
                    $wfId = $wfFolder.Name
                    $wfName = $wfId
                    if (Test-Path $scriptDir) {
                        $scriptMatch = Get-ChildItem "$scriptDir/*-${wfId}.js" -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($scriptMatch) { $wfName = $scriptMatch.Name -replace "-${wfId}\.js$", '' }
                    }

                    # Phase detection: try state JSON first (completed workflows), fall back to script+journal (running workflows)
                    $wfPhases = @()
                    $phaseCounters = @{}
                    $phaseDone = @{}
                    $wfStateFile = "$sessionDir/workflows/${wfId}.json"
                    $_phasesResolved = $false
                    if (Test-Path $wfStateFile) {
                        try {
                            $wfState = Get-Content $wfStateFile -Raw | ConvertFrom-Json -ErrorAction Stop
                            if ($wfState.workflowName) { $wfName = $wfState.workflowName }
                            if ($wfState.phases -and $wfState.workflowProgress) {
                                $wfPhases = @($wfState.phases | ForEach-Object { $_.title })
                                foreach ($ph in $wfPhases) { $phaseCounters[$ph] = 0; $phaseDone[$ph] = 0 }
                                foreach ($wp in $wfState.workflowProgress) {
                                    if ($wp.type -ne 'workflow_agent') { continue }
                                    if ($wp.phaseTitle -and $phaseCounters.ContainsKey($wp.phaseTitle)) {
                                        $phaseCounters[$wp.phaseTitle]++
                                        if ($wp.state -eq 'done') { $phaseDone[$wp.phaseTitle]++ }
                                    }
                                }
                                $_phasesResolved = $true
                            }
                        } catch {}
                    }
                    if (-not $_phasesResolved) {
                        # Running workflow: parse meta.phases from script, infer agent-to-phase mapping from journal
                        $wfScript = Get-ChildItem "$scriptDir/*-${wfId}.js" -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($wfScript) {
                            try {
                                $scriptText = Get-Content $wfScript -Raw
                                if ($scriptText -match '(?s)phases\s*:\s*\[(.*?)\]') {
                                    $pBlock = $Matches[1] -replace "(\w+)\s*:" , '"$1":' -replace "'", '"'
                                    $pArr = "[$pBlock]" | ConvertFrom-Json -ErrorAction Stop
                                    $wfPhases = @($pArr | ForEach-Object { $_.title })
                                    foreach ($ph in $wfPhases) { $phaseCounters[$ph] = 0; $phaseDone[$ph] = 0 }
                                }
                            } catch {}
                        }
                        if ($wfPhases.Count -gt 0) {
                            $journalFile = "$($wfFolder.FullName)/journal.jsonl"
                            if (Test-Path $journalFile) {
                                try {
                                    # Journal pattern: starts arrive in bursts per phase, results interleave.
                                    # Detect phase boundaries: a "started" after a "result" begins a new phase.
                                    $phaseIdx = 0
                                    $seenResult = $false
                                    $agentPhase = @{}
                                    $doneAgents = [System.Collections.Generic.HashSet[string]]::new()
                                    foreach ($jline in [System.IO.File]::ReadLines($journalFile)) {
                                        try {
                                            $je = $jline | ConvertFrom-Json -ErrorAction Stop
                                            if ($je.type -eq 'started') {
                                                if ($seenResult -and $phaseIdx -lt ($wfPhases.Count - 1)) {
                                                    $phaseIdx++
                                                    $seenResult = $false
                                                }
                                                $agentPhase[$je.agentId] = $wfPhases[$phaseIdx]
                                                $phaseCounters[$wfPhases[$phaseIdx]]++
                                            } elseif ($je.type -eq 'result') {
                                                $seenResult = $true
                                                if ($je.agentId) { $null = $doneAgents.Add($je.agentId) }
                                            }
                                        } catch { continue }
                                    }
                                    foreach ($ph in $wfPhases) { $phaseDone[$ph] = 0 }
                                    foreach ($aid in $doneAgents) {
                                        if ($agentPhase.ContainsKey($aid) -and $phaseDone.ContainsKey($agentPhase[$aid])) {
                                            $phaseDone[$agentPhase[$aid]]++
                                        }
                                    }
                                } catch {}
                            }
                        }
                    }

                    $wfTotalTok = 0; $wfFirstTs = $null; $wfLastWrite = 0; $wfSubCount = 0; $wfModel = ""
                    foreach ($wjf in Get-ChildItem "$($wfFolder.FullName)/agent-*.jsonl" -ErrorAction SilentlyContinue) {
                        $wjfItem = Get-Item $wjf
                        $wjfWrite = ([DateTimeOffset]$wjfItem.LastWriteTimeUtc).ToUnixTimeSeconds()
                        if ($wjfWrite -gt $wfLastWrite) { $wfLastWrite = $wjfWrite }
                        $wfSubCount++

                        $ck = "${wfId}/$($wjfItem.Name)"
                        $ca = $atc[$ck]
                        $caSize = if ($ca) { [int64]$ca.size } else { 0 }
                        $wjfSize = $wjfItem.Length

                        if ($wjfSize -eq $caSize -and $caSize -gt 0) {
                            $wfTotalTok += [int]$ca.tokens
                            if (-not $wfModel -and $ca.model) { $wfModel = $ca.model }
                            if ($ca.first_ts -and [int64]$ca.first_ts -gt 0 -and (-not $wfFirstTs -or [int64]$ca.first_ts -lt $wfFirstTs)) {
                                $wfFirstTs = [int64]$ca.first_ts
                            }
                        } else {
                            $seekPos = if ($wjfSize -gt $caSize -and $caSize -gt 0) { $caSize } else { 0 }
                            $subTok = if ($seekPos -gt 0) { [int]$ca.tokens } else { 0 }
                            $subFirstTs = $null; $subModel = ""
                            if ($seekPos -gt 0) {
                                $subModel = if ($ca.model) { $ca.model } else { "" }
                                if ($ca.first_ts -and [int64]$ca.first_ts -gt 0) { $subFirstTs = [int64]$ca.first_ts }
                            }

                            try {
                                $fs = [System.IO.File]::Open($wjf, 'Open', 'Read', 'ReadWrite')
                                try {
                                    $reader = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
                                    if ($seekPos -gt 0) {
                                        $null = $fs.Seek($seekPos, 'Begin')
                                        $reader.DiscardBufferedData()
                                    }
                                    while ($null -ne ($line = $reader.ReadLine())) {
                                        try {
                                            $entry = $line | ConvertFrom-Json -ErrorAction Stop
                                            if (-not $subFirstTs -and $entry.timestamp) {
                                                $subFirstTs = [DateTimeOffset]::new([DateTime]::Parse($entry.timestamp), [TimeSpan]::Zero).ToUnixTimeSeconds()
                                            }
                                            if ($entry.message.usage.output_tokens) {
                                                $subTok += [int]$entry.message.usage.output_tokens
                                            }
                                            if (-not $subModel -and $entry.message.model) {
                                                $subModel = $entry.message.model -replace '^claude-' -replace '-\d.*'
                                                $subModel = (Get-Culture).TextInfo.ToTitleCase($subModel)
                                            }
                                        } catch { continue }
                                    }
                                } finally { $fs.Dispose() }
                            } catch {}

                            $atc[$ck] = @{
                                size = $wjfSize; tokens = $subTok; model = $subModel
                                first_ts = if ($subFirstTs) { $subFirstTs } else { 0 }
                            }
                            $wfTotalTok += $subTok
                            if (-not $wfModel -and $subModel) { $wfModel = $subModel }
                            if ($subFirstTs -and (-not $wfFirstTs -or $subFirstTs -lt $wfFirstTs)) { $wfFirstTs = $subFirstTs }
                        }
                    }

                    if ($wfSubCount -eq 0) { continue }
                    if (($now - $wfLastWrite) -gt 120) { continue }

                    $wfRate = $null
                    if ($wfFirstTs) {
                        $elapsed = $now - $wfFirstTs
                        if ($elapsed -ge 10) {
                            $wfRate = [math]::Round($wfTotalTok / ($elapsed / 60.0))
                        }
                    }

                    $wfPhaseData = @()
                    if ($wfPhases.Count -gt 0) {
                        foreach ($ph in $wfPhases) {
                            $wfPhaseData += [PSCustomObject]@{
                                Title = $ph; Done = $phaseDone[$ph]; Total = $phaseCounters[$ph]
                            }
                        }
                    }

                    $agentsData += [PSCustomObject]@{
                        Short = $wfName; Tokens = $wfTotalTok; Rate = $wfRate; Model = $wfModel
                        Workflow = $wfId; SubCount = $wfSubCount; Phases = $wfPhaseData
                    }
                }
            }

            if ($atc.Count -gt 0) {
                $atc | ConvertTo-Json -Depth 2 | Set-Content $agentCacheFile -NoNewline
            }
        }
    }

    # ── Write full cache (overwrites partial) ────────────
    writeComputeCache

} else {
    # ══════════════════════════════════════════════════════
    # CHEAP TICK — read cached values, just update countdown
    # ══════════════════════════════════════════════════════

    $linesAdd   = [int]$cc.lines_add
    $linesDel   = [int]$cc.lines_del
    $branch     = $cc.branch
    $inGit      = [bool]$cc.in_git
    $cacheEpoch = [int64]$cc.cache_epoch
    $cacheTtl   = [int]$cc.cache_ttl
    $agentsData = if ($cc.agents) { parseAgentsCache $cc.agents } else { @() }
}

# ── Cache countdown (computed from epoch every tick) ─────
$cacheRemaining = ""
$cacheElapsedPct = 0
if ($cacheEpoch -gt 0) {
    $remain = $cacheTtl - ($now - $cacheEpoch)
    if ($remain -gt 0) {
        $m = [math]::Floor($remain / 60)
        $s = $remain % 60
        $cacheRemaining = if ($m -gt 0) { "${m}m${s}s" } else { "${s}s" }
        $cacheElapsedPct = 100 - [math]::Round($remain * 100 / $cacheTtl)
    }
}

# ── Build output ─────────────────────────────────────────
$segments = [ordered]@{}

if ($model) {
    $modelStr = $model -replace '\s*\(1M context\)', ''
    $s = "${cModel}${modelStr}"
    if ($ctxSize -ge 1000000) { $s += " ${cDim}[1M]" }
    if ($effort) { $s += " ${cGray}(${effort})" }
    $segments['model'] = $s
}

$proj = if ($projectDir) { Split-Path $projectDir -Leaf } else { "" }
if ($proj) {
    if ($inGit) {
        $segments['project'] = "${cProj}`u{1F4C1} ${proj} ${cGray}(${branch})"
    } else {
        $segments['project'] = "${cProj}`u{1F4C1} ${proj} ${cDim}(untracked)"
    }
}

if ($inGit -and ($linesAdd -gt 0 -or $linesDel -gt 0)) {
    $segments['diff'] = "${cAdd}+${linesAdd}${cDel}/-${linesDel}"
}

$ctxP = [math]::Round($ctxPct)
$ctxUsed = [math]::Round($ctxSize * $ctxPct / 100)
$uFmt = fmtTok $ctxUsed
$segments['ctx'] = "${cGray}${uFmt} $(makeBar $ctxPct) $(tierColor $ctxPct @(30,60,80))${ctxP}%"

if ($null -ne $fiveH) {
    $p5 = [math]::Round($fiveH)
    $rate = calcRate $fiveH
    $rateStr = ""
    if ($null -ne $rate -and $rate -ne 0) {
        $arrow = if ($rate -lt 0) { [char]0x2193 } else { [char]0x2191 }
        $rAbs = [math]::Abs($rate)
        $rateStr = " ${cGray}($(tierColor $rAbs @(5,10,15))${arrow}${rAbs}%${cGray}/hr)"
    }
    $segments['5h'] = "${cGray}5h $(makeBar $fiveH) $(tierColor $fiveH @(30,60,80))${p5}%${rateStr}"
    $seg5hMid       = "${cGray}5h $(makeBar $fiveH) $(tierColor $fiveH @(30,60,80))${p5}%"
    $seg5hShort     = "${cGray}5h: $(tierColor $fiveH @(30,60,80))${p5}%"
}

if ($null -ne $sevenD) {
    $pw = [math]::Round($sevenD)
    $segments['7d'] = "${cGray}7d $(makeBar $sevenD) $(tierColor $sevenD @(30,60,80))${pw}%"
    $seg7dShort     = "${cGray}7d: $(tierColor $sevenD @(30,60,80))${pw}%"
}

if ($cacheRemaining) {
    $segments['cache'] = "${cGray}cache $(tierColor $cacheElapsedPct @(30,60,80))${cacheRemaining}"
}

$MAX_W = $WIDTH - 4
$script:curBarW = 8
$script:rateDropped = $false

function overBy { (visLen ($segments.Values -join $sep)) - $MAX_W }

function rebuildBars {
    if ($segments.Contains('ctx')) {
        $segments['ctx'] = "${cGray}${uFmt} $(makeBar $ctxPct $script:curBarW) $(tierColor $ctxPct @(30,60,80))${ctxP}%"
    }
    if ($segments.Contains('5h') -and $null -ne $fiveH) {
        $p5_ = [math]::Round($fiveH)
        $rs = if ($script:rateDropped) { "" } else { $rateStr }
        $segments['5h'] = "${cGray}5h $(makeBar $fiveH $script:curBarW) $(tierColor $fiveH @(30,60,80))${p5_}%${rs}"
    }
    if ($segments.Contains('7d') -and $null -ne $sevenD) {
        $pw_ = [math]::Round($sevenD)
        $segments['7d'] = "${cGray}7d $(makeBar $sevenD $script:curBarW) $(tierColor $sevenD @(30,60,80))${pw_}%"
    }
}

$collapseSteps = @(
    { if ($segments.Contains('cache') -and $cacheRemaining) {
        $segments['cache'] = "$(tierColor $cacheElapsedPct @(30,60,80))${cacheRemaining}"
    } }
    { if ($segments.Contains('model') -and $ctxSize -ge 1000000) {
        $ms = "${cModel}$($model -replace '\s*\(1M context\)', '')"
        if ($effort) { $ms += " ${cGray}(${effort})" }
        $segments['model'] = $ms
    } }
    { if ($script:curBarW -gt 7) { $script:curBarW = 7; rebuildBars } }
    { if ($script:curBarW -gt 6) { $script:curBarW = 6; rebuildBars } }
    { if ($script:curBarW -gt 5) { $script:curBarW = 5; rebuildBars } }
    { if ($script:curBarW -gt 4) { $script:curBarW = 4; rebuildBars } }
    { if ($segments.Contains('5h') -and $null -ne $fiveH) {
        $script:rateDropped = $true
        $p5_ = [math]::Round($fiveH)
        $segments['5h'] = "${cGray}5h $(makeBar $fiveH $script:curBarW) $(tierColor $fiveH @(30,60,80))${p5_}%"
    } }
    { if ($seg7dShort -and $segments.Contains('7d')) { $segments['7d'] = $seg7dShort } }
    { if ($segments.Contains('7d')) { $segments.Remove('7d') } }
    { if ($seg5hShort -and $segments.Contains('5h')) { $segments['5h'] = $seg5hShort } }
    { if ($segments.Contains('5h')) { $segments.Remove('5h') } }
)

foreach ($step in $collapseSteps) {
    if ((overBy) -le 0) { break }
    & $step
}

$out = $segments.Values -join $sep

# ── Agents line ──────────────────────────────────────────
$agentsLine = ""
$workflowLines = @()
if ($agentsData.Count -gt 0) {
    $regularAgents = @($agentsData | Where-Object { -not $_.Workflow })
    $workflows = @($agentsData | Where-Object { $_.Workflow })

    if ($regularAgents.Count -gt 0) {
        $allSame = ($regularAgents | Select-Object -ExpandProperty Model -Unique).Count -le 1
        $pl = if ($regularAgents.Count -gt 1) { "s" } else { "" }
        $mdl = if ($allSame -and $regularAgents[0].Model) { " ${cDim}($($regularAgents[0].Model))" } else { "" }
        $header = "${cGray}$($regularAgents.Count) agent${pl}${mdl}${cDim}:"

        $parts = foreach ($a in $regularAgents) {
            $tf = fmtTok $a.Tokens
            $segs = @("${cGray}$($a.Short)", "${cModel}${tf}")
            if ($null -ne $a.Rate -and $a.Rate -ne 0) {
                $rf = if ($a.Rate -ge 1000) { "{0:F0}k" -f ($a.Rate / 1000) } else { "$([math]::Round($a.Rate))" }
                $segs += "$(tierColor $a.Rate @(2000,5000,10000))${rf}/m"
            }
            if (-not $allSame -and $a.Model) { $segs += "${cDim}($($a.Model))" }
            " " + ($segs -join ' ')
        }
        $agentsLine = $header + ($parts -join "${cGray},")
    }

    foreach ($wf in $workflows) {
        $tf = fmtTok $wf.Tokens
        $segs = @("${cGray}`u{2192} $($wf.Short)", "${cDim}($($wf.SubCount) agents)", "${cModel}${tf}")
        if ($null -ne $wf.Rate -and $wf.Rate -ne 0) {
            $rf = if ($wf.Rate -ge 1000) { "{0:F0}k" -f ($wf.Rate / 1000) } else { "$([math]::Round($wf.Rate))" }
            $segs += "$(tierColor $wf.Rate @(2000,5000,10000))${rf}/m"
        }
        if ($wf.Model) { $segs += "${cDim}($($wf.Model))" }
        $workflowLines += ($segs -join ' ')

        if ($wf.Phases -and $wf.Phases.Count -gt 0) {
            $cCheck = fg 152 195 121
            $phaseSegs = foreach ($ph in $wf.Phases) {
                if ($ph.Total -eq 0) { continue }
                $mark = if ($ph.Done -eq $ph.Total) { " ${cCheck}`u{2713}" } else { "" }
                "${cDim}$($ph.Title) ${cGray}$($ph.Done)/$($ph.Total)${mark}"
            }
            if ($phaseSegs) {
                $workflowLines += "   " + ($phaseSegs -join "  ")
            }
        }
    }
}

# ── Output ───────────────────────────────────────────────
[Console]::Write("$out$rst")
if ($agentsLine) { [Console]::Write("`n$agentsLine$rst") }
foreach ($wl in $workflowLines) { [Console]::Write("`n$wl$rst") }
exit 0
