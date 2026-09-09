import AppKit

/// Colours for every token kind, plus the editor chrome. Defined with dynamic providers so the
/// same document reads correctly in light and dark without the app tracking appearance itself.
enum EditorTheme {

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (red, green, blue) = isDark ? dark : light
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                           blue: CGFloat(blue) / 255, alpha: 1)
        }
    }

    // A restrained palette: keywords and strings carry most of the signal, everything else
    // stays close to the body colour so code does not read as a rainbow.
    static let plain      = dynamic(light: (0, 0, 0),       dark: (222, 226, 232))
    static let keyword    = dynamic(light: (155, 35, 147),  dark: (252, 95, 163))
    static let type       = dynamic(light: (11, 79, 121),   dark: (93, 216, 255))
    static let builtin    = dynamic(light: (57, 0, 160),    dark: (208, 168, 255))
    static let string     = dynamic(light: (196, 26, 22),   dark: (252, 106, 93))
    static let escape     = dynamic(light: (128, 12, 100),  dark: (255, 160, 200))
    static let number     = dynamic(light: (28, 0, 207),    dark: (208, 191, 105))
    static let comment    = dynamic(light: (93, 108, 121),  dark: (128, 145, 160))
    static let docComment = dynamic(light: (80, 120, 80),   dark: (140, 190, 140))
    static let function   = dynamic(light: (52, 89, 128),   dark: (120, 194, 217))
    static let attribute  = dynamic(light: (170, 90, 20),   dark: (230, 165, 90))
    static let directive  = dynamic(light: (120, 70, 30),   dark: (215, 155, 105))
    static let key        = dynamic(light: (11, 79, 121),   dark: (127, 191, 255))
    static let tag        = dynamic(light: (155, 35, 147),  dark: (150, 200, 255))
    static let heading    = dynamic(light: (0, 51, 153),    dark: (130, 175, 255))
    static let emphasis   = dynamic(light: (60, 60, 60),    dark: (200, 200, 200))
    static let link       = dynamic(light: (20, 100, 190),  dark: (110, 175, 255))
    static let invalid    = dynamic(light: (200, 30, 30),   dark: (255, 110, 110))

    static let gutterText     = dynamic(light: (150, 155, 160), dark: (110, 118, 128))
    static let gutterCurrent  = dynamic(light: (60, 60, 60),    dark: (215, 220, 226))
    static let gutterBack     = dynamic(light: (246, 247, 249), dark: (33, 36, 41))
    static let currentLine    = dynamic(light: (238, 242, 248), dark: (44, 48, 55))
    static let background     = dynamic(light: (255, 255, 255), dark: (28, 31, 35))
    static let bracketMatch   = dynamic(light: (200, 215, 235), dark: (70, 92, 120))
    static let errorTint      = dynamic(light: (204, 40, 40),   dark: (255, 105, 105))
    static let warningTint    = dynamic(light: (176, 128, 0),   dark: (230, 190, 80))
    static let infoTint       = dynamic(light: (60, 120, 190),  dark: (120, 180, 255))

    static func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .plain, .punctuation, .op: return plain
        case .keyword: return keyword
        case .type: return type
        case .builtin: return builtin
        case .string, .regex: return string
        case .escape: return escape
        case .interpolation: return escape
        case .number: return number
        case .comment: return comment
        case .docComment: return docComment
        case .function: return function
        case .attribute: return attribute
        case .directive: return directive
        case .key: return key
        case .tag: return tag
        case .heading: return heading
        case .emphasis: return emphasis
        case .link: return link
        case .invalid: return invalid
        }
    }

    /// Markdown wants weight, not just colour.
    static func traits(for kind: TokenKind) -> NSFontTraitMask? {
        switch kind {
        case .heading: return .boldFontMask
        case .emphasis: return .italicFontMask
        default: return nil
        }
    }

    static var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: "editorFontSize")
            return stored >= 8 ? stored : 13
        }
        set { UserDefaults.standard.set(newValue, forKey: "editorFontSize") }
    }

    static var font: NSFont {
        NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    static func font(_ traits: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: traits)
    }

    static var showsInvisibles: Bool {
        get { UserDefaults.standard.bool(forKey: "editorShowsInvisibles") }
        set { UserDefaults.standard.set(newValue, forKey: "editorShowsInvisibles") }
    }

    static var wrapsLines: Bool {
        get { UserDefaults.standard.object(forKey: "editorWrapsLines") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "editorWrapsLines") }
    }
}
