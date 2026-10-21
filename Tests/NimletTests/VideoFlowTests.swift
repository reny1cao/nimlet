import XCTest

final class VideoFlowTests: XCTestCase {

    private func ns(_ seconds: Double) -> UInt64 { UInt64(seconds * 1_000_000_000) }

    func testOneAcknowledgementClearsEverythingUpToIt() {
        var flow = VideoFlowWindow()
        flow.sent(sequence: 1, bytes: 1000, at: ns(1))
        flow.sent(sequence: 2, bytes: 2000, at: ns(1.01))
        flow.sent(sequence: 4, bytes: 3000, at: ns(1.02))
        XCTAssertEqual(flow.unackedBytes, 6000)
        let sample = flow.acknowledged(through: 2, at: ns(1.11), bitrate: 8_000_000)
        XCTAssertEqual(flow.unackedFrames, 1)
        XCTAssertEqual(flow.unackedBytes, 3000)
        XCTAssertEqual(sample?.roundTrip ?? 0, 0.10, accuracy: 0.0001)
        // An acknowledgement for something already cleared says nothing new.
        XCTAssertNil(flow.acknowledged(through: 2, at: ns(1.2), bitrate: 8_000_000))
    }

    func testAnEmptyWindowAlwaysTakesAFrameAndAFullOneDoesNot() {
        var flow = VideoFlowWindow()
        XCTAssertTrue(flow.hasRoom(bitrate: 1_000_000, now: ns(1)))
        // A keyframe far larger than the budget still goes out on its own...
        flow.sent(sequence: 1, bytes: 200_000, at: ns(1))
        // ...and nothing goes behind it until the phone has it.
        XCTAssertFalse(flow.hasRoom(bitrate: 1_000_000, now: ns(1.001)))
        flow.acknowledged(through: 1, at: ns(1.5), bitrate: 1_000_000)
        XCTAssertTrue(flow.hasRoom(bitrate: 1_000_000, now: ns(1.5)))
    }

    func testQueueingDelayIsMeasuredAgainstTheQuickestRecentRoundTrip() {
        var flow = VideoFlowWindow()
        // Small frames, so their airtime is negligible.
        flow.sent(sequence: 1, bytes: 500, at: ns(0))
        XCTAssertEqual(flow.acknowledged(through: 1, at: ns(0.3), bitrate: 2_000_000)?.queueDelay ?? -1, 0, accuracy: 0.005)
        flow.sent(sequence: 2, bytes: 500, at: ns(1))
        let queued = flow.acknowledged(through: 2, at: ns(1.5), bitrate: 2_000_000)
        XCTAssertEqual(queued?.queueDelay ?? 0, 0.2, accuracy: 0.005)
        XCTAssertEqual(flow.baseRoundTrip ?? 0, 0.3, accuracy: 0.005)
    }

    /// Measured through the relay: a keyframe that takes longer to cross than
    /// the round trip must not become the base, or every frame after it reads
    /// as queued.
    func testAKeyframeLongerThanTheRoundTripDoesNotBecomeTheBase() {
        var flow = VideoFlowWindow()
        flow.sent(sequence: 1, bytes: 100_000, at: ns(0))
        flow.acknowledged(through: 1, at: ns(1.0), bitrate: 300_000)
        XCTAssertNil(flow.baseRoundTrip, "2.7 s of airtime says nothing about the path")
        flow.sent(sequence: 2, bytes: 1_000, at: ns(2))
        let small = flow.acknowledged(through: 2, at: ns(2.35), bitrate: 300_000)
        XCTAssertEqual(flow.baseRoundTrip ?? 0, 0.323, accuracy: 0.01)
        XCTAssertEqual(small?.queueDelay ?? -1, 0, accuracy: 0.001)
        flow.sent(sequence: 3, bytes: 100_000, at: ns(3))
        flow.acknowledged(through: 3, at: ns(4.0), bitrate: 300_000)
        XCTAssertEqual(flow.baseRoundTrip ?? 0, 0.323, accuracy: 0.01, "and a later one leaves it alone")
    }

    func testAFarViewerStartsLowUntilTheLinkIsMeasured() {
        var pacer = VideoPacer(ceiling: 2_500_000, minimum: VideoPacer.farFloor)
        pacer.startConservatively(at: VideoPacer.farStart)
        XCTAssertEqual(pacer.bitrate, VideoPacer.farStart)
    }

