import AppKit

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

PendingInstall.installAtLaunch()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(Headless.active ? .accessory : .regular)
Headless.install()
app.run()
