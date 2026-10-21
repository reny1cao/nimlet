import Foundation

/// The two orders one app's windows are put in. They answer different
/// questions, so they are kept apart.
///
/// The shelf is a row of cards you come back to, so it is in the order the
/// windows were opened and nothing else. It used to lead with the window in
/// front and sort the rest by size: every switch moved the card just used to
/// the front and reshuffled the others, and with four windows all titled
/// "ChatGPT" their position was the only thing telling them apart. Opened
/// order is what a row of tabs, the Window menu and a taskbar's previews all
/// use. The card being shown is marked and scrolled to, never moved.
///
/// Following an app is the other question — which of its windows is in front —
/// and the window server's stacking order is what answers it. The mirror used
/// to ask ScreenCaptureKit, whose `isActive` is true for every window of the
/// active app, so the tie went to the biggest window: clicking another window
/// on the Mac left the mirror where it was.
enum WindowOrdering {

    /// The window server numbers windows as they are created, so ascending id
    /// is opened order. Windows that cannot be raised go after the rest:
    /// they are the oddities, and a card that cannot be chosen should not
    /// push one that can along the row.
    static func shelf(_ windows: [MacWindow]) -> [MacWindow] {
        windows.sorted { lhs, rhs in
            if lhs.canRaise != rhs.canRaise { return lhs.canRaise }
            return lhs.id < rhs.id
        }
    }

    struct Candidate: Equatable {
        var id: UInt32
        var isOnScreen: Bool
        var area: Double
    }

    /// The window an app has in front, given the window server's stacking
    /// order, front first.
    ///
    /// A window missing from that order — minimised, or on another Space — wins
    /// only when nothing is stacked. Then on screen, then size, then the lowest
    /// id, so that two windows of the same size cannot take turns being the
    /// answer: the mirror resolves every second and a half, and an answer that
    /// alternated would switch the picture every time it did.
    static func front(of candidates: [Candidate], stacking: [UInt32]) -> UInt32? {
        let rank = Dictionary(stacking.enumerated().map { ($1, $0) },
                              uniquingKeysWith: { first, _ in first })
        return candidates.min { lhs, rhs in
            let left = rank[lhs.id] ?? Int.max, right = rank[rhs.id] ?? Int.max
            if left != right { return left < right }
            if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
            if lhs.area != rhs.area { return lhs.area > rhs.area }
            return lhs.id < rhs.id
        }?.id
    }
}