    func testABaseFromAnotherRouteExpires() {
        var flow = VideoFlowWindow()
        flow.sent(sequence: 1, bytes: 500, at: ns(0))
        flow.acknowledged(through: 1, at: ns(0.01), bitrate: 2_000_000)
        // Now on a slower route: a quick LAN base must not make this look
        // like 290 ms of queue for ever.
        flow.sent(sequence: 2, bytes: 500, at: ns(11))
        let later = flow.acknowledged(through: 2, at: ns(11.3), bitrate: 2_000_000)
        XCTAssertEqual(later?.queueDelay ?? -1, 0, accuracy: 0.005)
        XCTAssertEqual(flow.baseRoundTrip ?? 0, 0.3, accuracy: 0.005)
    }

    func testAFrameStuckInAQueueClosesTheWindowWhateverTheByteCount() {
        var flow = VideoFlowWindow()
        flow.sent(sequence: 1, bytes: 500, at: ns(0))
        flow.acknowledged(through: 1, at: ns(0.1), bitrate: 4_000_000)
        flow.sent(sequence: 2, bytes: 500, at: ns(1))
        XCTAssertTrue(flow.hasRoom(bitrate: 4_000_000, now: ns(1.2)))
        XCTAssertFalse(flow.hasRoom(bitrate: 4_000_000, now: ns(1.5)))
    }

    func testThePacerCutsOnQueueingAndHoldsItsProbeWhileAQueueForms() {
        var pacer = VideoPacer(ceiling: 2_500_000)
        XCTAssertFalse(pacer.noteQueueDelay(0.01, deliveryRate: nil))
        XCTAssertEqual(pacer.bitrate, 2_500_000)
        XCTAssertTrue(pacer.noteQueueDelay(0.2, deliveryRate: 200_000))
        // Lands at what the phone was actually receiving, with margin.
        XCTAssertLessThanOrEqual(pacer.bitrate, Int(200_000 * 8 * 0.82) + 1)
        // One cut per episode: the next sample inside the cooldown is ignored.
        let once = pacer.bitrate
        pacer.noteQueueDelay(0.3, deliveryRate: 50_000)
        XCTAssertEqual(pacer.bitrate, once)
    }

    /// Away from the Mac the floor is lower, so a path that carries less than
    /// 700 kbps can be matched rather than queued behind.
    func testAFarViewerCanBeCutBelowTheLANFloor() {
        var pacer = VideoPacer(ceiling: 2_500_000)
        pacer.setCeiling(2_500_000, minimum: VideoPacer.farFloor)
        XCTAssertTrue(pacer.noteQueueDelay(0.2, deliveryRate: 40_000))
        XCTAssertEqual(pacer.bitrate, VideoPacer.farFloor, "cut to what the phone received, as far as the far floor")
        pacer.setCeiling(12_000_000, minimum: VideoPacer.floor)
        XCTAssertGreaterThanOrEqual(pacer.bitrate, VideoPacer.floor, "back on the LAN the usual floor holds")
    }

    /// One late acknowledgement on a cellular path is the path, not a queue;
    /// a queue the sender built is in every acknowledgement until it drains.
    func testALoneLateAcknowledgementIsJitterAndAStandingOneIsAQueue() {
        var flow = VideoFlowWindow()
        var t = 1.0
        var sequence = 0
        func exchange(roundTrip: Double) -> VideoFlowWindow.Sample? {
            sequence += 1
            flow.sent(sequence: sequence, bytes: 500, at: ns(t))
            let sample = flow.acknowledged(through: sequence, at: ns(t + roundTrip), bitrate: 2_000_000)
            t += roundTrip + 1.0 / 60
            return sample
        }
        for _ in 0..<10 { _ = exchange(roundTrip: 0.06) }
        let spike = exchange(roundTrip: 0.2)
        XCTAssertEqual(spike?.queueDelay ?? 0, 0.14, accuracy: 0.01, "the sample itself is late")
        XCTAssertLessThan(spike?.standingDelay ?? 1, VideoPacer.queueHoldSeconds, "but nothing is standing")
        var standing: VideoFlowWindow.Sample?
        for _ in 0..<4 { standing = exchange(roundTrip: 0.2) }
        XCTAssertGreaterThan(standing?.standingDelay ?? 0, VideoPacer.queueCutSeconds,
                             "a queue that lasts is in every acknowledgement")
    }

