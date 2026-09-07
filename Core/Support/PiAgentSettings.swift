import Foundation

/// Maintains the pointer pi's GLOBAL settings keep to the app-bundled skills
/// directory.
///
/// The `file-reference-links` skill (and any future app-bundled skills) lives
/// INSIDE the app bundle — `…/uni03C0.app/Contents/Resources/Skills` — the
/// idiomatic place for an app's support files. pi never looks there on its
/// own, so at launch the app registers the bundle's skills directory in pi's
/// global settings (`~/.pi/agent/settings.json`, the "Settings" skill
/// location) under the `skills` key. That file is shared with the user's own
/// pi settings (provider, model, …) and with terminal pi runs, so this only
/// ever ADDS its own directory — every other key is preserved verbatim, and
/// an existing entry for the same path is left alone. Writing the pointer is
/// the whole job; the skill content itself is never copied into `~/.pi`.
///
/// pi reads global settings at process spawn, so a registration at app launch
/// is picked up by every session the app starts afterwards (and by any
/// terminal pi started later).
public enum PiAgentSettings {
    /// The settings key pi reads for local skill paths/directories.
    static let skillsKey = "skills"

    /// Ensures `skillsDirectory.path` is listed under `skills` in
    /// `~/.pi/agent/settings.json`, creating the file (with just that entry)
    /// when it doesn't exist yet. Returns true when the entry is present
    /// afterwards; false when the file exists but couldn't be parsed or
    /// written (a corrupt or read-only file is never clobbered).
    @discardableResult
    public static func registerSkillsDirectory(_ skillsDirectory: URL) -> Bool {
        let fileManager = FileManager.default
        let settingsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/settings.json")

        var settings: [String: Any]
        if let data = fileManager.contents(atPath: settingsURL.path), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Unreadable/corrupt settings: never touch the user's file.
                return false
            }
            settings = parsed
        } else {
            settings = [:]
        }

        var skills = settings[Self.skillsKey] as? [String] ?? []
        guard !skills.contains(skillsDirectory.path) else { return true }
        skills.append(skillsDirectory.path)
        settings[Self.skillsKey] = skills

        guard let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return false }

        do {
            let directory = settingsURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: settingsURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
