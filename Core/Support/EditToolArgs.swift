import Foundation

/// One replacement the edit tool performed: the file it edited and the exact
/// old/new text of a single edit operation.
public struct EditOperation: Hashable, Sendable {
    public let path: String
    public let oldText: String
    public let newText: String

    public init(path: String, oldText: String, newText: String) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
    }
}

/// Decodes the edit tool's arguments (pi 0.84.1 `editSchema`):
///
/// ```json
/// { "path": "<file>", "edits": [{ "oldText": "...", "newText": "..." }] }
/// ```
///
/// Pure and testable. The tool-call card uses this to render a red/green diff
/// (via `TextDiff`) instead of the raw JSON when the card is an edit call.
public enum EditToolArgs {
    /// Parses the structured arguments value (the card's raw args), skipping
    /// malformed entries. Returns `[]` when the shape doesn't match at all.
    public static func parse(_ value: JSONValue?) -> [EditOperation] {
        guard let value,
              case .object(let object) = value,
              case .string(let path)? = object["path"],
              case .array(let edits)? = object["edits"] else {
            return []
        }
        var result: [EditOperation] = []
        for edit in edits {
            guard case .object(let editObject) = edit,
                  case .string(let oldText)? = editObject["oldText"],
                  case .string(let newText)? = editObject["newText"] else {
                continue
            }
            result.append(EditOperation(path: path, oldText: oldText, newText: newText))
        }
        return result
    }

    /// String fallback: parses the pretty-printed arguments text. Used when
    /// only the display string is available (e.g. history rebuilt before the
    /// raw value was carried). A truncated or otherwise unparseable string
    /// simply yields `[]` — the card falls back to plain-text rendering.
    public static func parse(json: String) -> [EditOperation] {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return []
        }
        return parse(value)
    }
}
