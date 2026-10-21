import Foundation

/// Which of a Mac's applications are worth offering as a target, and in what
/// order to offer them.
///
/// The phone cannot answer either question — it cannot see the Mac's disk, let
/// alone how often anything on it has been opened — so this is the Mac's
/// answer, and the phone's job is only to draw it. It lives in `Shared`
/// because the arithmetic is the part most likely to be wrong and the part
/// easiest to test, and because the curated table below was being kept in two
/// places at once.
public enum AppRanking {
    /// An app Nimlet exists to talk to, with the glyph to draw before its own
    /// icon arrives.
    ///
    /// This is not a list of good applications. It is a list of the ones a
    /// person installs Nimlet *for* — agents, the terminals they run in, the
    /// editors beside them, and the browser the work is looked at in — and it
    /// exists so that a dock on a machine with a hundred apps opens pointing at
    /// those rather than at whatever was launched most times last year.
    public struct Known: Sendable, Hashable {
        public let name: String
        public let bundleID: String
        public let symbol: String

        public init(name: String, bundleID: String, symbol: String) {
            self.name = name
            self.bundleID = bundleID
            self.symbol = symbol
        }
    }

    public static let curated: [Known] = [
        Known(name: "Claude", bundleID: "com.anthropic.claudefordesktop", symbol: "sparkle"),
        Known(name: "Codex", bundleID: "com.openai.codex",
              symbol: "chevron.left.forwardslash.chevron.right"),
        Known(name: "ChatGPT", bundleID: "com.openai.chat",
              symbol: "bubble.left.and.text.bubble.right"),
        // Terminals.
        Known(name: "iTerm", bundleID: "com.googlecode.iterm2", symbol: "terminal"),
        Known(name: "Terminal", bundleID: "com.apple.Terminal", symbol: "terminal"),
        Known(name: "Ghostty", bundleID: "com.mitchellh.ghostty", symbol: "terminal"),
        Known(name: "WezTerm", bundleID: "com.github.wez.wezterm", symbol: "terminal"),
        Known(name: "Kitty", bundleID: "net.kovidgoyal.kitty", symbol: "terminal"),
        Known(name: "Alacritty", bundleID: "org.alacritty", symbol: "terminal"),
        Known(name: "Warp", bundleID: "dev.warp.Warp-Stable", symbol: "terminal"),
        Known(name: "Hyper", bundleID: "co.zeit.hyper", symbol: "terminal"),
        // Editors, which is where the other half of the work happens.
        Known(name: "VS Code", bundleID: "com.microsoft.VSCode",
              symbol: "chevron.left.forwardslash.chevron.right"),
        Known(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92",
              symbol: "chevron.left.forwardslash.chevron.right"),
        Known(name: "Windsurf", bundleID: "com.exafunction.windsurf",
              symbol: "chevron.left.forwardslash.chevron.right"),
        Known(name: "Zed", bundleID: "dev.zed.Zed",
              symbol: "chevron.left.forwardslash.chevron.right"),
        Known(name: "Xcode", bundleID: "com.apple.dt.Xcode", symbol: "hammer"),
        // The browser is where the thing being built is looked at, and reload
        // is the key pressed most often while looking at it.
        Known(name: "Safari", bundleID: "com.apple.Safari", symbol: "globe"),
        Known(name: "Chrome", bundleID: "com.google.Chrome", symbol: "globe"),
        Known(name: "Arc", bundleID: "company.thebrowser.Browser", symbol: "globe"),
    ]

    private static let curatedByID: [String: Known] = {
        var map: [String: Known] = [:]
        for app in curated { map[app.bundleID.lowercased()] = app }
        return map
    }()

    public static func known(bundleID: String) -> Known? {
        curatedByID[bundleID.lowercased()]
    }

    /// The glyph to draw for an app before — or instead of — its own icon.
    ///
    /// `app` rather than something clever for an app nobody wrote an entry for:
    /// the real icon is on its way, and a wrong guess at what an app is for is
    /// worse than a plain square for the half second before it lands.
    public static func symbol(bundleID: String) -> String {
        known(bundleID: bundleID)?.symbol ?? "app"
    }

    // MARK: - The score

    /// A use count halves in weight every fortnight it goes unused.
    private static let halfLifeDays = 14.0
    /// What an app that has never been opened keeps of its count. Not zero:
    /// Spotlight's counter resets with its index, and an app it has forgotten
    /// about should sink rather than vanish.
    private static let staleFloor = 0.02
    /// Where a launch count stops meaning anything, in the log's own units: ten
    /// is about a thousand launches.
    ///
    /// Past that the number is measuring how long the app has been installed
    /// rather than how much it is wanted here. Without the cap a browser opened
    /// twenty-six thousand times — a real figure off a real Mac — outscored
    /// every agent on the machine by more than the three bonuses put together,
    /// and no amount of "but it is running right now" could reach it.
    private static let countCeiling = 10.0
    static let runningBonus = 2.5
    static let dockBonus = 1.5
    static let curatedBonus = 3.0

    /// How strongly an app should be offered, from what the Mac knows about it.
    ///
    /// The count is logarithmic, and capped, because launch counts are: a
    /// browser opened twenty-six thousand times is not two hundred times more
    /// wanted here than an agent opened a hundred times, it is a browser and it
    /// has been installed for three years. Recency is what
    /// separates the tool being used today from the one used every day in June,
    /// and the bonuses are for the three things a count cannot see — that it is
    /// open right now, that the user thought it worth keeping in their Dock,
    /// and that it is the kind of app Nimlet is for.
    public static func score(useCount: Int,
                             lastUsed: Date?,
                             isRunning: Bool,
                             isDocked: Bool,
                             isCurated: Bool,
                             now: Date = Date()) -> Double {
        let base = min(log2(1 + Double(max(0, useCount))), countCeiling)
        var weight = staleFloor
        if let lastUsed {
            let days = max(0, now.timeIntervalSince(lastUsed) / 86_400)
            weight = max(staleFloor, pow(0.5, days / halfLifeDays))
        }
        var score = base * weight
        if isRunning { score += runningBonus }
        if isDocked { score += dockBonus }
        if isCurated { score += curatedBonus }
        return score
    }
}
