import AppKit
import ApplicationServices
import Foundation

/// The words the phone's dictation should be biased toward for one target.
///
/// On-device transcription hears "host server" for `HostServer` and "line framer"
/// for `LineFramer`, and no general-purpose vocabulary is ever going to contain
/// the names in somebody's repository. The names that matter are in the working
/// directory the target points at, so they are read from there.
final class Vocabulary {
    static let shared = Vocabulary()

    /// git is a subprocess and this reads files: it must never run on the
    /// network queue, where it would stall pointer delivery for the duration.
    let queue = DispatchQueue(label: "com.renyicao.mice.host.vocabulary", qos: .utility)

    /// `LineFramer` drops a line over 1 MiB, and a mid-size repository's terms
    /// exceed that comfortably, so a set goes out in chunks.
    static let chunkSize = 200
    static let maxTerms = 2000

    /// How much of a repository to read. The tail of a long history contributes
    /// little and costs the most.
    private static let fileBudget = 40
    private static let byteBudget = 256 * 1024
    private static let trackedFileBudget = 5000

    private struct Entry {
        var terms: [String]
        var at: Date
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    /// Long enough that pressing a target twice costs one git invocation, short
    /// enough that switching branches shows up without restarting anything.
    private let ttl: TimeInterval = 60

    func terms(for target: NimletTarget) -> [String] {
        guard let directory = workingDirectory(for: target) else { return [] }
        if let cached = lock.withLock({ cache[directory] }),
           Date().timeIntervalSince(cached.at) < ttl {
            return cached.terms
        }
        let terms = extract(from: directory)
        lock.withLock { cache[directory] = Entry(terms: terms, at: Date()) }
        return terms
    }

    // MARK: - Where the target is

    private func workingDirectory(for target: NimletTarget) -> String? {
        switch target.kind {
        case .tmux:
            guard let pane = target.tmuxTarget, target.hasStableTmuxID else { return nil }
            return Tmux.currentPath(ofPane: pane)
        case .app, .frontmost:
            return documentDirectory(of: runningApplication(for: target))
        }
    }

    private func runningApplication(for target: NimletTarget) -> NSRunningApplication? {
        if target.kind == .frontmost { return NSWorkspace.shared.frontmostApplication }
        guard let bundleID = target.bundleID else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// A GUI app does not publish the project it has open. The one thing it can
    /// be asked is which file its focused window stands for, which names a
    /// directory for an editor and nothing at all for anything else — and
    /// nothing is the right answer there, rather than a guess.
    private func documentDirectory(of app: NSRunningApplication?) -> String? {
        guard let app, EventInjector.shared.isTrusted else { return nil }
        // A busy app would otherwise hold this queue for the six-second default
        // per read, and every other target's vocabulary waits behind it.
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let window = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.5)
        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &document) == .success,
              let path = document as? String,
              let url = URL(string: path), url.isFileURL else { return nil }
        return url.deletingLastPathComponent().path
    }

    // MARK: - What is in it

    private func extract(from directory: String) -> [String] {
        guard let root = Git.root(of: directory) else { return [] }
        var scores: [String: Double] = [:]

        func offer(_ term: String, _ score: Double) {
            guard term.count >= 3, term.count <= 64 else { return }
            if let existing = scores[term], existing >= score { return }
            scores[term] = score
        }

        // The branch you are on is the phrase you are most likely to say.
        for branch in Git.branches(in: root) {
            offer(branch, 5)
            for part in Vocabulary.parts(of: branch) { offer(part, 4) }
        }

        let changed = Git.recentlyChangedFiles(in: root)
        for (index, path) in changed.enumerated() {
            // Recency, and nothing cleverer: the file touched in the last
            // commit is the one being talked about now.
            let recency = 4.0 / Double(index / 5 + 1)
            for term in Vocabulary.nameTerms(of: path) { offer(term, recency) }
            guard index < Vocabulary.fileBudget else { continue }
            for identifier in Vocabulary.identifiers(inFileAt: root + "/" + path) {
                offer(identifier, recency * 0.75)
            }
        }

        // Everything else that is tracked, as background: a file nobody has
        // touched recently is still a file you might name out loud.
        for path in Git.trackedFiles(in: root).prefix(Vocabulary.trackedFileBudget) {
            for term in Vocabulary.nameTerms(of: path) { offer(term, 0.5) }
        }

        return Vocabulary.rank(scores)
    }

    /// The file's own name, its stem, and the words inside them.
    private static func nameTerms(of path: String) -> [String] {
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return [name, stem] + parts(of: stem)
    }

