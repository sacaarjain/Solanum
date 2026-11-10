# Builds Solanum for Windows into build\windows:
#   Solanum.exe         the app
#   Solanum-test.exe    the same code as a console program, for --selftest and --window-test
#
#   .\build.ps1            release build (optimized)
#   .\build.ps1 -Debug     debug build
#   .\build.ps1 -Restart   then restarts the Solanum that's running into the new build, everything open coming back
#                          (Ctrl+Shift+R in Solanum does the same, whenever you like)
#   .\build.ps1 -Clean     starts from nothing, as after changing compilers
#
# Builds are incremental: Swift files compile in parallel, each on its own, and only those changed (or affected by a
# change) compile again; the canvas and icon only when they've changed; nothing links when nothing changed. Compiling the
# files separately rather than as one whole module was measured to leave the emulator just as fast (`Solanum-test
# --bench`), and takes a full build from about 95 seconds to about 35, and a typical one to a few seconds.
param([switch]$Debug, [switch]$Restart, [switch]$Clean)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

foreach ($tool in 'swiftc', 'clang-cl') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$tool not found. Install Swift (see WINDOWS.md), then open a new terminal."
    }
}

$out = 'build\windows'
# Debug and release objects are kept apart, as they're compiled differently.
$objects = "$PWD\$out\$(if ($Debug) { 'debug' } else { 'release' })"
if ($Clean) { Remove-Item -Recurse -Force $objects -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $objects | Out-Null
$started = Get-Date

function Is-Newer($source, $target) { -not (Test-Path $target) -or (Get-Item $source).LastWriteTime -gt (Get-Item $target).LastWriteTime }

$canvasObject = "$objects\canvas.obj"
$canvasSources = 'Sources\Windows\CCanvas\canvas.cpp', 'Sources\Windows\CCanvas\canvas.h'
if ($canvasSources | Where-Object { Is-Newer $_ $canvasObject }) {
    Write-Host '> Compiling the canvas...'
    $cArgs = @('/nologo', '/MD', '/std:c++17', '/EHs-c-', '/GR-', '/c')
    if ($Debug) { $cArgs += '/Od', '/Zi' } else { $cArgs += '/O2' }
    & clang-cl @cArgs "/Fo$canvasObject" 'Sources\Windows\CCanvas\canvas.cpp'
    if ($LASTEXITCODE -ne 0) { Write-Error 'The canvas failed to compile (the errors are above).' }
}

# The icon, and the Quantum Moon's script, symbol and font, need a resource compiler: LLVM's comes with Swift, and
# Windows' with its SDK. Without either Solanum still works, with the generic icon and no reading on the Quantum Moon,
# so a problem here doesn't stop the build.
$iconResource = "$objects\Solanum.res"
$iconSources = 'Support\Windows\Solanum.rc', 'Support\Windows\Solanum.ico', 'Support\Bells.svg', 'Support\Solanum.svg', 'Support\QuantumMoon.png',
               'Support\Fonts\SpaceMono-Regular.ttf'
if ($iconSources | Where-Object { Is-Newer $_ $iconResource }) {
    Write-Host '> Compiling the icon and resources...'
    $rc = (Get-Command llvm-rc, rc -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $rc) {
        $rc = (Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\rc.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1).FullName
    }
    if ($rc) { & $rc /nologo "/fo$iconResource" 'Support\Windows\Solanum.rc' 2>&1 | Write-Host }
}
$linkIcon = @()
if (Test-Path $iconResource) { $linkIcon = @('-Xlinker', $iconResource) } else { Write-Host "  Couldn't make the icon, so Solanum gets the generic one." }

Write-Host '> Compiling Swift...'
# As in build.sh: release skips the runtime exclusivity checks, which are costly in the emulator's per-byte loops.
$opt = if ($Debug) { '-Onone', '-g' } else { '-O', '-enforce-exclusivity=unchecked' }
$sources = Get-ChildItem 'Sources\Core\*.swift', 'Sources\UI\*.swift', 'Sources\Windows\*.swift' | ForEach-Object { $_.FullName }
# Where each file's object and dependencies go, which is what lets swiftc compile only what a change affects.
$map = @{ '' = @{ 'swift-dependencies' = "$objects\module.swiftdeps" } }
$swiftObjects = foreach ($s in $sources) {
    $name = [IO.Path]::GetFileNameWithoutExtension($s)
    $map[$s] = @{ object = "$objects\$name.obj"; 'swift-dependencies' = "$objects\$name.swiftdeps" }
    "$objects\$name.obj"
}
$map | ConvertTo-Json -Depth 3 | Set-Content -Encoding utf8 "$objects\output-file-map.json"
& swiftc @opt -swift-version 5 -module-name Solanum -c -incremental -enable-batch-mode -j $env:NUMBER_OF_PROCESSORS `
    -output-file-map "$objects\output-file-map.json" -I 'Sources\Windows\CCanvas' @sources
if ($LASTEXITCODE -ne 0) { Write-Error 'Swift failed to compile (the errors are above).' }

# Nothing to link when nothing has changed since the programs were made.
$inputs = @($swiftObjects) + $canvasObject + @(if (Test-Path $iconResource) { $iconResource })
$newest = ($inputs | ForEach-Object { (Get-Item $_).LastWriteTime } | Measure-Object -Maximum).Maximum
$programs = "$out\Solanum.exe", "$out\Solanum-test.exe"
$kind = if ($Debug) { 'debug' } else { 'release' }
$lastKind = Get-Content "$out\last-build.txt" -ErrorAction SilentlyContinue
$upToDate = $lastKind -eq $kind -and -not ($programs | Where-Object { -not (Test-Path $_) -or (Get-Item $_).LastWriteTime -lt $newest })
if ($upToDate) {
    Write-Host "Nothing changed: $out\Solanum.exe is up to date."
} else {
    Write-Host '> Linking...'
    # The linker announces the import library it makes for each program, which nothing here uses.
    # comdlg32: the Open dialog, for uploading files to an ssh host.
    function Link-Program { & swiftc -module-name Solanum @swiftObjects $canvasObject @linkIcon -lcomdlg32 @args 2>&1 | ForEach-Object { "$_" } | Where-Object { $_ -notmatch 'Creating library' } | Write-Host }
    Link-Program -o "$out\Solanum-test.exe"
    if ($LASTEXITCODE -ne 0) { Write-Error 'Linking Solanum-test.exe failed.' }
    # A running Solanum.exe can't be overwritten, but it can be renamed: it carries on as Solanum.old-<time>.exe and the
    # new build takes its name, which is what a restart starts. (Run inside Solanum, closing it here would stop the build
    # itself.) Each one moved aside gets a name of its own, as one from a build before may still be running; those that
    # have closed since are cleared away.
    Get-ChildItem "$out\Solanum.old*.exe" -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
    if (Test-Path "$out\Solanum.exe") {
        $aside = "$out\Solanum.old-$(Get-Date -Format 'yyyyMMdd-HHmmss').exe"
        try { Move-Item -Force "$out\Solanum.exe" $aside -ErrorAction Stop }
        catch { Write-Error "Couldn't move Solanum.exe aside ($($_.Exception.Message)). Close Solanum and build again." }
    }
    Link-Program -o "$out\Solanum.exe" -Xlinker /SUBSYSTEM:WINDOWS -Xlinker /ENTRY:mainCRTStartup
    if ($LASTEXITCODE -ne 0) { Write-Error 'Linking Solanum.exe failed.' }
    Set-Content "$out\last-build.txt" $kind
    Write-Host "Built $out\Solanum.exe and $out\Solanum-test.exe in $([int]((Get-Date) - $started).TotalSeconds)s"
}

if ($Restart) {
    # Asks the running Solanum to save what's open and restart into this build (or starts it, if none is running). Run
    # inside Solanum, this shell goes with it and comes back in the new one, showing this build's output.
    Write-Host 'Restarting Solanum...'
    & "$out\Solanum.exe" --restart-running
} elseif (-not $upToDate -and (Get-Process -Name 'Solanum*' -ErrorAction SilentlyContinue)) {
    Write-Host 'Solanum is running: press Ctrl+Shift+R in it to restart into this build.'
}
