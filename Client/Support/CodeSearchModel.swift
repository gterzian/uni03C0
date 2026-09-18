import AppKit
import Observation

/// Find-in-buffer state for one read-only code pane — the Files page's open
/// file or the Changes page's diff. A single buffer is already in memory and
/// small next to a whole conversation, so unlike the session's batched,
/// off-main search a query here is one synchronous scan whose hits are plain
/// `NSRange`s into the displayed buffer.
///
/// The model owns only the UI-visible state (visibility, query, case
/// sensitivity, match count/position). The pane registers its container via
/// `attach`; the model then searches, highlights, and scrolls the live buffer.
/// The page owns the model (`@State`); the pane borrows it through the
/// `CodeSearching` protocol so the renderer test bundle need not compile this
/// Observation-macro source.
@MainActor
@Observable
final class CodeSearchModel: CodeSearching {
    var isVisible = false
    var query = ""
    var isCaseSensitive = false
    /// Number of hits in the current buffer.
    private(set) var matchCount = 0
    /// 0-based index of the current hit, -1 when there are none.
    private(set) var currentIndex = -1

    @ObservationIgnored private weak var container: FilePaneContainer?
    @ObservationIgnored private var matches: [NSRange] = []

    // MARK: - CodeSearching (pane-facing)

    func toggle() {
        if isVisible {
            close()
        } else {
            isVisible = true
            rescan()
        }
    }

    func attach(_ container: FilePaneContainer) {
        self.container = container
        if isVisible {
            rescan()
        }
    }

    func bufferDidChange() {
        guard isVisible else { return }
        rescan()
    }

    func next() { advance(by: 1) }
    func previous() { advance(by: -1) }

    func close() {
        isVisible = false
        query = ""
        matches = []
        matchCount = 0
        currentIndex = -1
        container?.clearSearchHighlight()
    }

    // MARK: - Query (find-bar facing)

    func updateQuery(_ query: String) {
        self.query = query
        rescan()
    }

    func setCaseSensitive(_ value: Bool) {
        isCaseSensitive = value
        rescan()
    }

    // MARK: - Engine

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func advance(by delta: Int) {
        guard matchCount > 0, let container, matches.indices.contains(currentIndex) else { return }
        currentIndex = (currentIndex + delta + matchCount) % matchCount
        container.applySearchHighlight(ranges: matches, currentIndex: currentIndex)
        container.revealSearchMatch(matches[currentIndex])
    }

    /// Recomputes the hits for the current query against the pane's buffer and
    /// repaints, re-anchoring at the first hit at or below the viewport top.
    /// That is right for both a query change (continue from where the user is
    /// reading) and a buffer change (a file switch resets the scroll to the
    /// top, a live refresh keeps the reader's place).
    private func rescan() {
        guard let container else {
            matches = []
            matchCount = 0
            currentIndex = -1
            return
        }
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            matches = []
            matchCount = 0
            currentIndex = -1
            container.clearSearchHighlight()
            return
        }
        matches = ReadOnlyCodeTextView.searchRanges(of: trimmed, in: container.codeView.string, caseSensitive: isCaseSensitive)
        matchCount = matches.count
        guard !matches.isEmpty else {
            currentIndex = -1
            container.clearSearchHighlight()
            return
        }
        currentIndex = firstMatchIndex(atOrAfter: container.topVisibleCharacterIndex) ?? 0
        container.applySearchHighlight(ranges: matches, currentIndex: currentIndex)
        container.revealSearchMatch(matches[currentIndex])
    }

    /// The first hit at or after `index`, else the first hit overall — so a
    /// fresh query continues from where the user is reading.
    private func firstMatchIndex(atOrAfter index: Int) -> Int? {
        matches.firstIndex { $0.location >= index } ?? matches.indices.first
    }
}