    /// The minimum must not reach back past a quiet spell: a queue that formed
    /// since the last few frames of a still window is a queue now.
    func testOldQuickSamplesDoNotHideANewQueue() {
        var flow = VideoFlowWindow()
        flow.sent(sequence: 1, bytes: 500, at: ns(1))
        flow.acknowledged(through: 1, at: ns(1.06), bitrate: 2_000_000)
        flow.sent(sequence: 2, bytes: 500, at: ns(1.1))
        flow.acknowledged(through: 2, at: ns(1.16), bitrate: 2_000_000)
        flow.sent(sequence: 3, bytes: 500, at: ns(5))
        let late = flow.acknowledged(through: 3, at: ns(5.3), bitrate: 2_000_000)
        XCTAssertEqual(late?.standingDelay ?? 0, 0.24, accuracy: 0.01)
    }

    // MARK: - A link, simulated

    /// What one run of the simulated mirror produced.
    private struct Run {
        var latencies: [Double] = []
        var deliveredBytes = 0
        var seconds = 0.0
        /// What the encoder was being asked for when the run ended.
        var encoderRate = 0
        var roundTrips: [Double] = []
        func percentile(_ p: Double) -> Double {
            let sorted = latencies.sorted()
            guard !sorted.isEmpty else { return .infinity }
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        var framesPerSecond: Double { Double(latencies.count) / seconds }
        var megabits: Double { Double(deliveredBytes) * 8 / seconds / 1_000_000 }
    }

    /// The mirror's sender — `PanelStreamer`'s admission rule and `VideoPacer` —
    /// against a bottleneck of `capacity` bytes per second with `oneWay`
    /// seconds of propagation each way, behind `buffer` bytes of socket and
    /// relay buffering that accept a frame long before the phone has it.
    ///
    /// `acknowledged` switches between the old rule (local acceptance only) and
    /// the new one (local acceptance and the phone's acknowledgements).
    ///
    /// `jitter` is the mean of an exponential delay added to each crossing,
    /// either way, without reordering: the path is a TCP stream or a KCP one.
    /// Mostly a few milliseconds, now and then a lot, which is what cellular
    /// looks like. The encoder
    /// is sized by what it was last *told*, which is only what the pacer said
    /// was worth a retune — the same as `PanelStreamer`.
    private func simulate(capacity: Double, oneWay: Double, buffer: Int, ceiling: Int,
                          acknowledged: Bool, minimum: Int = VideoPacer.floor, duration: Double = 20,
                          jitter: Double = 0, start: Int? = nil) -> Run {
        struct Frame { let sequence: Int; let bytes: Int; let captured: Double; var handed: Double }
        var pacer = VideoPacer(ceiling: ceiling, minimum: minimum)
        if let start { pacer.startConservatively(at: start); pacer.noteTold() }
        var encoderRate = pacer.bitrate
        var random = SplitMix(seed: 7)
        var lastArrival = 0.0
        var lastAck = 0.0
        var flow = VideoFlowWindow()
        var waiting: [Frame] = []          // handed over, not yet accepted by the socket
        var pipe: [(frame: Frame, left: Double)] = []  // accepted, queued at the bottleneck
        var pipeBytes = 0
        var arrivals: [(at: Double, frame: Frame)] = []
        var acks: [(at: Double, sequence: Int)] = []
        var run = Run()
        var sequence = 0
        var lastHanded = 0.0
        var nextCapture = 0.0
        let dt = 0.001
        var t = 0.0
        let warmup = 2.0
        while t < duration {
            // The bottleneck drains the head of the queue.
            var budget = capacity * dt
            while budget > 0, !pipe.isEmpty {
                let take = min(budget, pipe[0].left)
                pipe[0].left -= take
                budget -= take
                if pipe[0].left <= 0.0001 {
                    let done = pipe.removeFirst()
                    pipeBytes -= done.frame.bytes
                    lastArrival = max(lastArrival, t + oneWay + random.exponential(mean: jitter))
                    arrivals.append((lastArrival, done.frame))
                }
            }
            // The socket takes what fits.
            while let head = waiting.first, pipeBytes + head.bytes <= buffer || pipeBytes == 0 {
                waiting.removeFirst()
                pipe.append((head, Double(head.bytes)))
                pipeBytes += head.bytes
                let interval = head.handed - lastHanded
                lastHanded = head.handed
                if pacer.noteDelivered(bytes: head.bytes, seconds: t - head.handed, interval: interval) {
                    encoderRate = pacer.bitrate
                }
            }
            // The phone reads, and acknowledges.
            while let first = arrivals.first, first.at <= t {
                arrivals.removeFirst()
                if first.frame.captured >= warmup {
                    run.latencies.append(t - first.frame.captured)
                    run.deliveredBytes += first.frame.bytes
                }
                lastAck = max(lastAck, t + oneWay + random.exponential(mean: jitter))
                acks.append((lastAck, first.frame.sequence))
            }
            while let ack = acks.first, ack.at <= t {
                acks.removeFirst()
                guard acknowledged,
                      let sample = flow.acknowledged(through: ack.sequence, at: ns(t), bitrate: pacer.bitrate) else { continue }
                if t >= warmup { run.roundTrips.append(sample.roundTrip) }
                if pacer.noteQueueDelay(sample.standingDelay, deliveryRate: sample.deliveryRate) {
                    encoderRate = pacer.bitrate
                }
            }
            // A capture every 60th of a second, encoded only if there is room.
            if t >= nextCapture {
                nextCapture += 1.0 / 60
                let localBytes = waiting.reduce(0) { $0 + $1.bytes }
                let localRoom = waiting.isEmpty
                    || (waiting.count < VideoPacer.maxFramesInFlight && localBytes < pacer.inFlightByteBudget)
                let endToEndRoom = !acknowledged || flow.hasRoom(bitrate: pacer.bitrate, now: ns(t))
                if localRoom, endToEndRoom {
                    sequence += 1
                    // A keyframe every two seconds of captures, ten frames' worth:
                    // the frame that once took longer to cross than the round trip.
                    let keyframe = sequence % 120 == 1
                    let bytes = max(1_500, Int(Double(encoderRate) / 8 / max(pacer.framesPerSecond, 1))) * (keyframe ? 10 : 1)
                    let frame = Frame(sequence: sequence, bytes: bytes, captured: t, handed: t)
                    waiting.append(frame)
                    if acknowledged { flow.sent(sequence: sequence, bytes: bytes, at: ns(t)) }
                }
            }
            t += dt
        }
        run.seconds = duration - warmup
        run.encoderRate = encoderRate
        return run
    }

