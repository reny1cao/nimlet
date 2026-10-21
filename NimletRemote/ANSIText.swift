import SwiftUI

/// Turns `tmux capture-pane -e` output into styled text.
///
/// Colour is not decoration in an agent pane — diffs, prompts, spinners and
/// error output are all told apart by it, and a stripped-down monochrome mirror
/// is markedly harder to read at a glance. Only SGR is interpreted; every other
/// escape sequence is dropped, because a captured pane is already a settled
/// screen and cursor motion would only corrupt it.
enum ANSIText {

    struct Style: Equatable {
        var foreground: Color?
        var background: Color?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false

        mutating func reset() { self = Style() }
    }

    static func attributed(_ source: String, defaultForeground: Color) -> [AttributedString] {
        source.split(separator: "\n", omittingEmptySubsequences: false).map {
            line(String($0), defaultForeground: defaultForeground)
        }
    }

    private static func line(_ source: String, defaultForeground: Color) -> AttributedString {
        var result = AttributedString()
        var style = Style()
        var pending = ""
        let characters = Array(source)
        var index = 0

        func flush() {
            guard !pending.isEmpty else { return }
            var run = AttributedString(pending)
            var foreground = style.foreground ?? defaultForeground
            var background = style.background
            if style.inverse {
                let swapped = foreground
                foreground = background ?? .black
                background = swapped
            }
            run.foregroundColor = style.dim ? foreground.opacity(0.55) : foreground
            if let background { run.backgroundColor = background }
            if style.underline { run.underlineStyle = .single }
            // Tracked but never applied until now, which lost the emphasis an
            // agent pane uses to separate its own voice from command output.
            // As an intent rather than a font, so it composes with whatever size
            // the view has picked instead of pinning one here.
            var emphasis: InlinePresentationIntent = []
            if style.bold { emphasis.insert(.stronglyEmphasized) }
            if style.italic { emphasis.insert(.emphasized) }
            if !emphasis.isEmpty { run.inlinePresentationIntent = emphasis }
            result.append(run)
            pending = ""
        }

        while index < characters.count {
            let character = characters[index]
            guard character == "\u{1B}" else {
                pending.append(character)
                index += 1
                continue
            }
            index += 1
            guard index < characters.count else { break }

            if characters[index] == "[" {
                index += 1
                var parameters = ""
                while index < characters.count, !("\u{40}"..."\u{7E}").contains(characters[index]) {
                    parameters.append(characters[index])
                    index += 1
                }
                guard index < characters.count else { break }
                let final = characters[index]
                index += 1
                if final == "m" {
                    flush()
                    apply(parameters, to: &style)
                }
                // Any other CSI (cursor moves, erases) is ignored by design.
            } else if characters[index] == "]" {
                // OSC: run to BEL or ST.
                index += 1
                while index < characters.count {
                    if characters[index] == "\u{07}" { index += 1; break }
                    if characters[index] == "\u{1B}", index + 1 < characters.count, characters[index + 1] == "\\" {
                        index += 2; break
                    }
                    index += 1
                }
            } else {
                // Two-character escapes: charset selection and friends.
                index += 1
            }
        }
        flush()
        return result
    }

    private static func apply(_ parameters: String, to style: inout Style) {
        let codes = parameters.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: style.reset()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 30...37: style.foreground = basic(code - 30, bright: false)
            case 39: style.foreground = nil
            case 40...47: style.background = basic(code - 40, bright: false)
            case 49: style.background = nil
            case 90...97: style.foreground = basic(code - 90, bright: true)
            case 100...107: style.background = basic(code - 100, bright: true)
            case 38, 48:
                let (colour, consumed) = extended(codes, from: index + 1)
                if code == 38 { style.foreground = colour } else { style.background = colour }
                index += consumed
            default: break
            }
            index += 1
        }
    }

    /// 256-colour and 24-bit forms: `38;5;n` and `38;2;r;g;b`.
    private static func extended(_ codes: [Int], from start: Int) -> (Color?, Int) {
        guard start < codes.count else { return (nil, 0) }
        switch codes[start] {
        case 5:
            guard start + 1 < codes.count else { return (nil, 1) }
            return (xterm(codes[start + 1]), 2)
        case 2:
            guard start + 3 < codes.count else { return (nil, 1) }
            return (Color(red: Double(codes[start + 1]) / 255,
                          green: Double(codes[start + 2]) / 255,
                          blue: Double(codes[start + 3]) / 255), 4)
        default:
            return (nil, 1)
        }
    }

    private static let normal: [Color] = [
        Color(white: 0.16), Color(red: 0.80, green: 0.27, blue: 0.27),
        Color(red: 0.33, green: 0.71, blue: 0.36), Color(red: 0.80, green: 0.66, blue: 0.24),
        Color(red: 0.31, green: 0.55, blue: 0.90), Color(red: 0.72, green: 0.40, blue: 0.85),
        Color(red: 0.25, green: 0.70, blue: 0.72), Color(white: 0.80),
    ]

    private static let vivid: [Color] = [
        Color(white: 0.45), Color(red: 0.95, green: 0.42, blue: 0.40),
        Color(red: 0.49, green: 0.85, blue: 0.48), Color(red: 0.95, green: 0.82, blue: 0.40),
        Color(red: 0.45, green: 0.69, blue: 1.00), Color(red: 0.85, green: 0.56, blue: 0.96),
        Color(red: 0.40, green: 0.85, blue: 0.86), Color(white: 0.97),
    ]

    /// The 6x6x6 cube's axis, as xterm defines it.
    private static let cubeLevels: [Double] = [0, 0.37, 0.53, 0.68, 0.84, 1.0]

    private static func basic(_ index: Int, bright: Bool) -> Color {
        let palette = bright ? vivid : normal
        return palette[min(max(index, 0), palette.count - 1)]
    }

    private static func xterm(_ index: Int) -> Color {
        switch index {
        case 0...7: return basic(index, bright: false)
        case 8...15: return basic(index - 8, bright: true)
        case 16...231:
            let value = index - 16
            return Color(red: cubeLevels[value / 36],
                         green: cubeLevels[(value / 6) % 6],
                         blue: cubeLevels[value % 6])
        case 232...255:
            return Color(white: (Double(index - 232) * 10 + 8) / 255)
        default:
            return .white
        }
    }
}
