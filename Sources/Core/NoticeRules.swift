import Foundation

/// When a corner card (a notification inside the window) is due, and what it says, as the Mac has it (TerminalView's
/// terminalBlockFinished, agentChanged and terminalSSHExited there): a long command finishing, an agent that worked a
/// while stopping, an ssh connection dropping. Shared by the Mac and Windows; each draws the card its own way.
enum NoticeRules {
    /// What a card's mark shows.
    enum Mark: Equatable {
        case finished, failed, needsInput, lostConnection
    }

    struct Card: Equatable {
        var title: String
        var mark: Mark
        /// Under the title, one line each: the first (the tab) brighter, the rest dimmer.
        var lines: [String]
    }

    /// "850ms", "12.4s", "3m 5s", "1h 12m".
    static func formatDuration(_ d: TimeInterval) -> String {
        if d < 1 { return "\(Int(d * 1000))ms" }
        if d < 60 { return String(format: "%.1fs", d) }
        let m = Int(d) / 60, s = Int(d) % 60
        if m < 60 { return "\(m)m \(s)s" }
        return "\(m / 60)h \(m % 60)m"
    }

    /// "Group › Tab" for a tab in a group, else the tab's name.
    static func place(tab: String, group: String?) -> String {
        group.map { "\($0) \u{203A} \(tab)" } ?? tab
    }

    /// A command that took at least `threshold` seconds (0 is off) and has finished. Nil when it's not worth a card.
    static func commandFinished(command: String, duration: TimeInterval?, exitCode: Int?, threshold: Double, place: String) -> Card? {
        guard threshold > 0, let d = duration, d >= threshold else { return nil }
        let ok = (exitCode ?? 0) == 0
        let took = "Took \(formatDuration(d))" + (ok ? "" : " \u{00B7} exit \(exitCode ?? -1)")
        return Card(title: ok ? "Command finished" : "Command failed", mark: ok ? .finished : .failed, lines: [place, command, took])
    }

    /// An agent that worked `worked` seconds and stopped: done, or waiting on you. `prompt` is what it was asked last.
    /// `reply`: the start of its answer, when known (Claude's transcript, see ClaudeTranscript).
    static func agentStopped(agent: String, waiting: Bool, worked: TimeInterval, prompt: String?, place: String, reply: String? = nil) -> Card {
        let asked = prompt.map { "\u{276F} " + $0.split(whereSeparator: \.isNewline).joined(separator: " ") }
        let answer = reply.flatMap { $0.isEmpty ? nil : $0 }
        return Card(title: agent + (waiting ? " needs your input" : " finished"), mark: waiting ? .needsInput : .finished,
                    lines: [place] + (asked.map { [$0] } ?? []) + (answer.map { [$0] } ?? []) + ["Worked \(formatDuration(worked))"])
    }

    static func lostConnection(host: String, place: String, folder: String?) -> Card {
        Card(title: "Lost connection to \(host)", mark: .lostConnection, lines: [place, folder ?? ""].filter { !$0.isEmpty })
    }
}

/// Watches an agent work and stop, as the Mac does: it counts as stopped only after a few seconds without working
/// again, so pauses between its steps don't each make a card.
struct AgentStopWatch {
    /// When it started working, this stretch.
    private(set) var workingSince: Date?
    /// When it last stopped working, while that's still to be confirmed.
    private(set) var stoppedAt: Date?
    static let settle: TimeInterval = 2.5

    /// The agent's status now: working, or anything else (nil: no agent).
    mutating func update(working: Bool, now: Date = Date()) {
        if working {
            stoppedAt = nil
            if workingSince == nil { workingSince = now }
        } else if workingSince != nil, stoppedAt == nil {
            stoppedAt = now
        }
    }

    /// Once it's been stopped long enough: how long it worked (to when it stopped), and the watch starts over. Nil
    /// while that's still to see. `stillStopped`: it's done or waiting, not gone or failed.
    mutating func settled(now: Date = Date(), stillStopped: Bool) -> TimeInterval? {
        guard let since = workingSince, let stopped = stoppedAt, now.timeIntervalSince(stopped) >= Self.settle else { return nil }
        workingSince = nil
        stoppedAt = nil
        return stillStopped ? stopped.timeIntervalSince(since) : nil
    }
}
