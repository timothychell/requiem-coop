param(
    [ValidateSet('start', 'sample', 'cleanup')][string]$Action = 'sample',
    [string]$GameRoot = $env:REQUIEM_GAME_ROOT
)
$ErrorActionPreference = 'Stop'
$code = "local probe_action = '$Action'`n" + (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'probe_native_animation.lua') -Raw)
$bridgeArgs = @{ Code = $code }
if ($GameRoot) { $bridgeArgs.GameRoot = $GameRoot }
& (Join-Path $PSScriptRoot 'Invoke-CoopBridge.ps1') @bridgeArgs | ConvertTo-Json -Depth 8
