import Foundation

/// Phone layout survives reconnects and promotion of a running app to a favorite.
/// Hiding a tile never terminates the app or removes it from the app directory.
struct PhoneDockArrangement: Codable, Equatable {
    var order: [String] = []
    var hiddenApps: [AppReference] = []

    func isHidden(_ app: AppReference) -> Bool {
        hiddenApps.contains { $0.matches(app) }
    }

    mutating func hide(_ app: AppReference) {
        if !isHidden(app) { hiddenApps.append(app) }
    }

    mutating func show(_ app: AppReference) {
        hiddenApps.removeAll { $0.matches(app) }
    }

    static func key(for target: NimletTarget) -> String {
        target.appReference?.key ?? "target:\(target.id)"
    }

    func visibleTargets(in targets: [NimletTarget]) -> [NimletTarget] {
        let visible = targets.filter {
            // Terminal panes remain available in Targets, outside the app Dock.
            $0.kind != .tmux && !($0.appReference.map(isHidden) ?? false)
        }
        let positions = Dictionary(order.enumerated().map { ($0.element, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        return visible.enumerated().sorted {
            let lhs = positions[Self.key(for: $0.element)] ?? (order.count + $0.offset)
            let rhs = positions[Self.key(for: $1.element)] ?? (order.count + $1.offset)
            return lhs < rhs
        }.map(\.element)
    }
}