    private func describe(_ name: String, _ run: Run) -> String {
        let trips = run.roundTrips.sorted()
        let trip = { (p: Double) in trips.isEmpty ? 0 : trips[min(trips.count - 1, Int(Double(trips.count) * p))] * 1000 }
        return String(format: "%@: latency p50 %.0f ms, p95 %.0f ms, %.1f fps, %.2f Mbps, encoder at %.2f Mbps, ack rtt p50 %.0f / p95 %.0f ms",
                      name, run.percentile(0.5) * 1000, run.percentile(0.95) * 1000, run.framesPerSecond, run.megabits,
                      Double(run.encoderRate) / 1e6, trip(0.5), trip(0.95))
    }

    /// The relay on cellular, as measured on 2026-10-05: about 300 ms of round
    /// trip, a path that carries less than the 2.5 Mbps the far ceiling asks
    /// for, and a megabyte of buffering between the Mac's socket and the
    /// phone. Before: the pacer saw a socket with room and filled that
    /// megabyte. After: the phone's acknowledgements bound it.
    func testThroughADeepBufferAcknowledgementsKeepThePictureCurrent() {
        let before = simulate(capacity: 150_000, oneWay: 0.15, buffer: 1_000_000, ceiling: 2_500_000, acknowledged: false)
        let after = simulate(capacity: 150_000, oneWay: 0.15, buffer: 1_000_000, ceiling: 2_500_000, acknowledged: true)
        print(describe("relay 1.2 Mbps / 300 ms, local acceptance", before))
        print(describe("relay 1.2 Mbps / 300 ms, acknowledged", after))
        XCTAssertGreaterThan(before.percentile(0.95), 1.5, "the old rule lets seconds of picture queue")
        XCTAssertLessThan(after.percentile(0.95), 0.6)
        XCTAssertLessThan(after.percentile(0.5), 0.45)
        XCTAssertGreaterThan(after.megabits, 0.6, "and keeps most of the link busy")
    }

