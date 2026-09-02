import AppKit
import Core

/// The off-main height pre-measurement pipeline, expressed with explicit
/// `Sendable` value structures.
///
/// The coordinator (a `@MainActor` type in the default-`MainActor` Client
/// target) builds one `RowMeasureSpec` per settled text row entering the
/// materialized window, then a single detached task maps specs → measurements
/// on a worker thread, and the coordinator stores the results on the main
/// actor. Every value crossing the task boundary is a plain `Sendable`
/// struct — the worker never touches the row model, the view hierarchy, a
/// `HeightCache`, or any coordinator state. That confines the "callable off
/// the main actor" surface to exactly the pure measurement entry point below
/// (plus the markdown parse it shares with the main-thread renderer): nothing
/// else in the pipeline needs a `nonisolated` annotation at all.
///
/// A spec is built on the main actor at schedule time, so it captures the
/// row's content and the cache tag exactly as the main-thread measure path
/// would key them — a seeded height is indistinguishable from a synchronously
/// measured one (the "one measurement function" invariant).
struct RowMeasureSpec: Sendable {
    let id: String
    let text: String
    let thinking: String?
    let role: TextRowView.Role
    let cacheHitRate: Double?
    let cacheMiss: Bool
    /// The content fingerprint the height is cached under (computed on main,
    /// so the seeded entry is keyed identically to main-thread ones).
    let tag: String?
}

/// The result of measuring one spec, stored into the session's height cache
/// on the main actor.
struct RowMeasurement: Sendable {
    let id: String
    let width: CGFloat
    let height: CGFloat
    let tag: String?
}

/// The pre-measure worker's single entry point. Pure over `RowMeasureSpec`
/// (all-Sendable input/output), calling the SAME
/// `TranscriptText.measuredHeight` as the main-thread synchronous path, so
/// both produce byte-identical heights. The whole type is `nonisolated` to
/// opt out of the target's default `MainActor` isolation — the only
/// annotation the off-main computation needs.
nonisolated enum RowMeasurer {
    static func measure(_ spec: RowMeasureSpec, width: CGFloat, bodySize: CGFloat) -> RowMeasurement {
        let height = TranscriptText.measuredHeight(
            text: spec.text,
            thinking: spec.thinking,
            role: spec.role,
            isStreaming: false, // pre-measurable rows are always settled
            width: width,
            cacheHitRate: spec.cacheHitRate,
            cacheMiss: spec.cacheMiss,
            bodySize: bodySize
        )
        return RowMeasurement(id: spec.id, width: width, height: height, tag: spec.tag)
    }
}
