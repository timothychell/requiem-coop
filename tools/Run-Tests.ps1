# Runs the protocol/session regression suites inside the running game (exact game Lua runtime)
# through the dev-only Requiem Bridge. No game objects, saves or network state are changed.
# Usage (from the repository root, game running with tools/dev/requiem_bridge.lua enabled):
#   ./tools/Run-Tests.ps1 [-GameRoot <game folder>]
param([string]$GameRoot = $env:REQUIEM_GAME_ROOT)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$bridge = Join-Path $PSScriptRoot 'Invoke-CoopBridge.ps1'
$bridgeArgs = @{}
if ($GameRoot) { $bridgeArgs.GameRoot = $GameRoot }
function Quote([string]$path) {
    $text = Get-Content -LiteralPath (Join-Path $root $path) -Raw
    if ($text.Contains(']====]')) { throw "Lua delimiter collision in $path" }
    return '[====[' + $text + ']===' + '=]'
}
$protocol = 'local protocol_source = ' + (Quote 'mod/reframework/autorun/requiem_coop.lua') + "`n"
$session = 'local session_source = ' + (Quote 'mod/reframework/autorun/require/requiem_coop_session.lua') + "`n"
$suites = [ordered]@{
    'test_animation_protocol.lua' = $protocol
    'test_packet_regression.lua'  = $protocol
    'test_state_v2.lua'           = $protocol
    'test_session_sync.lua'       = $session
}
$failed = 0
foreach ($suite in $suites.Keys) {
    $code = $suites[$suite] + (Get-Content -LiteralPath (Join-Path $PSScriptRoot $suite) -Raw)
    try {
        $r = & $bridge -Code $code @bridgeArgs
        Write-Host ("PASS {0,-30} {1} checks" -f $suite, $r.result.passed)
    } catch {
        $failed++
        Write-Host ("FAIL {0,-30} {1}" -f $suite, $_) -ForegroundColor Red
    }
}
if ($failed) { throw "$failed suite(s) failed" }
