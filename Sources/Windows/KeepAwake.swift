import Foundation
import WinSDK

/// Keep Awake (Ctrl+Shift+A), as the Mac's ⇧⌘A runs `caffeinate`: the PC and its display don't sleep for as long as
/// Settings says (`keep-awake-seconds`, 8 hours to start with). Windows has no caffeinate, so Solanum asks Windows itself
/// (SetThreadExecutionState), from the window's thread, which lasts as long as Solanum does. The status bar shows the time
/// left; a click there, or the shortcut again, ends it. Quitting Solanum ends it too.
enum KeepAwake {
    /// When it ends; nil while off.
    private(set) static var until: Date?
    /// Called on the window's thread when it starts or stops.
    static var onChange: [() -> Void] = []

    static var isOn: Bool { until.map { Date() < $0 } ?? false }

    static func start(seconds: Int) {
        until = Date().addingTimeInterval(TimeInterval(max(seconds, 1)))
        _ = SetThreadExecutionState(EXECUTION_STATE(ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED))
        onChange.forEach { $0() }
    }

    static func stop() {
        guard until != nil else { return }
        until = nil
        _ = SetThreadExecutionState(EXECUTION_STATE(ES_CONTINUOUS))
        onChange.forEach { $0() }
    }

    static func toggle() {
        if isOn { stop() } else { start(seconds: AppSettings.shared.keepAwakeSeconds) }
    }

    /// From the window's timer: ends it once its time's up.
    static func tick() {
        if let until, Date() >= until { stop() }
    }

    /// Seconds left, nil while off.
    static var secondsLeft: Int? {
        guard let until, isOn else { return nil }
        return max(Int(until.timeIntervalSinceNow.rounded(.up)), 0)
    }

    /// "8h", "7h 59m", "45m", "30s": the time left as the status bar shows it, to the minute past one.
    static func shortDuration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        let minutes = (seconds + 59) / 60
        let h = minutes / 60, m = minutes % 60
        return h == 0 ? "\(m)m" : m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
