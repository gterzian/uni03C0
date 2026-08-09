import Foundation

/// Shared expansion state for tool-call cards, keyed by card id. The card's
/// expand button toggles it (through the coordinator, so the row re-measures);
/// the height measurer reads it. Pure data with no AppKit dependency — lives
/// in Core so it is unit-testable.
///
/// `@unchecked Sendable`: accessed only from the main actor (the transcript
/// coordinator, the height measurer, and the card view are all MainActor);
/// the shared instance is a convenience for those main-actor call sites.
public final class ToolCardExpansion: @unchecked Sendable {
    public static let shared = ToolCardExpansion()
    private var expanded: Set<String> = []

    public init() {}

    public func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    public func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    public func reset() { expanded.removeAll() }
}
