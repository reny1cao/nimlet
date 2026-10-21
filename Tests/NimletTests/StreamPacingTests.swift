import XCTest

/// The mirror's rate control, and the correction that keeps the picture with the
/// sound.
///
/// Both are worth tests for the same reason the audio cushion is: every way they
/// can be wrong looks like a network problem from the outside. A controller that
/// backs off and never recovers is "the mirror is blurry now"; one that does not
/// back off at all is "it freezes every couple of seconds"; a hold that grows
/// without bound is "the trackpad has gone laggy". None of those point at the
/// arithmetic that caused them, and none can be checked by looking at a mirror.
final class StreamPacingTests: XCTestCase {

    /// A frame the transport took a while to accept, sized so it is also a
    /// throughput sample.
    private let slowFrame = (bytes: 120_000, seconds: 0.12)
    /// And one it took in a memcpy, which says nothing about the link's ceiling.
    private let fastFrame = (bytes: 20_000, seconds: 0.001)

    // MARK: - Where the rate starts

    func testItStartsAtTheCeilingAndNeverAsksForMore() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        XCTAssertEqual(pacer.bitrate, 12_000_000)
        for _ in 0..<500 {
            pacer.noteDelivered(bytes: fastFrame.bytes, seconds: fastFrame.seconds, interval: 1.0 / 60)
        }
        XCTAssertEqual(pacer.bitrate, 12_000_000,
                       "a link that never makes us wait has nothing to probe towards")
    }

    func testAnUnmeasuredLinkReportsNoGoodput() {
        var pacer = VideoPacer(ceiling: 8_000_000)
        pacer.noteDelivered(bytes: fastFrame.bytes, seconds: fastFrame.seconds, interval: 1.0 / 60)
        XCTAssertNil(pacer.goodput,
                     "dividing by a millisecond of fixed cost would claim a gigabit")
    }

    // MARK: - Backing off

    func testAStalledFrameCutsTheRateAndIsMeasured() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        pacer.noteDelivered(bytes: slowFrame.bytes, seconds: slowFrame.seconds, interval: 1.0 / 30)

        XCTAssertLessThan(pacer.bitrate, 12_000_000)
        guard let goodput = pacer.goodput else { return XCTFail("a metered transfer is a measurement") }
        XCTAssertEqual(goodput, Double(slowFrame.bytes) / slowFrame.seconds, accuracy: 1)
    }

    /// The direction that matters. A link carrying 1 Mbps handed 12 does not
    /// fail, it queues — and a queue is a mirror running behind that never
    /// catches up, which is the fault this whole controller exists to prevent.
    func testItConvergesOnWhatTheLinkActuallyCarries() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        // 125 KB/s, which is 1 Mbps.
        for _ in 0..<40 {
            pacer.noteDelivered(bytes: 25_000, seconds: 0.2, interval: 1.0 / 8)
        }
        XCTAssertLessThanOrEqual(pacer.bitrate, 1_000_000)
        XCTAssertGreaterThanOrEqual(pacer.bitrate, VideoPacer.floor)
    }

    /// Simulated against a 6 Mbps link and the real encoder, a controller without
    /// this took the rate from 12 Mbps to the floor inside a second and then used
    /// 22% of the link for the rest of the run. Every frame sent into a full link
    /// comes back slow, so cutting on each one cuts eight or nine times before
    /// the first cut has reached the encoder.
    func testOneEpisodeOfCongestionIsOneStepDownRatherThanOnePerFrame() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        let start = pacer.bitrate
        // Thirty stalled frames inside a tenth of a second: one episode.
        for _ in 0..<30 {
            pacer.noteDelivered(bytes: 120_000, seconds: 0.12, interval: 0.003)
        }
        XCTAssertGreaterThan(pacer.bitrate, start / 4,
                             "a burst of slow frames is one piece of news, not thirty")
    }

    func testAnotherEpisodeLaterDoesCutAgain() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        for _ in 0..<5 { pacer.noteDelivered(bytes: 120_000, seconds: 0.12, interval: 0.01) }
        let afterFirst = pacer.bitrate
        // Half a second of delivery later, the cut has had time to take effect
        // and a link that is still struggling is new information.
        for _ in 0..<5 { pacer.noteDelivered(bytes: 120_000, seconds: 0.12, interval: 0.1) }
        XCTAssertLessThan(pacer.bitrate, afterFirst)
    }

    func testItNeverAsksForLessThanAPictureIsWorth() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        for _ in 0..<200 {
            pacer.noteDropped()
            // A drop carries no interval of its own, so deliveries are what let
            // the cooldown expire — which is the only way the rate walks down.
            pacer.noteDelivered(bytes: 1_000, seconds: 0.001, interval: 0.4)
        }
        XCTAssertEqual(pacer.bitrate, VideoPacer.floor,
                       "below this the problem is not one bitrate control can solve")
    }

    func testADroppedFrameIsTreatedAsCongestion() {
        var pacer = VideoPacer(ceiling: 4_000_000)
        let before = pacer.bitrate
        pacer.noteDropped()
        XCTAssertLessThan(pacer.bitrate, before)
    }

    // MARK: - Coming back

    /// Asymmetric on purpose, and this is the test that says so: down in one
    /// step, up only after a run of frames that went out cleanly.
    func testItProbesBackUpOnceNothingIsGoingWrong() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        pacer.noteDropped()
        let cut = pacer.bitrate
        XCTAssertLessThan(cut, 12_000_000)

        for _ in 0..<600 {
            pacer.noteDelivered(bytes: fastFrame.bytes, seconds: fastFrame.seconds, interval: 1.0 / 60)
        }
        XCTAssertGreaterThan(pacer.bitrate, cut)
        XCTAssertLessThanOrEqual(pacer.bitrate, 12_000_000)
    }

    /// In seconds rather than frames, because a link bad enough to be worth
    /// recovering from is also a link running at ten frames a second — a frame
    /// count slowed the recovery down exactly when it mattered most.
    func testRecoveryIsPacedInSecondsAndNotInFrames() {
        var slow = VideoPacer(ceiling: 12_000_000)
        var fast = VideoPacer(ceiling: 12_000_000)
        slow.noteDropped()
        fast.noteDropped()
        // Two seconds of delivery each: eight frames a second, and sixty-four.
        // Both intervals divide the second exactly, so the comparison is about
        // the pacing rule rather than about where floating point rounds.
        for _ in 0..<16 { slow.noteDelivered(bytes: 1_000, seconds: 0.001, interval: 0.125) }
        for _ in 0..<128 { fast.noteDelivered(bytes: 1_000, seconds: 0.001, interval: 1.0 / 64) }
        XCTAssertEqual(slow.bitrate, fast.bitrate)
    }

    /// The encoder only hears about a rate when this says it is worth a retune,
    /// and each probe is a 10% step against a one-eighth threshold. Judged step
    /// by step, no recovery was ever worth telling it about: measured on
    /// 2026-10-15, a phone sat at the far floor for four minutes while the
    /// pacer's own number had long since climbed back.
    func testARecoveryReachesTheEncoderAndNotJustThePacer() {
        var pacer = VideoPacer(ceiling: 2_500_000, minimum: VideoPacer.farFloor)
        XCTAssertTrue(pacer.noteQueueDelay(0.2, deliveryRate: 30_000))
        XCTAssertEqual(pacer.bitrate, VideoPacer.farFloor)
        var encoder = pacer.bitrate
        var retunes = 0
        for _ in 0..<(60 * 30) {
            if pacer.noteDelivered(bytes: fastFrame.bytes, seconds: fastFrame.seconds, interval: 1.0 / 60) {
                encoder = pacer.bitrate
                retunes += 1
            }
        }
        XCTAssertEqual(pacer.bitrate, 2_500_000)
        XCTAssertGreaterThan(encoder, 2_000_000, "the encoder has to hear about the recovery")
        XCTAssertLessThan(retunes, 20, "in steps it notices, not one per probe")
    }

    func testOneCleanFrameIsNotEnoughToUndoABackOff() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        pacer.noteDropped()
        let cut = pacer.bitrate
        pacer.noteDelivered(bytes: fastFrame.bytes, seconds: fastFrame.seconds, interval: 1.0 / 60)
        XCTAssertEqual(pacer.bitrate, cut)
    }

    // MARK: - The ceiling

    /// Moving to AWDL is a tenth of the bandwidth, and the sender has to be told
    /// rather than discover it a frame at a time.
    func testALowerCeilingTakesEffectAtOnce() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        pacer.setCeiling(2_500_000)
        XCTAssertEqual(pacer.bitrate, 2_500_000)
    }

    func testARaisedCeilingIsProbedTowardsRatherThanJumpedTo() {
        var pacer = VideoPacer(ceiling: 2_500_000)
        pacer.setCeiling(12_000_000)
        XCTAssertEqual(pacer.bitrate, 2_500_000,
                       "more room available is an invitation to find out, not a licence")
    }

    func testResettingForgetsALinkThatIsNoLongerTheOne() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        for _ in 0..<40 { pacer.noteDelivered(bytes: 25_000, seconds: 0.2, interval: 1.0 / 8) }
        pacer.reset()
        XCTAssertLessThan(pacer.inFlightByteBudget, 200_000)
        XCTAssertEqual(pacer.bitrate, 12_000_000)
        XCTAssertNil(pacer.goodput)
    }

    // MARK: - What the encoder is told

    /// The encoder spreads a second's budget across `ExpectedFrameRate` frames,
    /// so telling it 60 while 20 arrive gives away two thirds of the bitrate.
    func testTheReportedFrameRateFollowsWhatIsActuallyGoingOut() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        for _ in 0..<200 {
            pacer.noteDelivered(bytes: fastFrame.bytes, seconds: fastFrame.seconds, interval: 1.0 / 20)
        }
        XCTAssertEqual(pacer.framesPerSecond, 20, accuracy: 1.5)
    }

    /// The direction that has to be believed immediately. Told 60 while 20 are
    /// going out, the encoder spends a second's budget across sixty frames and
    /// then sends twenty of them — measured at three times the rate it was
    /// asked for, on exactly the link that provoked the back-off.
    func testAFrameRateThatHasCollapsedIsBelievedFasterThanOneThatHasRecovered() {
        var falling = VideoPacer(ceiling: 12_000_000)
        var rising = VideoPacer(ceiling: 12_000_000)
        for _ in 0..<600 {
            rising.noteDelivered(bytes: fastFrame.bytes, seconds: fastFrame.seconds, interval: 1.0 / 10)
        }
        for _ in 0..<5 {
            falling.noteDelivered(bytes: fastFrame.bytes, seconds: fastFrame.seconds, interval: 1.0 / 10)
        }
        let fallen = 60 - falling.framesPerSecond
        for _ in 0..<5 {
            rising.noteDelivered(bytes: fastFrame.bytes, seconds: fastFrame.seconds, interval: 1.0 / 60)
        }
        let risen = rising.framesPerSecond - 10
        XCTAssertGreaterThan(fallen / 50, risen / 50,
                             "overshooting during congestion is the one thing that must not happen")
    }

    func testTheFrameRateIgnoresIntervalsThatAreNotIntervals() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        let before = pacer.framesPerSecond
        pacer.noteDelivered(bytes: fastFrame.bytes, seconds: fastFrame.seconds, interval: 0)
        pacer.noteDelivered(bytes: fastFrame.bytes, seconds: fastFrame.seconds, interval: 30)
        XCTAssertEqual(pacer.framesPerSecond, before, accuracy: 0.0001,
                       "the first frame of a stream has no interval, and a gap is not a rate")
    }

    // MARK: - What may be in flight

    func testTheBudgetIsAFractionOfASecondRatherThanAQueue() {
        let pacer = VideoPacer(ceiling: 12_000_000)
        // 12 Mbps is 1.5 MB/s; a twentieth of that is 75 KB — two delta frames
        // of a large window, and not a keyframe.
        XCTAssertEqual(pacer.inFlightByteBudget, 75_000, accuracy: 1_000)
    }

    /// Measured against a hardware HEVC encoder, a 1920x1200 window in motion
    /// does not produce frames smaller than about 10 KB whatever rate it is
    /// asked for — it lowers the frame rate instead. So a budget with a floor
    /// generous enough to hold one would allow two at the bottom of the range,
    /// which is a tenth of a second of link on the link that can least afford it.
    func testTheBudgetDoesNotQuietlyAllowTwoFramesOnASlowLink() {
        var pacer = VideoPacer(ceiling: 12_000_000)
        for _ in 0..<200 {
            pacer.noteDropped()
            pacer.noteDelivered(bytes: 1_000, seconds: 0.001, interval: 0.4)
        }
        XCTAssertEqual(pacer.bitrate, VideoPacer.floor)
        XCTAssertGreaterThan(pacer.inFlightByteBudget, 0)
        XCTAssertLessThan(pacer.inFlightByteBudget, 10_000)
    }

    func testMoreThanOneFrameMayBeInFlightSoTheEncoderIsNotIdleWhileOneDrains() {
        XCTAssertGreaterThanOrEqual(VideoPacer.maxFramesInFlight, 2)
    }

    // MARK: - Keeping the picture with the sound

    func testNothingIsHeldWhenNobodyIsListening() {
        XCTAssertEqual(VideoHold.seconds(audioDelay: nil, videoDelay: 0.02), 0)
        XCTAssertEqual(VideoHold.seconds(audioDelay: 0.3, videoDelay: nil), 0)
    }

    func testThePictureIsHeldForTheDifferenceBetweenTheTwoPaths() {
        XCTAssertEqual(VideoHold.seconds(audioDelay: 0.22, videoDelay: 0.04), 0.18, accuracy: 1e-9)
    }

    /// A frame that arrived late is held less, which is what makes this a
    /// correction rather than a delay added to everything.
    func testAFrameThatIsAlreadyLateIsNotHeldAtAll() {
        XCTAssertEqual(VideoHold.seconds(audioDelay: 0.12, videoDelay: 0.3), 0)
    }

    func testAGapTooSmallToSeeIsNotWorthHoldingFor() {
        XCTAssertEqual(VideoHold.seconds(audioDelay: 0.05, videoDelay: 0.04), 0,
                       "chasing the last few milliseconds of a moving measurement is judder")
    }

    /// The mirror is something you point at. Past a certain delay a lip-sync
    /// error is the better of the two faults.
    func testTheHoldIsBounded() {
        XCTAssertEqual(VideoHold.seconds(audioDelay: 5, videoDelay: 0.02),
                       VideoHold.maximum, accuracy: 1e-9)
    }
}
