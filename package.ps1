# Builds the plugin and packs a release zip: dist\RequiemCoop-<version>.zip
# Usage:  powershell -ExecutionPolicy Bypass -File package.ps1 [-Version 0.1.0]
param([string]$Version = "dev")
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot

cmd /c "`"$root\plugin\build.bat`""
if ($LASTEXITCODE -ne 0) { throw "plugin build failed" }

$stage = Join-Path $root (".package-" + $Version + "-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force "$stage\reframework\autorun", "$stage\reframework\plugins" | Out-Null
Copy-Item "$root\mod\reframework\autorun\*" "$stage\reframework\autorun\" -Recurse
Copy-Item "$root\plugin\build\requiem_coop_net.dll" "$stage\reframework\plugins\"
Copy-Item "$root\README.md" "$stage\RequiemCoop_README.md"
Copy-Item "$root\THIRD_PARTY_NOTICES.md" "$stage\RequiemCoop_THIRD_PARTY_NOTICES.md"
Copy-Item "$root\LICENSE" "$stage\RequiemCoop_LICENSE.txt"

New-Item -ItemType Directory -Force "$root\dist" | Out-Null
$zip = "$root\dist\RequiemCoop-$Version.zip"
Compress-Archive -Path "$stage\*" -DestinationPath $zip -Force
# Keep the unique staging directory for inspection; .package-* is ignored.
Write-Host "Created $zip"
