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

# The icon needs a resource compiler: LLVM's comes with Swift, and Windows' with its SDK. Without either Solanum still
# works, with the generic icon, so a problem here doesn't stop the build.
Write-Host '> Compiling the icon...'
$iconResource = "$out\Solanum.res"
$rc = (Get-Command llvm-rc, rc -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $rc) {
    $rc = (Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\rc.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1).FullName
}
$linkIcon = @()
if ($rc) {
    & $rc /nologo "/fo$PWD\$iconResource" 'Support\Windows\Solanum.rc' 2>&1 | Write-Host
    if ($LASTEXITCODE -eq 0 -and (Test-Path $iconResource)) { $linkIcon = @('-Xlinker', "$PWD\$iconResource") }
}
if ($linkIcon.Count -eq 0) { Write-Host "  Couldn't make the icon, so Solanum gets the generic one." }

Write-Host '> Compiling Swift...'
# As in build.sh: release skips the runtime exclusivity checks, which are costly in the emulator's per-byte loops.
$opt = if ($Debug) { '-Onone', '-g' } else { '-O', '-enforce-exclusivity=unchecked' }
$sources = Get-ChildItem 'Sources\Core\*.swift', 'Sources\UI\*.swift', 'Sources\Windows\*.swift' | ForEach-Object { $_.FullName }
& swiftc @opt -swift-version 5 -module-name Solanum -wmo -c -I 'Sources\Windows\CCanvas' @sources -o $swiftObject
if ($LASTEXITCODE -ne 0) { Write-Error 'Swift failed to compile (the errors are above).' }

Write-Host '> Linking...'
# The linker announces the import library it makes for each program, which nothing here uses.
# comdlg32: the Open dialog, for uploading files to an ssh host.
function Link-Program { & swiftc -module-name Solanum $swiftObject $canvasObject @linkIcon -lcomdlg32 @args 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch 'Creating library' } | Write-Host }
Link-Program -o "$out\Solanum-test.exe"
if ($LASTEXITCODE -ne 0) { Write-Error 'Linking Solanum-test.exe failed.' }
Link-Program -o "$out\Solanum.exe" -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup
if ($LASTEXITCODE -ne 0) { Write-Error 'Linking Solanum.exe failed.' }

Write-Host "Built $out\Solanum.exe and $out\Solanum-test.exe"
