import CoreGraphics

/// Chrome metrics shared by the hand-built surfaces that have to track the
/// window's own geometry. Liquid Glass rounds windows more than earlier
/// releases, so these live in one place: a future system change is a one-line
/// fix instead of a hunt through the view files.
enum WindowChrome {
    /// Matches the window's corner radius. Used by the prompt input so the
    /// input and the window read as one surface, and by EVERY rounded glass
    /// panel (composer, sidebar, banners, queued-steering bar) so their
    /// silhouettes match too. Capsule chrome stays a capsule; it tracks half
    /// the view's height instead of this.
    static let cornerRadius: CGFloat = 10

    /// The smaller radius used by pill-shaped navigation chrome (the outer
    /// session tabs). Kept distinct from `cornerRadius` because a pill is not
    /// the window edge, but centralized so the two never drift independently.
    static let pillCornerRadius: CGFloat = 7
}
