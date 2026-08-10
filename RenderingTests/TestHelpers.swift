import AppKit
import XCTest

/// Shared helpers for the rendering tests: attributed-string attribute
/// extraction and text layout. Everything is deterministic — no pi process,
/// no network.
enum RenderTestHelper {
    /// UTF-16 substring at `range`.
    static func substring(_ string: NSAttributedString, _ range: NSRange) -> String {
        (string.string as NSString).substring(with: range)
    }

    /// First range of `needle` (UTF-16 units); `{NSNotFound, 0}` if absent.
    static func range(of needle: String, in string: NSAttributedString) -> NSRange {
        (string.string as NSString).range(of: needle)
    }

    /// All ranges of `needle`.
    static func ranges(of needle: String, in string: NSAttributedString) -> [NSRange] {
        let haystack = string.string as NSString
        var result: [NSRange] = []
        var search = NSRange(location: 0, length: haystack.length)
        while search.location != NSNotFound && search.length > 0 {
            let r = haystack.range(of: needle, options: [], range: search)
            if r.location == NSNotFound { break }
            result.append(r)
            let newLocation = r.location + r.length
            search = NSRange(location: newLocation, length: haystack.length - newLocation)
        }
        return result
    }

    /// Font attribute at `location`.
    static func font(_ string: NSAttributedString, at location: Int = 0) -> NSFont? {
        string.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    /// Paragraph style at `location`.
    static func paragraph(_ string: NSAttributedString, at location: Int = 0) -> NSParagraphStyle? {
        string.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
    }

    /// True when the font at `location` carries `trait`.
    static func font(_ string: NSAttributedString, at location: Int, hasTrait trait: NSFontDescriptor.SymbolicTraits) -> Bool {
        font(string, at: location)?.fontDescriptor.symbolicTraits.contains(trait) == true
    }

    /// Lays `attributed` out in a text view of `width` (same insets and line
    /// fragment padding as the transcript rows) and returns the used rect.
    static func layout(_ attributed: NSAttributedString, width: CGFloat) -> (used: NSRect, view: NSTextView) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10_000))
        tv.textContainerInset = NSSize(width: 0, height: 6)
        tv.textContainer?.lineFragmentPadding = 8
        tv.textStorage?.setAttributedString(attributed)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        return (tv.layoutManager!.usedRect(for: tv.textContainer!), tv)
    }

    /// The pitch (y distance) between consecutive line fragments of the glyph
    /// range; empty when the range has fewer than two lines.
    static func linePitches(_ view: NSTextView, glyphRange: NSRange) -> [CGFloat] {
        var ys: [CGFloat] = []
        view.layoutManager?.enumerateLineFragments(forGlyphRange: glyphRange) { _, used, _, _, _ in
            ys.append(used.minY)
        }
        return zip(ys, ys.dropFirst()).map { $1 - $0 }
    }

    /// Height of the text when measured with `boundingRect` at the same usable
    /// width the transcript uses (container width minus line-fragment padding).
    static func boundingHeight(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        attributed.boundingRect(
            with: NSSize(width: width - 16, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
    }
}
