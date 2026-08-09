import Foundation

/// Never remeasure content on every layout pass. Cache height keyed by
/// content+width, invalidate only on genuine change. The coordinator drops
/// (`invalidate`) rows evicted from the materialized window, so the cache
/// tracks the view's window, not the full conversation.
///
/// Pure data (no AppKit): the measure closure is supplied by the caller (the
/// transcript coordinator), so this lives in Core and is unit-testable.
public final class HeightCache {
    private struct Entry {
        var width: CGFloat
        var height: CGFloat
    }

    private var cache: [String: Entry] = [:]

    public init() {}

    public func height(for id: String, width: CGFloat, measure: () -> CGFloat) -> CGFloat {
        if let cached = cache[id], abs(cached.width - width) < 0.5 {
            return cached.height
        }
        let height = measure()
        cache[id] = Entry(width: width, height: height)
        return height
    }

    public func invalidate(_ id: String) {
        cache.removeValue(forKey: id)
    }

    /// Drops every cached height (e.g. after a font-size change).
    public func clear() {
        cache.removeAll()
    }

    /// Pre-seeds the cache from an authoritative source (e.g. the visible
    /// cell's own layout) so later `height(for:width:measure:)` calls hit
    /// without running the measure closure.
    public func store(_ id: String, width: CGFloat, height: CGFloat) {
        cache[id] = Entry(width: width, height: height)
    }

    /// Test/observation helper: whether an id has a cached height.
    public func hasHeight(for id: String) -> Bool { cache[id] != nil }

    public var count: Int { cache.count }
}
