import SwiftUI

/// What a colour means here, written down once.
///
/// Orange had come to mean three unrelated things at the same time, on one
/// screen: a round trip over 60ms in the status line, the banner that says
/// Accessibility is not granted, and a window on the shelf that cannot be
/// picked. Nothing connects those, so learning any one of them taught you
/// nothing about the other two — and the loudest of the three was the one that
/// mattered least, because a window you cannot choose is not an emergency, it
/// is just not an option.
///
/// Two meanings, kept apart:
///
/// - **Attention** is about the link and the grants. Something is wrong between
///   this phone and that Mac, and it will keep being wrong until somebody does
///   something. It is allowed to be loud because it is rare and it is
///   actionable.
/// - **Unavailable** is about a control that exists and cannot be used right
///   now. It is quiet on purpose: the message is "not this one", and a warning
///   colour overstates it every time.
enum Palette {
    /// The link, the grants, a delivery that failed. Rare, actionable, loud.
    static let attention = Color.orange
    /// The halfway house on the way there — a round trip that is climbing but
    /// has not arrived anywhere bad yet.
    static let caution = Color.yellow

    /// A control that is present and cannot be used: a minimised window, a
    /// window Nimlet cannot raise. Drawn back rather than marked up.
    static let unavailable = Color.white.opacity(0.35)
    /// The ring and badge that go with it.
    static let unavailableMark = Color.white.opacity(0.22)
}
