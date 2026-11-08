import AppKit

// Syntax colors for the hand-edited config formats: JSON, YAML and XML. What each part of the text is comes from
// SyntaxScanner (Core/Syntax.swift), shared with Windows; this paints it in the theme's colors. Beautify is Prettifier
// (Core/Prettifier.swift), also shared.

enum SyntaxHighlighter {
    /// Larger files stay plain: re-coloring runs on every edit.
    static let maxLength = SyntaxScanner.maxLength

    private static func color(_ t: SyntaxToken, _ th: Theme) -> NSColor {
        switch t {
        case .comment: return th.foreground.withAlphaComponent(0.42)
        case .key, .tag: return th.ansi[4]
        case .string: return th.green
        case .number: return th.ansi[5]
        case .literal: return th.ansi[6]
        case .attribute: return th.yellow
        case .punctuation: return th.foreground.withAlphaComponent(0.5)
        case .entity: return th.ansi[5]
        }
    }

    /// Colors `text` in place (foreground only); call after resetting it to the plain foreground.
    static func highlight(_ text: NSMutableAttributedString, as language: SyntaxLanguage, theme th: Theme = Config.shared.theme) {
        guard text.length <= maxLength else { return }
        for (range, token) in SyntaxScanner.tokens(in: text.string, as: language) {
            text.addAttribute(.foregroundColor, value: color(token, th), range: range)
        }
    }
}
