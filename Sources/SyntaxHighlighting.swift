import AppKit

// Syntax colors for the config formats (JSON, YAML, XML) and source files, scripts, markdown and diffs. What each part of the text is comes from
// SyntaxScanner (Core/Syntax.swift), shared with Windows; this paints it in the theme's colors. Beautify is Prettifier
// (Core/Prettifier.swift), also shared.

enum SyntaxHighlighter {
    /// Larger files stay plain: re-coloring runs on every edit.
    static let maxLength = SyntaxScanner.maxLength

    private static func color(_ t: SyntaxToken, _ th: Theme) -> NSColor {
        switch t {
        // The theme's terminal colors, as editors pair them: keywords magenta, strings green, numbers and constants
        // yellow, functions and keys blue, types cyan, variables red.
        case .comment: return th.foreground.withAlphaComponent(0.42)
        case .key, .tag, .function: return th.ansi[4]
        case .string: return th.green
        case .number, .literal, .attribute: return th.yellow
        case .keyword, .entity: return th.ansi[5]
        case .type: return th.ansi[6]
        case .variable, .removed: return th.red
        case .punctuation: return th.foreground.withAlphaComponent(0.5)
        }
    }

    /// Colors `text` in place (foreground only); call after resetting it to the plain foreground.
    static func highlight(_ text: NSMutableAttributedString, as language: SyntaxLanguage, theme th: Theme = Config.shared.theme) {
        guard text.length <= maxLength else { return }
        if language == .log {
            LogPainter.paint(text, in: NSRange(location: 0, length: text.length), format: .builtIn, theme: th)
            return
        }
        paint(text, SyntaxScanner.tokens(in: text.string, as: language), theme: th)
    }

    /// Colors already-scanned `tokens` into `text` (foreground only), skipping any past its end.
    static func paint(_ text: NSMutableAttributedString, _ tokens: [(range: NSRange, token: SyntaxToken)], theme th: Theme) {
        // One color object per kind, not one per token.
        var colors: [SyntaxToken: NSColor] = [:]
        for (range, token) in tokens where NSMaxRange(range) <= text.length {
            let c = colors[token] ?? color(token, th)
            colors[token] = c
            text.addAttribute(.foregroundColor, value: c, range: range)
        }
    }
}
