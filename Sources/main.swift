import AppKit

// `Solanum --mcp <name>`: an extension's MCP server for Claude Code, on stdin/stdout, with no app around it.
if let i = CommandLine.arguments.firstIndex(of: "--mcp") {
    exit(MCPServer.run(i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""))
}

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

PendingInstall.installAtLaunch()

StartupTrace.mark("main")
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(Headless.active ? .accessory : .regular)
Headless.install()
app.run()
