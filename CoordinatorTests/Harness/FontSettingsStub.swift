import AppKit

/// Stub of `Client/Support/FontSettings.swift` WITHOUT the `@Observable` macro
/// (the macro's plugin server is blocked inside the app's Seatbelt sandbox, so
/// the real file cannot be compiled by the plain-swiftc harness). Only the
/// pieces the renderer/measurer read are provided — observation is not needed.
/// The Xcode `CoordinatorTests` target compiles the REAL `FontSettings.swift`
/// instead (the macro runs fine under xcodebuild).
@MainActor
final class FontSettings {
    static let shared = FontSettings()

    static let didChangeNotification = Notification.Name("FontSettings.didChange")

    static let presets: [(name: String, size: CGFloat)] = [
        ("Small", 11),
        ("Regular", 13),
        ("Large", 16),
        ("Extra Large", 19),
    ]

    static let defaultSize: CGFloat = 13

    var bodySize: CGFloat

    private init() {
        let saved = UserDefaults.standard.double(forKey: "transcriptFontSize")
        bodySize = saved > 0 ? saved : Self.defaultSize
    }
}
