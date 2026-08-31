import Foundation

/// Never remeasure content on every layout pass. Cache height keyed by
/// content+width, invalidate only on genuine change. The coordinator drops
/// (`invalidate`) rows evicted from the materialized window, so the cache
/// tracks the view's window, not the full conversation.
///
/// Entries can carry an optional content `tag` (a fingerprint of the text the
/// height was measured for). A streaming row's content changes on every delta
/// while its height is only re-seeded on the 0.25s batched refresh, so an
/// (id, width) hit would serve a height measured for older content; the tag
/// lets the renderer reuse a height that is still valid (same content) and
/// re-measure only on genuine change. Rows whose content never changes can use
/// `tag: nil` — (id, width) alone is enough; a nil-tag query only ever hits a
/// nil-tag entry (never a content-tracked one).
///
/// Pure data (no AppKit): the measure closure is supplied by the caller (the
/// transcript coordinator), so this lives in Core and is unit-testable.
///
/// Thread safety: the coordinator mutates the cache on the MAIN thread only
/// (the off-main pre-measurer measures plain values and hops to the main actor
/// to store), but the class is lock-guarded and `@unchecked Sendable` so the
/// pre-measurer can hold a cache reference across a task boundary and a future
/// path that stores off-main stays safe rather than silently corrupting the
/// dictionary. The lock is uncontended in the hot path (`heightOfRow` runs on
/// one thread); the measure closure is deliberately run OUTSIDE the lock so a
/// slow `boundingRect` never blocks a concurrent store.
public final class HeightCache: @unchecked Sendable {
    private struct Entry {
        var width: CGFloat
        var height: CGFloat
        /// The content fingerprint this height was measured for; nil for rows
        /// whose content never changes (any cached height is valid).
        var tag: String?
    }

    private var cache: [String: Entry] = [:]
    private let lock = NSLock()

    public init() {}

    /// Returns the cached height for `id` at `width` when it is still valid
    /// for the given content `tag`; a nil `tag` (content not tracked) only
    /// ever matches a nil-tag entry. Otherwise runs `measure`, caches the
    /// result under `tag`, and returns it.
    public func height(for id: String, width: CGFloat, tag: String? = nil, measure: () -> CGFloat) -> CGFloat {
        lock.lock()
        if let cached = cache[id], abs(cached.width - width) < 0.5, cached.tag == tag {
            let height = cached.height
            lock.unlock()
            return height
        }
        lock.unlock()
        // The measure closure can be a full CoreText `boundingRect` — never
        // hold the lock across it (a concurrent store would block for the
        // whole measure; and on the main thread both paths are serialized
        // anyway). A measure racing a store just computes the same value.
        let height = measure()
        lock.lock()
        cache[id] = Entry(width: width, height: height, tag: tag)
        lock.unlock()
        return height
    }

    /// The cached height for `id` at `width`, whatever content it was measured
    /// for, or nil when absent. Used by the table's `heightOfRow` for
    /// STREAMING rows: the table's row height must match what the cell
    /// renders, which is the last batched refresh the renderer seeded — never
    /// the store's newer, not-yet-rendered content.
    public func heightIfPresent(for id: String, width: CGFloat) -> CGFloat? {
        lock.withLock {
            guard let cached = cache[id], abs(cached.width - width) < 0.5 else { return nil }
            return cached.height
        }
    }

    /// The cached entry for `id` at `width` (height + content tag), or nil when
    /// absent or the width differs. Used by the streaming-row renderer to skip
    /// configure+layout when the content is unchanged since the last render
    /// (a scroll re-entering the row with the same text must not re-measure).
    public func cached(for id: String, width: CGFloat) -> (height: CGFloat, tag: String?)? {
        lock.withLock {
            guard let cached = cache[id], abs(cached.width - width) < 0.5 else { return nil }
            return (cached.height, cached.tag)
        }
    }

    public func invalidate(_ id: String) {
        lock.withLock {
            cache.removeValue(forKey: id)
        }
    }

    /// Drops every cached height (e.g. after a font-size change).
    public func clear() {
        lock.withLock {
            cache.removeAll()
        }
    }

    /// Pre-seeds the cache from an authoritative source (e.g. the visible
    /// cell's own layout) so later `height(for:width:tag:measure:)` calls hit
    /// without running the measure closure.
    public func store(_ id: String, width: CGFloat, height: CGFloat, tag: String? = nil) {
        lock.withLock {
            cache[id] = Entry(width: width, height: height, tag: tag)
        }
    }

    /// Test/observation helper: whether an id has a cached height.
    public func hasHeight(for id: String) -> Bool {
        lock.withLock { cache[id] != nil }
    }

    public var count: Int {
        lock.withLock { cache.count }
    }
}
