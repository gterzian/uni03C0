import AppKit
import SwiftUI

/// App-wide appearance: light, dark, or match the system. Persisted to
/// UserDefaults and applied by setting `NSApplication.appearance`, so EVERY
/// window (main window, Settings, panels) and every dynamic system color
/// follows the choice through the same mechanism the renderer already uses for
/// a system appearance change: `NSColor.labelColor`/`textBackgroundColor`,
/// SwiftUI's semantic colors, `.bar` materials, and the prompt bar's
/// `viewDidChangeEffectiveAppearance` all adapt without special-casing.
///
/// The one place that resolves appearance ONCE and caches the result is syntax
/// highlighting — Highlightr bakes fixed RGB values out of a highlight.js
/// theme CSS file. `CodePaneContainer.viewDidChangeEffectiveAppearance` reacts
/// to the change and the diff viewer rebuilds the document with the matching
/// theme, so the code views follow both an explicit app toggle and a system
/// appearance change.
@MainActor
@Observable
final class AppearanceSettings {
    static let shared = AppearanceSettings()

    enum Mode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: "Match System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var symbolName: String {
            switch self {
            case .system: "circle.lefthalf.filled"
            case .light: "sun.max"
            case .dark: "moon"
            }
        }

        /// The AppKit appearance to apply app-wide. `nil` = follow the system.
        var appearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            apply()
        }
    }

    private static let key = "appAppearanceMode"

    private init() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .system
        apply()
    }

    /// Pushes the persisted mode onto the running app. Called once at startup
    /// (via `shared`) and on every change. `NSApplication.appearance` covers
    /// future windows (Settings, panels) and their chrome; setting it on the
    /// already-open windows makes the change land on them immediately rather
    /// than on their next display pass. `nil` = follow the system.
    private func apply() {
        let appearance = mode.appearance
        NSApplication.shared.appearance = appearance
        for window in NSApplication.shared.windows {
            window.appearance = appearance
        }
    }
}

/// View menu → Appearance: the same three choices as the toolbar button, with
/// the current one checked. Its own `View` so `@Observable` tracking re-renders
/// the checkmark when the mode changes.
struct AppearanceCommands: View {
    @State private var settings = AppearanceSettings.shared

    var body: some View {
        ForEach(AppearanceSettings.Mode.allCases) { mode in
            Button {
                settings.mode = mode
            } label: {
                if settings.mode == mode {
                    Label(mode.title, systemImage: "checkmark")
                } else {
                    Text(mode.title)
                }
            }
        }
    }
}

/// The toolbar's appearance button: a menu of the three modes, its icon
/// reflecting the current choice (sun / moon / split circle). A standalone
/// `View` so observation re-renders the icon when the mode changes — a plain
/// function inside the toolbar builder would never be re-evaluated.
struct AppearanceMenuButton: View {
    @State private var settings = AppearanceSettings.shared

    var body: some View {
        Menu {
            ForEach(AppearanceSettings.Mode.allCases) { mode in
                Button {
                    settings.mode = mode
                } label: {
                    if settings.mode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            Label("Appearance", systemImage: settings.mode.symbolName)
        }
        .help("Appearance — now: \(settings.mode.title.lowercased())")
        .accessibilityLabel("Appearance")
        .accessibilityValue(settings.mode.title)
    }
}
