import Foundation

/// Installs the app-bundled agent skills into pi's user skills directory
/// (`~/.pi/agent/skills/<name>/SKILL.md`) at launch.
///
/// The `file-reference-links` skill (and any future app-bundled skills) lives
/// inside the app bundle (`…/uni03C0.app/Contents/Resources/Skills`), which pi
/// never scans. pi DOES scan `~/.pi/agent/skills` by default, so the app
/// installs the bundled skill there instead of editing pi's global
/// `settings.json`:
///
/// - **Cache-stable.** The installed path is fixed (`~/.pi/agent/skills/…`),
///   so the `<location>` pi reports for the skill in the system prompt does
///   not move between app launches, builds, or install locations. Editing
///   `settings.json` with a path into DerivedData/`/Applications` would change
///   that location — and with it the provider's cached system-prompt prefix —
///   on every move.
/// - **Sandbox-readable.** The agent (inside Seatbelt) may read `~/.pi`; a
///   path into `/Applications` is denied, so a bundle-located skill would
///   silently drop out of the prompt.
/// - **Idempotent.** An up-to-date install is never rewritten, and an
///   existing skill with a different `name` is left untouched.
///
/// pi reads skills at process spawn, so an install at app launch is picked up
/// by every session the app starts afterwards.
public enum BundledSkill {
    /// Installs every skill directory in `sourceDirectory` into
    /// `agentDir/skills`. Returns true when every bundled skill is present
    /// afterwards, false when the source could not be listed or a file could
    /// not be written.
    @discardableResult
    public static func install(
        from sourceDirectory: URL,
        agentDir: URL = defaultAgentDir()
    ) -> Bool {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return false
        }

        var allInstalled = true
        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
            if !install(skill: content, named: entry.lastPathComponent, agentDir: agentDir) {
                allInstalled = false
            }
        }
        return allInstalled
    }

    /// Installs one skill's text at `agentDir/skills/<name>/SKILL.md` unless an
    /// identical file is already installed or a DIFFERENT skill already
    /// occupies that name (the user's own file is never clobbered).
    @discardableResult
    static func install(skill content: String, named name: String, agentDir: URL) -> Bool {
        let fileManager = FileManager.default
        let destination = agentDir
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("SKILL.md")

        if let existing = try? String(contentsOf: destination, encoding: .utf8) {
            if existing == content { return true }
            // A different skill occupies our name — leave the user's file
            // alone (they can remove it to opt into the bundled one).
            guard sameSkill(existing, content) else { return false }
        }

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: destination, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// True when both files declare the same skill `name` in their
    /// frontmatter — i.e. the installed file is a (possibly older) version of
    /// the bundled skill, safe to replace.
    static func sameSkill(_ a: String, _ b: String) -> Bool {
        guard let nameA = frontmatterName(in: a), let nameB = frontmatterName(in: b) else {
            return false
        }
        return nameA == nameB
    }

    /// Extracts the `name:` value from a leading `---` frontmatter block.
    static func frontmatterName(in content: String) -> String? {
        guard content.hasPrefix("---") else { return nil }
        for line in content.dropFirst(3).split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.hasPrefix("name:") {
                return trimmed.dropFirst("name:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    /// pi's default agent directory (`~/.pi/agent`), the parent of the
    /// default user skills directory.
    public static func defaultAgentDir() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent", isDirectory: true)
    }
}
