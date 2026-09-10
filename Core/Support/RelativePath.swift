import Foundation

/// Pure path math for rendering an absolute path relative to another
/// directory — the inverse of what `PathCompletion` does forward (a relative
/// fragment + `cwd` → an absolute path). No filesystem access; fully
/// unit-testable with plain `URL`s.
///
/// Used by `CodeReference.promptText(relativeTo:)`: a reference stores its
/// absolute path (resolved once at copy time) and renders it relative to
/// *whichever* composer it is pasted into, producing `../`-walking fragments
/// that the prompt editor and the agent already understand
/// (`PathCompletion` resolves a leading `../` against `cwd` as a perfectly
/// normal token).
public enum RelativePath {
    /// Returns `target`'s path relative to `base` (a directory), e.g.
    /// `compute(from: /p/Proj, to: /p/Proj/Core/R.swift)` → `"Core/R.swift"`,
    /// `compute(from: /p/Proj/src, to: /p/Proj/lib/F.swift)` → `"../lib/F.swift"`.
    ///
    /// Both paths are standardized lexically first (`.`/`..` collapsed), so
    /// the result is deterministic even when the inputs carry redundant
    /// components. Callers that resolve symlinks (`SandboxPolicy.canonicalize`)
    /// do so BEFORE calling this — both sides must be canonical for the
    /// same-project case to collapse to a plain relative path.
    public static func compute(from base: URL, to target: URL) -> String {
        let baseComponents = base.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents

        var index = 0
        let common = min(baseComponents.count, targetComponents.count)
        while index < common, baseComponents[index] == targetComponents[index] {
            index += 1
        }

        var parts: [String] = []
        // One ".." per base component left over after the common prefix.
        for _ in index..<baseComponents.count {
            parts.append("..")
        }
        for component in targetComponents[index...] {
            parts.append(component)
        }
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