    /// Splits `LineFramer`, `line_framer` and `line-framer` alike. Dictation
    /// hears the words, not the identifier, so both have to be offered.
    private static func parts(of identifier: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for character in identifier {
            if character == "_" || character == "-" || character == "/" || character == "." {
                if !current.isEmpty { parts.append(current) }
                current = ""
            } else if character.isUppercase, let last = current.last, last.isLowercase {
                parts.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts.count > 1 ? parts : []
    }

    /// Identifier-shaped tokens, without asking anyone to install ctags.
    /// Extensions worth tokenising for identifiers.
    ///
    /// Prose files are deliberately absent. Scanning everything tracked meant a
    /// repository's LICENSE — several thousand words of legal English — and its
    /// README competed for the same capped budget as the symbols someone
    /// actually says out loud, and being longer they usually won.
    private static let sourceExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "rs", "go", "java", "kt",
        "ts", "tsx", "js", "jsx", "py", "rb", "sh", "zsh", "bash", "sql", "php",
        "cs", "scala", "ex", "exs", "lua", "pl", "r", "yml", "yaml", "toml", "json",
    ]

    private static func identifiers(inFileAt path: String) -> [String] {
        let ext = (path as NSString).pathExtension.lowercased()
        guard sourceExtensions.contains(ext) else { return [] }
        guard let data = FileManager.default.contents(atPath: path),
              data.count <= byteBudget,
              let text = String(data: data, encoding: .utf8) else { return [] }

        var found: [String] = []
        var current = ""
        func flush() {
            defer { current = "" }
            guard current.count >= 3 else { return }
            found.append(current)
            found.append(contentsOf: parts(of: current))
        }
        for character in text {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return found
    }

    // MARK: - Ranking

    private static func rank(_ scores: [String: Double]) -> [String] {
        var best: [String: (term: String, score: Double)] = [:]
        for (term, score) in scores {
            guard term.count >= 3, !isNoise(term), !isOrdinaryWord(term) else { continue }
            let key = term.lowercased()
            if let existing = best[key], existing.score >= score { continue }
            best[key] = (term, score)
        }
        // Alphabetical within a score, so the same repository produces the same
        // list twice running and a truncated tail is not arbitrary.
        return best.values
            .sorted { $0.score == $1.score ? $0.term < $1.term : $0.score > $1.score }
            .prefix(maxTerms)
            .map(\.term)
    }

    /// Commit hashes, keycode literals and minified blobs tokenise beautifully
    /// and are worth nothing to a recogniser.
    private static func isNoise(_ term: String) -> Bool {
        // Nothing a person dictates as a name begins with a digit: no language
        // Nimlet delivers into allows it. This is what catches the shapes the
        // rules below miss — `0x24` is too short to look like a hash and is not
        // all hex digits either, because `x` is not one.
        if let first = term.first, first.isNumber { return true }
        if term.allSatisfy(\.isNumber) { return true }
        if term.count > 6, term.allSatisfy(\.isHexDigit) { return true }
        return false
    }

    /// `/usr/share/dict/words` ships with macOS. An ordinary English word is
    /// exactly what the recogniser already knows, so biasing toward it spends a
    /// slot that one of the repository's own names should have had.
    private static let dictionaryWords: Set<String> = {
        guard let data = FileManager.default.contents(atPath: "/usr/share/dict/words"),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    private static func isOrdinaryWord(_ term: String) -> Bool {
        // Internal capitals, digits or an underscore make a term a name even
        // when its letters spell something: Codable, utf8, is_final.
        guard term == term.lowercased(), term.allSatisfy(\.isLetter) else { return false }
        return dictionaryWords.contains(term)
    }
}

/// Just enough git to answer "what is this project called, and what has been
/// happening in it lately".
private enum Git {
    static var executableURL: URL? {
        let manager = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/opt/local/bin/git"]
        where manager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // /usr/bin/git exists on every Mac, but on one without the Command
        // Line Tools or Xcode it is Apple's shim, and running it puts up the
        // "install developer tools?" dialog — from a menu bar app, in the
        // middle of somebody's first session. Only use it when there is a
        // real git behind it.
        let developerGit = ["/Library/Developer/CommandLineTools/usr/bin/git",
                            "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        if developerGit.contains(where: { manager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: "/usr/bin/git")
        }
        return nil
    }

    static func run(_ arguments: [String]) -> Subprocess.Result {
        guard let executableURL else { return Subprocess.Result(ok: false, output: "git not found") }
        return Subprocess.run(executableURL, arguments)
    }

    static func root(of directory: String) -> String? {
        let result = run(["-C", directory, "rev-parse", "--show-toplevel"])
        guard result.ok, !result.output.isEmpty else { return nil }
        return result.output
    }

    static func branches(in root: String) -> [String] {
        let result = run(["-C", root, "branch", "--format=%(refname:short)"])
        guard result.ok else { return [] }
        return result.output.split(separator: "\n").map(String.init)
    }

    static func trackedFiles(in root: String) -> [String] {
        let result = run(["-C", root, "ls-files"])
        guard result.ok else { return [] }
        return result.output.split(separator: "\n").map(String.init)
    }

    /// Files touched by the last twenty commits, most recent first.
    ///
    /// `diff --name-only HEAD~20` asks the same question but fails outright on a
    /// repository with fewer than twenty commits, and returns an unordered set,
    /// which is no use when the ranking is supposed to be by recency.
    static func recentlyChangedFiles(in root: String) -> [String] {
        let result = run(["-C", root, "log", "-n", "20", "--name-only", "--pretty=format:"])
        guard result.ok else { return [] }
        var seen: Set<String> = []
        var ordered: [String] = []
        for line in result.output.split(separator: "\n") {
            let path = String(line)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            // A file named in the last twenty commits may well have been the
            // file those commits deleted, and biasing a recogniser toward a
            // symbol nobody can refer to any more spends a slot for nothing.
            guard FileManager.default.fileExists(atPath: root + "/" + path) else { continue }
            ordered.append(path)
        }
        return ordered
    }
}
