# Builds Solanum for Windows into build\windows.
#   .\build.ps1            release build
#   .\build.ps1 -Debug     debug build
param([switch]$Debug)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not (Get-Command swiftc -ErrorAction SilentlyContinue)) {
    Write-Error 'swiftc not found. Install Swift (see README.md), then open a new terminal.'
}

$out = 'build\windows'
New-Item -ItemType Directory -Force -Path $out | Out-Null

# As in build.sh: release skips the runtime exclusivity checks, which are costly in the emulator's per-byte loops.
$opt = if ($Debug) { '-Onone', '-g' } else { '-O', '-enforce-exclusivity=unchecked' }
$sources = Get-ChildItem 'Sources\Core\*.swift', 'Sources\Windows\*.swift' | ForEach-Object { $_.FullName }

Write-Host '> Compiling...'
& swiftc @opt -swift-version 5 -module-name Solanum @sources -o "$out\Solanum.exe"
if ($LASTEXITCODE -ne 0) { Write-Error 'Build failed (the compiler''s errors are above).' }
Write-Host "Built $out\Solanum.exe"
