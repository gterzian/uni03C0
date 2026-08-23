import Core

/// Stub of `SessionViewModel` for the coordinator tests.
///
/// The real `SessionViewModel` spawns `pi --mode rpc` (a `ProcessController`)
/// at init, and tests never spawn a real pi process, so the transcript
/// `Coordinator` is tested against a member-compatible stand-in. The
/// coordinator only reads/writes the members below (its `store` plus the
/// search/find and streaming state it mirrors); the stand-in provides exactly
/// those, backed by a real `TranscriptStore` so folding RPC frames works like
/// production. Because the coordinator compiles the source directly (the
/// `CoordinatorTests` target), this type IS the `SessionViewModel` the
/// coordinator binds to — keep its members in sync with what
/// `TranscriptView.swift` touches.
final class SessionViewModel {
    let store = TranscriptStore()
    var onTranscriptChange: (() -> Void)?
    var onSearchJump: ((Int) -> Void)?
    var onSearchResultsChanged: (() -> Void)?
    var isSearchVisible = false
    var isFetchingOlder = false
    var isSearching = false
    struct SearchMatch { let storeIndex: Int; let rowID: String; let snippet: String }
    var searchMatches: [SearchMatch] = []
    var searchCurrentIndex = 0
    var searchQuery: String?
    var isCaseSensitive = false
    func toggleSearch() {}
    func nextSearchMatch() {}
    func previousSearchMatch() {}
    func reload() async {}
}
