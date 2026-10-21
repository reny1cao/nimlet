import Foundation
import CoreGraphics

/// Resize once per selected window and settled phone layout. An app may
/// enforce a minimum or fixed size; the capture watchdog must not fight it.
struct WindowAutoFit {
    private struct Attempt: Equatable {
        var windowID: UInt32
        var aspect: Double
    }
    private var lastAttempt: Attempt?

    static func validAspect(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        let rounded = (value * 1000).rounded() / 1000
        guard rounded > 0.1, rounded < 10 else { return nil }
        return rounded
    }

    mutating func shouldFit(windowID: UInt32, size: CGSize, aspect: Double?) -> Bool {
        guard let aspect = Self.validAspect(aspect) else {
            lastAttempt = nil
            return false
        }
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return false }
        let attempt = Attempt(windowID: windowID, aspect: aspect)
        guard attempt != lastAttempt else { return false }
        lastAttempt = attempt
        return abs(Double(size.width / size.height) - aspect) / aspect > 0.015
    }

    mutating func reset() { lastAttempt = nil }
}
