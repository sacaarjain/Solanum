import Foundation
import WinSDK

// Solanum on Windows. So far: the emulator's self-tests.
_ = SetConsoleOutputCP(UINT(CP_UTF8))

if CommandLine.arguments.contains("--selftest") {
    let results = CoreSelfTest.Results()
    CoreSelfTest.run(results)
    exit(results.finish() ? 0 : 1)
}

print("Solanum for Windows isn't finished yet. Try: Solanum --selftest")
