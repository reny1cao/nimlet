import XCTest

/// The Mac offers its own applications, ranked. These cover the two parts that
/// can be wrong without anything crashing: the order they come out in, and
/// whether an answer with icons in it fits down a socket whose lines are capped
/// at a megabyte.
final class AppCatalogTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    private func score(_ count: Int,
                       _ lastUsed: Date?,
                       running: Bool = false,
                       docked: Bool = false,
                       curated: Bool = false) -> Double {
        AppRanking.score(useCount: count, lastUsed: lastUsed, isRunning: running,
                         isDocked: docked, isCurated: curated, now: now)
    }

    // MARK: - The order

    func testTodayBeatsTheSameAppSixMonthsAgo() {
        // The point of weighting by recency at all: a tool used constantly in
        // June and not since is not what somebody wants in their dock today.
        XCTAssertGreaterThan(score(200, daysAgo(0)), score(200, daysAgo(180)))
    }

    func testALaunchCountCannotRunAwayWithTheList() {
        // A browser opened twenty-six thousand times is not two hundred times
        // more wanted here than an agent opened a hundred times — it is a
        // browser. The log is what keeps one app from owning the top of the
        // list outright.
        let browser = score(26_000, daysAgo(0))
        let agent = score(100, daysAgo(0), running: true, curated: true)
        XCTAssertGreaterThan(agent, browser,
                             "an agent open right now outranks the browser's raw count")
    }

    func testAnAppSpotlightHasNeverSeenStillRanksIfItIsWhatNimletIsFor() {
        // Spotlight's counters reset with its index, so "no count, no date" is
        // a statement about the index rather than about the app.
        let forgotten = score(0, nil, curated: true)
        XCTAssertGreaterThan(forgotten, 0)
        XCTAssertGreaterThan(forgotten, score(40, daysAgo(400)),
                             "a curated app beats one genuinely abandoned over a year ago")
    }

    func testRunningAndDockedBothCountAndRunningCountsForMore() {
        let base = score(50, daysAgo(10))
        XCTAssertEqual(score(50, daysAgo(10), running: true) - base,
                       AppRanking.runningBonus, accuracy: 0.0001)
        XCTAssertEqual(score(50, daysAgo(10), docked: true) - base,
                       AppRanking.dockBonus, accuracy: 0.0001)
        XCTAssertGreaterThan(AppRanking.runningBonus, AppRanking.dockBonus)
    }

    func testTheScoreIsStableForAnAppNothingIsKnownAbout() {
        XCTAssertEqual(score(0, nil), 0, accuracy: 0.0001,
                       "no count, no date and nothing special about it is nothing to say")
    }

    func testEveryCuratedEntryIsUsableAsATarget() {
        for known in AppRanking.curated {
            XCTAssertFalse(known.bundleID.isEmpty, "\(known.name) needs a bundle id")
            XCTAssertFalse(known.symbol.isEmpty, "\(known.name) needs a glyph")
            XCTAssertEqual(AppRanking.known(bundleID: known.bundleID.uppercased())?.bundleID,
                           known.bundleID,
                           "a bundle id off the wire is matched whatever its case")
        }
        let ids = Set(AppRanking.curated.map { $0.bundleID.lowercased() })
        XCTAssertEqual(ids.count, AppRanking.curated.count, "no bundle id is listed twice")
    }

    func testAnUnknownAppGetsAPlainGlyphRatherThanAGuess() {
        XCTAssertEqual(AppRanking.symbol(bundleID: "com.example.whatever"), "app")
        XCTAssertEqual(AppRanking.symbol(bundleID: "com.apple.Terminal"), "terminal")
    }

    // MARK: - Getting it down the wire

    private func app(_ id: String, iconBytes: Int = 0) -> MacApp {
        MacApp(bundleID: id, name: id,
               icon: iconBytes > 0 ? Data(repeating: 0xAB, count: iconBytes) : nil)
    }

    func testAChunkNeverGrowsPastTheFramersLine() throws {
        // Twenty-four icons at fifteen kilobytes apiece is comfortably past the
        // one-megabyte line, and an overlong line is not truncated — it is
        // dropped whole, in silence.
        let apps = (0..<24).map { app("app.\($0)", iconBytes: 15_000) }
        let chunks = AppCatalogPayload.chunked(apps, purpose: .suggestions)
        XCTAssertGreaterThan(chunks.count, 1, "this much would not have fitted in one line")
        for chunk in chunks {
            let line = try NimletCoder.line(HostMessage.apps(chunk))
            XCTAssertLessThan(line.count, 1 << 20, "a line the framer would throw away")
        }
        XCTAssertEqual(chunks.flatMap(\.apps).map(\.bundleID), apps.map(\.bundleID),
                       "chunking loses nobody and reorders nothing")
    }

    func testTheChunksAreNumberedAndTheLastOneSaysSo() {
        let chunks = AppCatalogPayload.chunked((0..<10).map { app("app.\($0)", iconBytes: 60_000) },
                                               purpose: .suggestions)
        XCTAssertEqual(chunks.map(\.sequence), Array(0..<chunks.count))
        XCTAssertEqual(chunks.filter(\.isFinal).count, 1)
        XCTAssertTrue(chunks.last!.isFinal)
    }

    func testAnEmptyCatalogueStillArrives() {
        // The phone shows a spinner until the final chunk lands, so "no apps"
        // has to be a message rather than a silence.
        let chunks = AppCatalogPayload.chunked([], purpose: .suggestions)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].apps.isEmpty)
        XCTAssertTrue(chunks[0].isFinal)
    }

    func testAnAppWhoseIconAloneIsTooBigKeepsItsPlaceAndLosesItsPicture() {
        let chunks = AppCatalogPayload.chunked([app("huge", iconBytes: 400_000),
                                                app("small", iconBytes: 900)],
                                               purpose: .icons,
                                               budget: 64 << 10)
        let all = chunks.flatMap(\.apps)
        XCTAssertEqual(all.map(\.bundleID), ["huge", "small"])
        XCTAssertNil(all[0].icon, "it is tappable without its picture; it is nothing without its row")
        XCTAssertNotNil(all[1].icon)
    }

    // MARK: - What the wire carries

    func testAnAppSurvivesTheWireWithItsIcon() throws {
        let sent = MacApp(bundleID: "com.apple.Terminal", name: "Terminal",
                          icon: Data([0x89, 0x50, 0x4E, 0x47]), symbol: "terminal",
                          isRunning: true, isAdded: false, useCount: 42,
                          lastUsedEpochMillis: 1_750_000_000_000)
        let line = try NimletCoder.line(HostMessage.apps(
            AppCatalogPayload(purpose: .suggestions, apps: [sent], sequence: 0, isFinal: true)))
        guard case .apps(let payload) = try NimletCoder.decode(HostMessage.self,
                                                             from: line.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(payload.apps, [sent])
        XCTAssertEqual(payload.purpose, .suggestions)
    }

    func testAPurposeThisBuildHasNeverHeardOfDoesNotCostTheWholeLine() throws {
        // A newer Mac sending a purpose this phone does not know must lose that
        // distinction, not the message: a throw here takes the apps with it.
        let json = Data(#"{"purpose":"something-new","apps":[],"sequence":0,"isFinal":true}"#.utf8)
        let payload = try NimletCoder.decode(AppCatalogPayload.self, from: json)
        XCTAssertEqual(payload.purpose, .suggestions)
    }

    func testAnAppFromAnOlderOrPartialMessageDecodesToSomethingDrawable() throws {
        let json = Data(#"{"bundleID":"com.example.app","name":"Example"}"#.utf8)
        let app = try NimletCoder.decode(MacApp.self, from: json)
        XCTAssertEqual(app.symbol, "app", "a tile with no glyph is a tile with a hole in it")
        XCTAssertFalse(app.isAdded)
        XCTAssertEqual(app.useCount, 0)
        XCTAssertNil(app.lastUsedEpochMillis)
    }

    func testTheTargetAnAppBecomesCarriesWhatTheMacNeedsToDeliverToIt() {
        let target = MacApp(bundleID: "com.apple.Terminal", name: "Terminal",
                            symbol: "terminal").asTarget()
        XCTAssertEqual(target.kind, .app)
        XCTAssertEqual(target.bundleID, "com.apple.Terminal")
        XCTAssertEqual(target.name, "Terminal")
        XCTAssertEqual(target.symbol, "terminal")
    }

    func testABatchOfTargetsSurvivesTheWire() throws {
        let batch = [NimletTarget(name: "Claude", kind: .app, bundleID: "com.anthropic.claudefordesktop"),
                     NimletTarget(name: "zsh", kind: .tmux, tmuxTarget: "%4",
                                submitOnSend: false, allowAutoSubmit: false)]
        let line = try NimletCoder.line(ClientMessage.addTargets(batch))
        guard case .addTargets(let round) = try NimletCoder.decode(ClientMessage.self,
                                                                 from: line.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(round, batch)
        XCTAssertFalse(round[1].allowAutoSubmit,
                       "the one field that must never be lost, in a batch as much as alone")
    }

    func testAskingForAppsAndForIconsAreTwoDifferentQuestions() throws {
        let apps = try NimletCoder.line(ClientMessage.requestApps(refresh: true))
        guard case .requestApps(let refresh) = try NimletCoder.decode(ClientMessage.self,
                                                                     from: apps.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertTrue(refresh)

        let icons = try NimletCoder.line(ClientMessage.requestAppIcons(bundleIDs: ["a", "b"]))
        guard case .requestAppIcons(let ids) = try NimletCoder.decode(ClientMessage.self,
                                                                     from: icons.dropLast()) else {
            return XCTFail("decoded as something else")
        }
        XCTAssertEqual(ids, ["a", "b"])
    }
}
