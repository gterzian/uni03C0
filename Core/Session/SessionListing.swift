import Foundation

/// Local-filesystem session discovery for the Resume menu (§7 of the design).
///
/// pi owns session storage: `~/.pi/agent/sessions/--<cwd with / → ->--/`.
/// The client only *reads* this directory (never writes into `~/.pi`); to
/// actually open a session it sends `switch_session` over RPC.
public enum SessionListing {
    public static func sessionsDirectory(for cwd: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var path = cwd.path
        // Strip the leading "/" so it doesn't become an extra "-" in the
        // encoded name (real dirs are --Users-Gregory-Projects-x--, not
        // ---Users-...--).
        if path.hasPrefix("/") { path.removeFirst() }
        let encoded = path.replacingOccurrences(of: "/", with: "-")
        return home.appendingPathComponent(".pi/agent/sessions/--\(encoded)--", isDirectory: true)
    }

    public struct Summary: Identifiable, Sendable, Equatable {
        public let id: String
        public let path: URL
        public let timestamp: Date
        public let title: String
    }

    /// Most-recently-modified session files for a project. Reads only the
    /// first few lines of each file (never the whole file), so listing stays
    /// cheap regardless of session length.
    public static func recentSessions(for cwd: URL, limit: Int? = 10) -> [Summary] {
        let dir = sessionsDirectory(for: cwd)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else {
            return []
        }
        let regular = files.filter {
            let values = try? $0.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile ?? true
        }
        let sorted = regular.sorted { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return l > r
        }
        let slice = limit.map { Array(sorted.prefix($0)) } ?? sorted
        return slice.map(summarize)
    }

    /// Peek at a session file: parse the `session` header line, then scan
    /// forward only until we have a title (session name → first user message
    /// → filename), stopping as soon as we have enough.
    private static func summarize(_ file: URL) -> Summary {
        var id = file.deletingPathExtension().lastPathComponent
        var timestamp: Date = .distantPast
        var title: String?
        var userCount = 0

        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return Summary(id: id, path: file, timestamp: timestamp, title: file.lastPathComponent)
        }
        defer { try? handle.close() }
        // Only the head of the file matters (session header + first messages);
        // a bounded read keeps listing cheap regardless of session length.
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()

        let lines = data.split(separator: 0x0A)
        let limit = min(lines.count, 400)
        for i in 0..<limit {
            guard let line = String(data: lines[i], encoding: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            switch json["type"] as? String {
            case "session":
                id = json["id"] as? String ?? id
                if let ts = json["timestamp"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    timestamp = formatter.date(from: ts) ?? timestamp
                }
            case "set_session_name":
                if title == nil, let name = json["name"] as? String, !name.isEmpty {
                    title = name
                }
            case "message":
                if let message = json["message"] as? [String: Any],
                   message["role"] as? String == "user",
                   let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        if block["type"] as? String == "text",
                           let text = block["text"] as? String, !text.isEmpty {
                            if title == nil { title = String(text.prefix(80)) }
                            userCount += 1
                            break
                        }
                    }
                }
            default:
                break
            }
            if title != nil && userCount >= 1 { break }
        }
        if title == nil { title = file.lastPathComponent }
        return Summary(id: id, path: file, timestamp: timestamp, title: title ?? file.lastPathComponent)
    }
}
