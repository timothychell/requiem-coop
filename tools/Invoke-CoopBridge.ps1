# Runs Lua in the running game through the dev-only Requiem Bridge (tools/dev/requiem_bridge.lua).
# The game folder is taken from -GameRoot, then $env:REQUIEM_GAME_ROOT, then the Steam libraries.
param(
    [Parameter(Mandatory=$true)][string]$Code,
    [string]$GameRoot = $env:REQUIEM_GAME_ROOT
)
$ErrorActionPreference = 'Stop'
if (-not $GameRoot) {
    $steam = (Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction SilentlyContinue).SteamPath
    $libraries = @()
    if ($steam) {
        $libraries += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $libraries += Select-String -LiteralPath $vdf -Pattern '"path"\s+"([^"]+)"' |
                ForEach-Object { $_.Matches[0].Groups[1].Value -replace '\\\\', '\' }
        }
    }
    $GameRoot = $libraries | ForEach-Object { Join-Path $_ 'steamapps\common\RESIDENT EVIL requiem BIOHAZARD requiem' } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $GameRoot) { throw 'Game folder not found. Pass -GameRoot or set REQUIEM_GAME_ROOT.' }
}
$dataDir = Join-Path $GameRoot 'reframework\data'
$outFile = Join-Path $dataDir 'bridge_out.json'
$cmdFile = Join-Path $dataDir 'bridge_cmd.json'
$previousId = 0L
foreach ($file in @($outFile, $cmdFile)) {
    if (Test-Path -LiteralPath $file) {
        try { $entry = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json; $previousId = [Math]::Max($previousId, [long]$entry.id) } catch {}
    }
}
$probeId = [Math]::Max($previousId + 1, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
$payload = @{ id = $probeId; code = $Code } | ConvertTo-Json -Depth 4
$temporaryFile = Join-Path $dataDir "bridge_cmd.$probeId.tmp"
[IO.File]::WriteAllText($temporaryFile, $payload, [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temporaryFile -Destination $cmdFile -Force
$deadline = [DateTime]::UtcNow.AddSeconds(10)
do {
    Start-Sleep -Milliseconds 150
    try { $result = Get-Content -LiteralPath $outFile -Raw | ConvertFrom-Json } catch { continue }
    if ([long]$result.id -eq $probeId) {
        if (-not $result.ok) { throw $result.error }
        return $result
    }
} while ([DateTime]::UtcNow -lt $deadline)
throw 'No bridge reply within 10 seconds. Check the game is running and the Requiem Bridge is enabled.'
