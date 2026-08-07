import AppKit
import SwiftUI

/// App-wide conversation font size, persisted to UserDefaults. The transcript
/// renderer/measurer (`TranscriptText`) and the prompt bar read it; the
/// View → Font Size menu writes it. The transcript coordinator observes
/// `didChangeNotification` to invalidate its height cache and re-measure, so
/// measured row heights always match the rendered font.
@MainActor
@Observable
final class FontSettings {
    static let shared = FontSettings()

    /// Posted whenever `bodySize` changes, so AppKit views (the transcript
    /// coordinator) can invalidate caches and re-render.
    static let didChangeNotification = Notification.Name("FontSettings.didChange")

    /// Presets offered in the View menu.
    static let presets: [(name: String, size: CGFloat)] = [
        ("Small", 11),
        ("Regular", 13),
        ("Large", 16),
        ("Extra Large", 19),
    ]

    static let defaultSize: CGFloat = 13

    var bodySize: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(bodySize), forKey: Self.key)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private static let key = "transcriptFontSize"

    private init() {
        let saved = UserDefaults.standard.double(forKey: Self.key)
        bodySize = saved > 0 ? saved : Self.defaultSize
    }
}

/// View → Font Size: smaller/larger shortcuts plus presets (current size
/// checked). Writes `FontSettings.shared.bodySize`; the transcript coordinator
/// re-measures on change.
struct FontSizeCommands: View {
    @State private var settings = FontSettings.shared

    var body: some View {
        Button("Smaller") {
            settings.bodySize = max(settings.bodySize - 1, 9)
        }
        .keyboardShortcut("-", modifiers: .command)
        Button("Larger") {
            settings.bodySize = min(settings.bodySize + 1, 28)
        }
        .keyboardShortcut("+", modifiers: .command)
        Divider()
        ForEach(FontSettings.presets, id: \.name) { preset in
            Button {
                settings.bodySize = preset.size
            } label: {
                if abs(settings.bodySize - preset.size) < 0.1 {
                    Label(preset.name, systemImage: "checkmark")
                } else {
                    Text(preset.name)
                }
            }
        }
        Divider()
        Button("Reset to Default") {
            settings.bodySize = FontSettings.defaultSize
        }
    }
}
