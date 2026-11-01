import Foundation
import WinSDK

// Solanum on Windows. build.ps1 links this twice: Solanum.exe, a windowed app with no console, and Solanum-test.exe, a
// console program that can print test results and that PowerShell waits for.
_ = SetConsoleOutputCP(65001)

if CommandLine.arguments.contains("--selftest") {
    let results = CoreSelfTest.Results()
    CoreSelfTest.run(results)
    WindowSelfTest.runDrawing(results)
    ConPTYSelfTest.run(results)
    exit(results.finish() ? 0 : 1)
}

if CommandLine.arguments.contains("--window-test") {
    exit(WindowSelfTest.runWindow())
}

exit(TerminalWindow.runApp())