    /// The same, slower and further: what a lossy cross-border hop leaves.
    /// This link carries less than `VideoPacer.floor`, so the bitrate cannot
    /// get under it and the window alone is what bounds the delay.
    func testOnASlowerLongerPathTheQueueStaysBounded() {
        let before = simulate(capacity: 70_000, oneWay: 0.25, buffer: 1_000_000, ceiling: 2_500_000, acknowledged: false)
        let after = simulate(capacity: 70_000, oneWay: 0.25, buffer: 1_000_000, ceiling: 2_500_000, acknowledged: true)
        print(describe("relay 0.56 Mbps / 500 ms, local acceptance", before))
        print(describe("relay 0.56 Mbps / 500 ms, acknowledged", after))
        XCTAssertGreaterThan(before.percentile(0.95), 3)
        XCTAssertLessThan(after.percentile(0.95), 1.2)
        // With the far floor the bitrate itself can get under the link.
        let far = simulate(capacity: 70_000, oneWay: 0.25, buffer: 1_000_000, ceiling: 2_500_000,
                           acknowledged: true, minimum: VideoPacer.farFloor)
        print(describe("relay 0.56 Mbps / 500 ms, acknowledged, far floor", far))
        XCTAssertLessThan(far.percentile(0.95), after.percentile(0.95))
        XCTAssertLessThan(far.percentile(0.5), 0.45)
    }

    /// And at the desk nothing is lost: a fast LAN still runs at full rate.
    func testOnALANAcknowledgementsCostNothing() {
        let before = simulate(capacity: 6_000_000, oneWay: 0.002, buffer: 256_000, ceiling: 12_000_000, acknowledged: false)
        let after = simulate(capacity: 6_000_000, oneWay: 0.002, buffer: 256_000, ceiling: 12_000_000, acknowledged: true)
        print(describe("LAN 48 Mbps / 4 ms, local acceptance", before))
        print(describe("LAN 48 Mbps / 4 ms, acknowledged", after))
        XCTAssertGreaterThan(after.framesPerSecond, 55)
        XCTAssertGreaterThan(after.megabits, 10)
        XCTAssertLessThan(after.percentile(0.95), 0.03)
    }

    /// 5G on the direct path, as the Mac saw it on 2026-10-15: a link with
    /// room for several megabits, a quick round trip, and acknowledgements
    /// that wander by tens of milliseconds — 15 ms mean each way puts the
    /// round trip's median and p95 about where 2026-10-05 measured them,
    /// 77 and 140 ms over a 60 ms floor. Judged one sample at a time that
    /// jitter read as a queue, and the mirror spent the session at the 300 kbps
    /// floor, sharp enough to see that something was there and no more.
    func testOnAJitteryCellularPathTheRateIsNotPinnedToTheFloor() {
        let run = simulate(capacity: 500_000, oneWay: 0.03, buffer: 256_000, ceiling: 2_500_000,
                           acknowledged: true, minimum: VideoPacer.farFloor, duration: 30,
                           jitter: 0.015, start: VideoPacer.farStart)
        print(describe("5G 4 Mbps / 60 ms, 15 ms mean jitter each way", run))
        XCTAssertGreaterThan(run.megabits, 1.5, "the link carries 4 Mbps; the far ceiling is 2.5")
        XCTAssertLessThan(run.percentile(0.95), 0.3, "and the picture stays current")
    }

    /// And the same path without room: a real queue is still a queue, jitter
    /// or not, and the picture is still kept within a fraction of a second.
    func testOnAJitteryPathThatIsFullTheQueueIsStillCut() {
        let run = simulate(capacity: 100_000, oneWay: 0.03, buffer: 1_000_000, ceiling: 2_500_000,
                           acknowledged: true, minimum: VideoPacer.farFloor, duration: 30,
                           jitter: 0.015, start: VideoPacer.farStart)
        print(describe("5G 0.8 Mbps / 60 ms, 15 ms mean jitter each way", run))
        XCTAssertLessThan(run.percentile(0.5), 0.35)
        XCTAssertLessThan(run.percentile(0.95), 0.8)
        XCTAssertGreaterThan(run.megabits, 0.4, "and most of the link is used")
    }
}

/// Deterministic, so a simulated run is the same run every time.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    /// Uniform in [0, 1).
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    mutating func exponential(mean: Double) -> Double {
        mean > 0 ? -mean * log(1 - next()) : 0
    }
}
