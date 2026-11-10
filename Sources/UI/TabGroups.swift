import Foundation

/// The colors a tab group can be, as on the Mac.
enum TabGroupColor: String, CaseIterable {
    case blue, red, yellow, green, pink, purple, cyan, orange, grey

    var rgb: UInt32 {
        switch self {
        case .blue: return 0x5B8DEF
        case .red: return 0xE8655F
        case .yellow: return 0xE9B949
        case .green: return 0x4FB477
        case .pink: return 0xE36FA8
        case .purple: return 0x9A7BEA
        case .cyan: return 0x3FB8C9
        case .orange: return 0xEE8B4A
        case .grey: return 0x8E949C
        }
    }

    var title: String { rawValue.capitalized }
}

/// A named, colored run of tabs side by side that can be collapsed, like a browser's tab group.
final class TabGroup {
    var name = ""
    var color: TabGroupColor
    var collapsed = false

    init(color: TabGroupColor) { self.color = color }

    var displayName: String { name.isEmpty ? "\(color.title) group" : name }

    /// What its chip says: its name, and how many tabs it's hiding when collapsed.
    func chipLabel(count: Int) -> String {
        guard collapsed else { return name }
        return name.isEmpty ? "\(count)" : "\(name)  \(count)"
    }
}

protocol Groupable: AnyObject {
    var group: TabGroup? { get set }
}

/// Moving tabs into and out of groups, so that each group's tabs always stay side by side.
enum TabGroupOps {
    /// The groups in the order their tabs come.
    static func groups<T: Groupable>(in tabs: [T]) -> [TabGroup] {
        var seen: [TabGroup] = []
        for tab in tabs { if let g = tab.group, !seen.contains(where: { $0 === g }) { seen.append(g) } }
        return seen
    }

    /// The first color no group is using, else the one used least.
    static func nextColor<T: Groupable>(in tabs: [T]) -> TabGroupColor {
        let used = groups(in: tabs).map(\.color)
        return TabGroupColor.allCases.min { a, b in used.filter { $0 == a }.count < used.filter { $0 == b }.count } ?? .blue
    }

    /// Gathers the picked tabs where the first of them was, in a new group. It never lands inside another group.
    static func addToNewGroup<T: Groupable>(_ tabs: inout [T], picked list: [T]) -> TabGroup? {
        let picked = tabs.filter { tab in list.contains { $0 === tab } }
        guard let first = picked.first, let firstIndex = tabs.firstIndex(where: { $0 === first }) else { return nil }
        let group = TabGroup(color: nextColor(in: tabs))
        var rest = tabs.filter { tab in !picked.contains { $0 === tab } }
        var at = tabs[..<firstIndex].filter { tab in !picked.contains { $0 === tab } }.count
        // Landing inside another group would split it, so it goes after that group.
        while at > 0, at < rest.count, let g = rest[at].group, rest[at - 1].group === g { at += 1 }
        rest.insert(contentsOf: picked, at: at)
        tabs = rest
        picked.forEach { $0.group = group }
        return group
    }

    /// Moves a tab to the end of a group.
    static func add<T: Groupable>(_ tab: T, to group: TabGroup, in tabs: inout [T]) {
        guard tab.group !== group else { return }
        tabs.removeAll { $0 === tab }
        let at = tabs.lastIndex { $0.group === group }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: at)
        tab.group = group
    }

    /// Takes a tab out of its group, moving it just past the group's end so the rest stay together.
    static func remove<T: Groupable>(_ tab: T, in tabs: inout [T]) {
        guard let group = tab.group else { return }
        tab.group = nil
        tabs.removeAll { $0 === tab }
        let at = tabs.lastIndex { $0.group === group }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: min(at, tabs.count))
    }

    /// After a tab has been dragged somewhere: it joins a group it's landed in the middle of, and leaves its own if it's
    /// been dragged away from it.
    static func settle<T: Groupable>(_ tab: T, in tabs: [T]) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        let left = i > 0 ? tabs[i - 1].group : nil, right = i + 1 < tabs.count ? tabs[i + 1].group : nil
        if let left, left === right {
            tab.group = left
        } else if let own = tab.group, left !== own, right !== own {
            tab.group = nil
        }
    }
}
