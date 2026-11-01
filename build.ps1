# Builds Solanum for Windows into build\windows:
#   Solanum.exe         the app
#   Solanum-test.exe    the same code as a console program, for --selftest and --window-test
#
#   .\build.ps1            release build
#   .\build.ps1 -Debug     debug build
param([switch]$Debug)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

foreach ($tool in 'swiftc', 'clang-cl') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$tool not found. Install Swift (see WINDOWS.md), then open a new terminal."
    }
}

$out = 'build\windows'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$canvasObject = "$out\canvas.obj"
$swiftObject = "$out\solanum.obj"

Write-Host '> Compiling the canvas...'
$cArgs = @('/nologo', '/MD', '/std:c++17', '/EHs-c-', '/GR-', '/c')
if ($Debug) { $cArgs += '/Od', '/Zi' } else { $cArgs += '/O2' }
& clang-cl @cArgs "/Fo$canvasObject" 'Sources\Windows\CCanvas\canvas.cpp'
if ($LASTEXITCODE -ne 0) { Write-Error 'The canvas failed to compile (the errors are above).' }

Write-Host '> Compiling Swift...'
# As in build.sh: release skips the runtime exclusivity checks, which are costly in the emulator's per-byte loops.
$opt = if ($Debug) { '-Onone', '-g' } else { '-O', '-enforce-exclusivity=unchecked' }
$sources = Get-ChildItem 'Sources\Core\*.swift', 'Sources\Windows\*.swift' | ForEach-Object { $_.FullName }
& swiftc @opt -swift-version 5 -module-name Solanum -wmo -c -I 'Sources\Windows\CCanvas' @sources -o $swiftObject
if ($LASTEXITCODE -ne 0) { Write-Error 'Swift failed to compile (the errors are above).' }

Write-Host '> Linking...'
& swiftc -module-name Solanum $swiftObject $canvasObject -o "$out\Solanum-test.exe"
if ($LASTEXITCODE -ne 0) { Write-Error 'Linking Solanum-test.exe failed.' }
& swiftc -module-name Solanum $swiftObject $canvasObject -o "$out\Solanum.exe" -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup
if ($LASTEXITCODE -ne 0) { Write-Error 'Linking Solanum.exe failed.' }

Write-Host "Built $out\Solanum.exe and $out\Solanum-test.exe"
