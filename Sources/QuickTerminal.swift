import AppKit
import Carbon

/// System-wide hotkey via Carbon (needs no Accessibility permission).
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1
    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(spec: String, handler: @escaping () -> Void) {
        guard let (code, mods) = HotKey.parse(spec) else { return nil }
        HotKey.installHandler()
        id = HotKey.nextID
        HotKey.nextID += 1
        let hkID = EventHotKeyID(signature: OSType(0x5052_4953), id: id)
        let status = RegisterEventHotKey(code, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        HotKey.handlers[id] = handler
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func parse(_ s: String) -> (UInt32, UInt32)? {
        let parts = s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var mods: UInt32 = 0
        var key: String?
        for p in parts {
            switch p {
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "alt", "opt", "option": mods |= UInt32(optionKey)
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            case "": key = "+"
            default: key = p
            }
        }
        guard let k = key, let code = keyCodes[k] else { return nil }
        return (UInt32(code), mods)
    }

    static func displayString(_ s: String) -> String {
        let parts = s.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var out = ""
        var key = ""
        for p in parts {
            switch p {
            case "ctrl", "control": out += "⌃"
            case "alt", "opt", "option": out += "⌥"
            case "shift": out += "⇧"
            case "cmd", "command": out += "⌘"
            default: key = p == "space" ? "Space" : p.uppercased()
            }
        }
        return out + key
    }

    private static let keyCodes: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "`": kVK_ANSI_Grave, "grave": kVK_ANSI_Grave, "backtick": kVK_ANSI_Grave,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash,
        "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
    ]
}

final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Drop-down terminal that slides from the top of the screen on a global hotkey.
final class QuickTerminalController: NSWindowController, NSWindowDelegate, TabOwner {
    static let shared = QuickTerminalController()

    private let rootView = WindowRootView()
    private var tab: TabSession?
    private var previousApp: NSRunningApplication?
    private var animating = false
    private(set) var isShown = false
    private var configObserver: NSObjectProtocol?

    private init() {
        let panel = QuickTerminalPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                                       styleMask: [.borderless, .resizable, .fullSizeContentView],
                                       backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.contentView = rootView
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = 12
        rootView.layer?.masksToBounds = true
        rootView.layer?.borderWidth = 1
        super.init(window: panel)
        panel.delegate = self
        rootView.applyTheme()
        rootView.layer?.borderColor = Config.shared.theme.border.cgColor
        configObserver = NotificationCenter.default.addObserver(forName: .solanumConfigChanged, object: nil, queue: .main) { [weak self] _ in
            self?.rootView.applyTheme()
            self?.rootView.layer?.borderColor = Config.shared.theme.border.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func toggle() {
        guard let w = window else { return }
        if isShown {
            if w.isKeyWindow && NSApp.isActive { hide() } else { show() }
        } else {
            show()
        }
    }

    private func targetFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let h = round(vf.height * Config.shared.quickTerminalHeight)
        return NSRect(x: vf.minX + 10, y: vf.maxY - h - 6, width: vf.width - 20, height: h)
    }

    func show() {
        guard let w = window, !animating else { return }
        if tab == nil {
            let t = TabSession(cwd: NSHomeDirectory())
            t.owner = self
            t.view.frame = rootView.content.bounds
            t.view.autoresizingMask = [.width, .height]
            rootView.content.addSubview(t.view)
            tab = t
        }
        if !isShown {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front == NSRunningApplication.current ? nil : front
        }
        let target = targetFrame()
        if !isShown {
            var start = target
            start.origin.y += 40
            w.setFrame(start, display: false)
            w.alphaValue = 0
        }
        isShown = true
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(target, display: true)
            w.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.animating = false
            self?.tab?.focus()
        })
        tab?.focus()
    }

    func hide() {
        guard let w = window, isShown, !animating else { return }
        isShown = false
        animating = true
        var end = w.frame
        end.origin.y += 40
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().setFrame(end, display: true)
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            w.orderOut(nil)
            self.animating = false
            // Hand focus back to whatever app was in front when the quick terminal was summoned.
            self.previousApp?.activate()
            self.previousApp = nil
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        guard Config.shared.quickTerminalAutoHide, isShown, !animating, window?.attachedSheet == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let w = self.window, !w.isKeyWindow, w.attachedSheet == nil else { return }
            self.hide()
        }
    }

    // MARK: TabOwner

    func tabDidUpdate(_ tab: TabSession) {}

    func tabDidFocus(_ tab: TabSession) {}

    func tabWantsClose(_ tab: TabSession) {}
    func isActiveTab(_ tab: TabSession) -> Bool { window?.isKeyWindow ?? false }

    func tabDidClose(_ tab: TabSession) {
        tab.view.removeFromSuperview()
        self.tab = nil
        hide()
    }

    @objc func showCommandPalette(_ sender: Any?) {
        guard let w = window else { return }
        CommandPalette.toggle(in: w)
    }
}
