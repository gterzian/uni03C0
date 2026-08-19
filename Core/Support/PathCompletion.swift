import Foundation

/// Local-filesystem path completion for the prompt editor (§4 of the design).
///
/// Deliberately *not* an RPC concern: pi's own completion lives in the TUI
/// editor and works against the local filesystem, so the native client does
/// the same, using the same `cwd` the subprocess was spawned with. No round
/// trip to the agent; inherently fast.
public enum PathCompletion {
    /// Returns replacement candidates for the typed fragment (the full text to
    /// substitute for the token under the cursor), or `[]` when nothing matches.
    public static func candidates(for fragment: String, cwd: URL) -> [String] {
        let expanded = (fragment as NSString).expandingTildeInPath
        // A trailing slash means the token points AT a directory: the partial
        // to match is empty and the directory itself is the base (shell
        // semantics — Tab on "Sources/" completes names inside Sources, not
        // "Sources" again, which used to produce a bogus "/Sources/" with a
        // leading slash). Detected on the ORIGINAL fragment: tilde expansion
        // strips the trailing slash.
        let endsInSlash = fragment.hasSuffix("/") && fragment != "/"
        let dirPart = endsInSlash ? expanded : (expanded as NSString).deletingLastPathComponent
        let partial = endsInSlash ? "" : (expanded as NSString).lastPathComponent

        let base: URL
        if dirPart.isEmpty {
            base = cwd
        } else if dirPart.hasPrefix("/") || dirPart.hasPrefix("~") {
            base = URL(fileURLWithPath: dirPart)
        } else {
            base = URL(fileURLWithPath: dirPart, relativeTo: cwd)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        let fragmentHasSlash = fragment.contains("/")
        var results: [String] = []
        for entry in contents {
            let name = entry.lastPathComponent
            if !partial.hasPrefix(".") && name.hasPrefix(".") { continue }
            guard name.hasPrefix(partial) else { continue }
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let completedName = name + (isDir ? "/" : "")
            if fragmentHasSlash {
                if endsInSlash {
                    // The slash is part of the typed fragment itself, so the
                    // prefix to re-emit is the fragment verbatim (with its
                    // trailing slash) and no separator is added. Do NOT use
                    // deletingLastPathComponent here: for a trailing-slash
                    // path it returns "" (Foundation treats the trailing-slash
                    // name as the final component with no parent), which used
                    // to drop the directory and emit a bogus leading "/" —
                    // selecting a candidate then replaced "scratchpad/" with
                    // "/something.md".
                    results.append(fragment + completedName)
                } else {
                    let dirText = (fragment as NSString).deletingLastPathComponent
                    results.append(dirText + "/" + completedName)
                }
            } else {
                results.append(completedName)
            }
        }
        return results.sorted()
    }

    /// True when a token under the cursor should trigger path completion.
    public static func isPathLike(_ fragment: String) -> Bool {
        guard !fragment.isEmpty else { return false }
        if fragment.contains("/") { return true }
        if fragment.hasPrefix("~") { return true }
        if fragment.hasPrefix(".") { return true }
        // Bare relative fragment: a whitespace-free token (e.g. "scratchpad").
        return !fragment.contains(Character(" "))
    }
}
