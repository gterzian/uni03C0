import CoreGraphics

/// One tick on the Changes sidebar's edit-density rail: where an added or
/// removed line sits as a fraction of the diff document's height. Produced by
/// `ChangesStore` from the built document's own edit map, so the rail is the
/// same data the viewer's scrollbar already draws — never a second diff pass.
struct EditTick: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case added
        case removed
    }

    let fraction: CGFloat
    let kind: Kind
}
