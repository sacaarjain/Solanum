import Foundation
import WinSDK

// Solanum on Windows. build.ps1 links this twice: Solanum.exe, a windowed app with no console, and Solanum-test.exe, a
// console program that can print test results and that PowerShell waits for.
_ = SetConsoleOutputCP(65001)

// Started by ssh to ask for a password (see Askpass): ask the running Solanum, and print the answer for ssh.
if ProcessInfo.processInfo.environment["SOLANUM_ASKPASS"] == "1" {
    exit(Askpass.runHelper(prompt: CommandLine.arguments.dropFirst().joined(separator: " ")))
}

if CommandLine.arguments.contains("--selftest") {
    let results = CoreSelfTest.Results()
    CoreSelfTest.run(results)
    WindowSelfTest.runDrawing(results)
    WindowSelfTest.runChrome(results)
    ConPTYSelfTest.run(results)
    exit(results.finish() ? 0 : 1)
}

if let flag = CommandLine.arguments.firstIndex(of: "--fake-agent") {
    FakeAgent.run(text: CommandLine.arguments[(flag + 1)...].joined(separator: " "))
    exit(0)
}

if CommandLine.arguments.contains("--input-probe") {
    ConPTYSelfTest.probeInput()
    exit(0)
}

if CommandLine.arguments.contains("--resize-probe") {
    ConPTYSelfTest.probeResize()
    exit(0)
}

if CommandLine.arguments.contains("--window-test") {
    exit(WindowSelfTest.runWindow())
}

exit(TerminalWindow.runApp())
