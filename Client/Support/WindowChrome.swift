import CoreGraphics

/// Chrome metrics shared by the hand-built surfaces that have to track the
/// window's own geometry. Liquid Glass rounds windows more than earlier
/// releases, so these live in one place: a future system change is a one-line
/// fix instead of a hunt through the view files.
enum WindowChrome {
    /// Matches the window's corner radius. The prompt input uses it so the
    /// input and the window read as one surface instead of a square field
    /// poking into a rounded window.
    static let cornerRadius: CGFloat = 10

    /// The smaller radius used by pill-shaped navigation chrome (the outer
    /// session tabs). Kept distinct from `cornerRadius` because a pill is not
    /// the window edge, but centralized so the two never drift independently.
    static let pillCornerRadius: CGFloat = 7
}
