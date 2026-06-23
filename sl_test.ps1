$ErrorActionPreference = 'SilentlyContinue'
$rawInput = [Console]::In.ReadToEnd()
"STATUSLINE_RAN at $(Get-Date) input_length=$($rawInput.Length)" | Set-Content "$env:USERPROFILE\.claude\.sl_debug_test" -NoNewline
[Console]::Write("TEST OK")
exit 0