import Core
import Foundation
import Observation

/// The editable sandbox settings, shared by the first-run picker and the
/// Settings page. The text fields hold the raw editor content; `save()`
/// persists a parsed snapshot. Both views bind to the same instance, so edits
/// stay in sync wherever they happen.
@MainActor
@Observable
final class SandboxSettingsModel {
    static let shared = SandboxSettingsModel()

    var readOnlyPathsText: String
    var allowedHostsText: String

    private init() {
        let settings = SandboxSettings.load()
        readOnlyPathsText = SandboxSettings.serialize(settings.readOnlyPaths)
        allowedHostsText = SandboxSettings.serialize(settings.allowedHosts)
    }

    /// The parsed settings as they would be saved right now.
    var current: SandboxSettings {
        SandboxSettings(
            readOnlyPaths: SandboxSettings.parse(readOnlyPathsText),
            allowedHosts: SandboxSettings.parse(allowedHostsText)
        )
    }

    func save() {
        current.save()
    }
}
