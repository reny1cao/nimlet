import Foundation
import AppKit
import Combine

/// Whether a newer Mac companion exists.
///
/// The phone updates itself; this app is a zip somebody downloaded once. Left
/// alone, the two drift apart — the phone speaks a newer protocol, the Mac
/// serves what it can, and features go quietly missing with nothing on the
/// Mac to say why. So, at most every six hours, this asks nimlet.app for one
/// small JSON file naming the current build, and the menu says so when it is
/// newer than this one. Nothing is downloaded or installed by itself.
///
/// What leaves the machine: a GET for a fixed URL, with no query string, no
/// cookies and no identifier of any kind — the same request a browser would
/// make opening that address. PRIVACY.md says so. It can be switched off:
///
///     defaults write com.renyicao.mice.host mice.updates.check -bool NO
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()

    /// What `latest.json` carries. `Scripts/package-host.sh` writes it beside
    /// each zip; publishing both is what makes a release visible here.
    struct Release: Equatable, Decodable {
        var version: String
        var build: Int
        var url: URL
        var notes: String?
    }

    static let feed = URL(string: "https://nimlet.app/releases/latest.json")!
    static let downloadPage = URL(string: "https://nimlet.app/download/")!
    private static let interval: TimeInterval = 6 * 60 * 60
    private static let enabledKey = "mice.updates.check"

    @Published private(set) var available: Release?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastProblem: String?

    private let session: URLSession
    private var timer: Timer?
    private var inFlight = false

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil
            || UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    static var currentVersion: String {
        let marketing = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(marketing) (\(build))"
    }

    /// Once, half a minute after launch — a launch is the moment the user is
    /// least interested in a banner — and then on the interval.
    func begin() {
        guard Self.isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.check()
        }
        timer?.tolerance = 5 * 60
    }

    /// For the menu opening: a check if the last one is stale, else nothing.
    func checkIfStale() {
        guard Self.isEnabled else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        check()
    }

    func check() {
        guard Self.isEnabled, !inFlight else { return }
        inFlight = true
        var request = URLRequest(url: Self.feed)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Nimlet/\(Self.currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                self.lastChecked = Date()
                if let error {
                    self.lastProblem = error.localizedDescription
                    miceLog.info("update check: \(error.localizedDescription, privacy: .public)")
                    return
                }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let data, let release = try? JSONDecoder().decode(Release.self, from: data) else {
                    self.lastProblem = "No release information at nimlet.app"
                    return
                }
                self.lastProblem = nil
                self.available = release.build > Self.currentBuild ? release : nil
                miceLog.info("update check: latest is \(release.version, privacy: .public) (\(release.build)), this is \(Self.currentVersion, privacy: .public)")
            }
        }.resume()
    }

    func openDownload() {
        NSWorkspace.shared.open(available?.url ?? Self.downloadPage)
    }
}
