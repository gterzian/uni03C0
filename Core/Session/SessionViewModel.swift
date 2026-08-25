import Foundation
import Observation

/// One session's observable state. This is now a *thin shim* over
/// `TranscriptStore`: it owns the connection, the RPC commands (prompt/abort/
/// setModel/...), and the few bits of UI state SwiftUI reads (`isStreaming`,
/// `model`, `thinkingLevel`, `isReloading`). It does NOT own the transcript —
/// that lives in `TranscriptStore`, folded off the main thread. The AppKit
/// coordinator reads the store directly.
///
/// The event stream is the single source of truth — nothing is
/// hand-maintained in parallel.
@MainActor
@Observable
public final class SessionViewModel {
    public enum ConnectionState: Equatable {
        case starting
        case connected
        case disconnected(String)
    }

    public private(set) var connectionState: ConnectionState = .starting
    /// The last send/prompt failure (preflight errors, auth failures, …), shown
    /// as a dismissible error banner above the prompt bar. Cleared on the next
    /// successful send. Set by the view layer (SessionContent's dismiss button).
    public var lastError: String?
    public private(set) var isStreaming = false
    public private(set) var model: ModelInfo?
    public private(set) var availableModels: [ModelInfo] = []
    public private(set) var thinkingLevel: String?
    public private(set) var availableThinkingLevels: [String] = []
    /// Context-window usage (percentage of the model's context window in use),
    /// refreshed from `get_session_stats`. Polled continuously while a turn is
    /// streaming so the readout tracks the live context; refreshed once more
    /// when the turn settles. Read by the status readout in the prompt bar.
    public private(set) var contextUsage: ContextUsage?
    public private(set) var sessionFile: URL?
    public private(set) var sessionName: String?
    /// True while a session switch / reload is rebuilding the transcript off
    /// the main thread. SwiftUI shows an in-app spinner from this; the main
    /// thread is never blocked.
    public private(set) var isReloading = false
    /// True while the coordinator is fetching a block of older history at the
    /// top of the transcript (scrolling up). Drives the in-app spinner above
    /// the conversation. Set by the AppKit coordinator on the main actor.
    public var isFetchingOlder = false

    /// The full history, owned off-main. Both the RPC-folding here and the
    /// coordinator (main thread) read/write it through lock-guarded APIs.
    public let store = TranscriptStore()

    public let cwd: URL
    public let controller: ProcessController
    /// Loopback whitelist proxy — the agent's only internet egress. Started
    /// with the session, stopped with it.
    public let proxy: WhitelistProxy

    /// AppKit-side hook: the transcript coordinator sets this and is called on
    /// the main actor whenever the store has mutated. The SwiftUI body
    /// deliberately never reads the transcript entries, so a streamed delta
    /// does not touch the SwiftUI graph at all — updates flow store → AppKit
    /// directly.
    public var onTranscriptChange: (() -> Void)?

    /// AppKit-side hook: called whenever a live status-readout input changes
    /// (context usage, model, thinking level). The prompt bar's coordinator
    /// sets this and updates the status label IN PLACE, so the 2s context
    /// poll re-renders only the readout — never the whole session body (which
    /// would otherwise re-run both NSViewRepresentable `updateNSView` calls
    /// every 2s, the whole-session redraw seen in Quartz Debug while typing).
    public var onStatusTextChanged: (() -> Void)?

    // MARK: - Per-session search

    /// True while the find bar is shown over the transcript (Cmd+F toggles).
    public var isSearchVisible = false
    /// The current query (the find bar's text, kept per session).
    public var searchQuery = ""
    /// The live match list, in REVERSE session order — the bottom-most (most
    /// recent) match is index 0, so the find bar reads 1/270 and the first
    /// result is the one nearest the viewport (the search jumps to it, and
    /// never yanks the viewport up to earlier history). While a search is in
    /// progress (`isSearching`) this is a PARTIAL list — only the ranges
    /// processed so far — and grows at the END as each batch lands; it
    /// reaches the full conversation's matches once the search completes.
    public private(set) var searchMatches: [TranscriptStore.SearchMatch] = []
    /// Index into `searchMatches` of the current match; -1 when there are none.
    public private(set) var searchCurrentIndex = -1
    /// True while a batched search has ranges still to cover. The find bar
    /// shows "x of ⟨spinner⟩" instead of a final total until this flips
    /// false — the total is only known once the whole session has been
    /// searched. Cycling (Enter/Shift+Enter) still works on the partial list.
    public private(set) var isSearching = false
    /// Case-sensitive matching for the find bar (off by default, matching
    /// most find-in-page defaults).
    public var isCaseSensitive = false
    /// AppKit-side hook: called with the store index of the current match so
    /// the coordinator can materialize history and scroll the row into view.
    public var onSearchJump: ((Int) -> Void)?

    /// AppKit-side hook: called whenever the match set or the current match
    /// changed (a query ran, Enter cycled, or search closed) so the
    /// coordinator can re-render the yellow row highlights.
    public var onSearchResultsChanged: (() -> Void)?

    private var searchTask: Task<Void, Never>?
    /// Monotonic id per search run. Batch applications guard on it: a batch
    /// whose run was superseded (the query changed mid-search, or the bar
    /// closed) is dropped even if its task escaped cancellation.
    private var searchRunID: UInt64 = 0
    /// The query the current match list was computed for (Enter re-runs the
    /// search when the text has changed since the last run).
    private var lastSearchedQuery = ""
    /// Whether the current match list was computed case-sensitively — a
    /// sensitivity toggle must re-run even when the text is unchanged.
    private var lastSearchedCaseSensitive = false

    /// How long typing must pause before a live search runs. The keys need to
    /// SETTLE: a search that fires mid-word jumps the transcript around while
    /// the query is still being refined. 500ms reads as a real pause without
    /// feeling laggy (250ms fired per keystroke, 800ms waited too long).
    private static let searchSettleDelay: Duration = .milliseconds(500)

    /// Rows per search batch. The search walks the conversation from the tail
    /// upward in slices of this size; each slice is searched in its own task
    /// and the results applied as they land, so the find bar fills in
    /// incrementally (bottom of the conversation first — the rows the user
    /// can already see) instead of after one whole-store pass. Sized so a
    /// single-batch search is well under a millisecond even for text-heavy
    /// rows. Internal so tests can shrink it to observe intermediate states.
    internal var searchBatchSize = 200

    /// Toggles the find bar. Closing it clears the search state AND the
    /// query, so reopening starts a blank new search (no stale results or
    /// auto-run of the previous query).
    public func toggleSearch() {
        if isSearchVisible {
            closeSearch()
        } else {
            isSearchVisible = true
            // Closing cleared the query, so the field reopens blank; this is
            // a defensive no-op in the normal flow (no path leaves a query
            // set while the bar is closed).
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                runSearch(searchQuery)
            }
        }
    }

    public func closeSearch() {
        isSearchVisible = false
        searchQuery = ""
        clearSearchResults()
    }

    /// Clears the match state (closing the bar, or a session switch that made
    /// the old row ids meaningless) and tells the view to drop the highlights.
    /// Also invalidates any in-flight batched search: the run id is bumped so
    /// batches already dispatched under the old run are dropped on arrival.
    private func clearSearchResults() {
        searchTask?.cancel()
        searchTask = nil
        searchRunID &+= 1
        searchMatches = []
        searchCurrentIndex = -1
        isSearching = false
        lastSearchedQuery = ""
        lastSearchedCaseSensitive = false
        onSearchResultsChanged?()
    }

    /// Live search as the query is typed, debounced: the query only runs once
    /// the keys have SETTLED — every keystroke cancels the pending run and
    /// restarts the settle timer, so a burst of typing launches a single
    /// search instead of one per character.
    public func updateSearchQuery(_ query: String) {
        performSearch(query: query, debounce: Self.searchSettleDelay)
    }

    /// Runs the search now (Enter / Cmd+F reopen / sensitivity toggle).
    public func runSearch(_ query: String) {
        performSearch(query: query, debounce: .zero)
    }

    /// Runs a batched search over the store. The whole conversation is NOT
    /// searched in one pass: `performSearch` resets the run state, then
    /// `searchBatches` walks the store from the TAIL upward in slices of
    /// `searchBatchSize` rows, searching each slice in its own task and
    /// applying the results as they land, until every row is covered. The
    /// find bar therefore fills in near the bottom first (the rows the user
    /// can already see) and the total only appears once the run completes.
    private func performSearch(query: String, debounce: Duration) {
        searchTask?.cancel()
        searchRunID &+= 1
        searchQuery = query
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask = Task { [weak self] in
            guard let self else { return }
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            guard !Task.isCancelled else { return }
            let caseSensitive = self.isCaseSensitive
            let store = self.store
            let runID = self.searchRunID
            if trimmed.isEmpty {
                self.applySearchResults([], trimmed: trimmed, runID: runID, isFirstBatch: true, searchComplete: true)
                return
            }
            self.beginSearchRun()
            await self.searchBatches(store: store, trimmed: trimmed, caseSensitive: caseSensitive, runID: runID)
        }
    }

    /// Marks a search run as in progress: the previous query's matches are
    /// dropped and `isSearching` flips on, so the find bar shows a spinner
    /// until the first batch lands. The current index is deliberately kept —
    /// a same-query re-run (e.g. a case-sensitivity toggle) preserves the
    /// position; a fresh query lands on result 1 when the first batch applies.
    private func beginSearchRun() {
        searchMatches = []
        isSearching = true
        onSearchResultsChanged?()
    }

    /// The batched search loop. Walks the conversation from the TAIL upward:
    /// each range is searched in its own detached task (off the main thread —
    /// the search itself never blocks the UI), the results applied on the
    /// main actor as they land, then the next range above is searched, until
    /// the whole conversation is covered.
    ///
    /// Threading model (deliberate): this loop is NONISOLATED — it runs on
    /// the search task's executor, OFF the main actor — and hops to the main
    /// actor once per batch, only to apply the results. The main thread's
    /// per-batch work is therefore just the apply (match-list prepend, index
    /// fix-up, highlight notification); it never drives the loop and never
    /// waits on a scan, so scrolling/streaming stay free for the whole
    /// search. The apply (`applySearchResults`) mutates MainActor state
    /// (`searchMatches`, `searchCurrentIndex`, `isSearching`) and calls the
    /// coordinator hooks, so it must run on the main actor — but nothing
    /// else in the search does. Cancellation is observed between batches
    /// (`Task.isCancelled`), and a superseding run is dropped by the run-id
    /// guard inside `applySearchResults`.
    ///
    /// Note: the ranges are computed ONCE from the store's count at search
    /// start. Rows appended WHILE the search runs (a turn streaming in) are
    /// deliberately not covered by this run — re-running the search (or the
    /// next Enter) picks them up. This is a known, accepted limitation for
    /// now, kept so the loop is a simple countdown over a fixed slice list.
    private nonisolated func searchBatches(store: TranscriptStore, trimmed: String, caseSensitive: Bool, runID: UInt64) async {
        let batchSize = await MainActor.run { self.searchBatchSize }
        let total = store.count
        if total == 0 {
            await MainActor.run {
                self.applySearchResults([], trimmed: trimmed, runID: runID, isFirstBatch: true, searchComplete: true)
            }
            return
        }
        var upperBound = total
        var isFirstBatch = true
        while upperBound > 0, !Task.isCancelled {
            let lowerBound = max(0, upperBound - batchSize)
            // Each range is searched in a NEW task, so a superseding search
            // can cancel this loop between batches and the dispatched work is
            // simply dropped (the run-id guard in applySearchResults).
            let matches = await Task.detached(priority: .userInitiated) { [store, trimmed, caseSensitive, lowerBound, upperBound] in
                store.search(trimmed, caseSensitive: caseSensitive, in: lowerBound..<upperBound)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.applySearchResults(matches, trimmed: trimmed, runID: runID, isFirstBatch: isFirstBatch, searchComplete: lowerBound == 0)
            }
            upperBound = lowerBound
            isFirstBatch = false
        }
    }

    /// Applies ONE search batch on the main actor. The match list is built in
    /// REVERSE session order — the bottom-most (most recent) match is index 0,
    /// so the find bar reads 1/270 and the first result is the one nearest the
    /// viewport, and the search jump never yanks the viewport up to earlier
    /// history (which fought the user's own scrolling). Batches arrive
    /// tail-first, so each batch's matches (ascending store index within the
    /// batch) are reversed and APPENDED: index 0 is always the first-found
    /// (bottom) match and never shifts as later batches land. A fresh search
    /// always lands on result 1 (index 0) — a same-query re-run (e.g. a
    /// case-sensitivity toggle) keeps the current position when it is still
    /// valid. Only the first batch (or the first match appearing after an
    /// empty tail) jumps the transcript; later batches just extend the
    /// highlight set without moving the user's viewport.
    private func applySearchResults(_ batch: [TranscriptStore.SearchMatch], trimmed: String, runID: UInt64, isFirstBatch: Bool, searchComplete: Bool) {
        guard runID == searchRunID else { return } // superseded by a newer run
        let batch = Array(batch.reversed())
        var shouldJump = false
        if isFirstBatch {
            searchMatches = batch
            if batch.isEmpty {
                searchCurrentIndex = -1
            } else if lastSearchedQuery == trimmed, batch.indices.contains(searchCurrentIndex) {
                // Same-query re-run: keep the current position.
            } else {
                // Fresh search: land on result 1 — the bottom-most match — so
                // the counter reads 1/N and the jump stays near the viewport.
                searchCurrentIndex = 0
            }
            shouldJump = !batch.isEmpty
        } else {
            // Appending never shifts the current match's index (it sits at the
            // front of the list), so no index fix-up is needed.
            searchMatches = searchMatches + batch
            if searchCurrentIndex < 0, !searchMatches.isEmpty {
                // The tail batches found nothing — the first match just
                // appeared, adopt it and jump so the user sees the first hit.
                searchCurrentIndex = 0
                shouldJump = true
            }
        }
        lastSearchedQuery = trimmed
        lastSearchedCaseSensitive = isCaseSensitive
        isSearching = !searchComplete
        if shouldJump {
            jumpToCurrentMatch()
        }
        onSearchResultsChanged?()
    }

    /// Toggles case-sensitive matching and re-runs the current query so the
    /// match list (and highlight) reflects the new sensitivity immediately.
    public func setCaseSensitive(_ enabled: Bool) {
        guard isCaseSensitive != enabled else { return }
        isCaseSensitive = enabled
        if isSearchVisible, !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runSearch(searchQuery)
        }
    }

    /// Enter / Cmd+G / chevron-up: move to the NEXT result in list order —
    /// 1 → 2 → 3, up the session toward older content (the result number
    /// INCREASES) — wrapping around to the bottom-most match after the last.
    public func nextSearchMatch() {
        advanceSearchMatch(by: 1)
    }

    /// Shift+Enter / Shift+Cmd+G / chevron-down: move to the PREVIOUS result —
    /// down the session toward newer content (the result number DECREASES) —
    /// wrapping around to the top-most match.
    public func previousSearchMatch() {
        advanceSearchMatch(by: -1)
    }

    private func advanceSearchMatch(by delta: Int) {
        // Cycling only makes sense while the bar is open: with it closed the
        // query is stale and re-running it would jump the transcript around
        // behind the user's back (Cmd+G is a no-op until Cmd+F reopens).
        guard isSearchVisible else { return }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, lastSearchedQuery == trimmed, lastSearchedCaseSensitive == isCaseSensitive, !searchMatches.isEmpty {
            // The visible matches are current for this query — advance now.
            if isSearching {
                // Partial list, still growing: CLAMP instead of wrapping. The
                // modular wrap would jump from result 1 to the partial list's
                // END (the top-most match found so far) — e.g. Enter mid-
                // search landing on 76/307 and yanking the viewport up the
                // history while more batches are landing.
                searchCurrentIndex = min(max(searchCurrentIndex + delta, 0), searchMatches.count - 1)
            } else {
                searchCurrentIndex = (searchCurrentIndex + delta + searchMatches.count) % searchMatches.count
            }
            jumpToCurrentMatch()
            onSearchResultsChanged?()
        } else if !trimmed.isEmpty {
            // The matches are stale (typing since the last run) or a search is
            // in flight — re-run; the fresh results land on result 1.
            performSearch(query: searchQuery, debounce: .zero)
        }
    }

    private func jumpToCurrentMatch() {
        guard searchMatches.indices.contains(searchCurrentIndex) else { return }
        onSearchJump?(searchMatches[searchCurrentIndex].storeIndex)
    }

    /// Accessibility hook: called when an agent run settles (the whole turn,
    /// including tool rounds, finished). The view layer posts an announcement
    /// so a VoiceOver user knows the work is done.
    public var onAgentSettled: (() -> Void)?

    private var eventTask: Task<Void, Never>?
    /// Periodic `get_session_stats` poller while the agent is streaming. pi has
    /// no event that pushes context usage, so the client polls: `get_session_stats`
    /// is a synchronous estimate on the agent side and the RPC loop interleaves
    /// it with event streaming, so a 2s cadence costs ~nothing while keeping the
    /// readout live. Started on the first turn-start and stopped on settle (the
    /// true end of work — not `agent_end`/`turn_end`, which also fire between
    /// tool rounds).
    private static let contextPollInterval: Duration = .seconds(2)
    private var contextPollTask: Task<Void, Never>?

    public init(cwd: URL, executable: String? = nil, projectsRoot: URL? = nil) {
        self.cwd = cwd
        // Debug escape hatch: PI_NOSANDBOX=1 runs the agent without a Seatbelt
        // profile (used to isolate sandbox-caused failures).
        let settings = ProcessInfo.processInfo.environment["PI_NOSANDBOX"] == nil
            ? SandboxSettings.load()
            : nil
        // Snapshot the sandbox settings at spawn: the seatbelt profile is
        // one-way and the proxy whitelist is fixed for the session's life, so
        // edits take effect on the next session (the settings page says so).
        self.proxy = WhitelistProxy(whitelist: .init(hosts: settings?.allowedHosts ?? []))
        // The RPC endpoint: the local pi executable spawned as `pi --mode rpc`.
        // Read from the settings (default: pi resolved from PATH), overridable
        // programmatically for tests.
        let exec = executable ?? RPCEndpointSettings.load().executablePath
        self.controller = ProcessController(
            executablePath: exec,
            arguments: ["--mode", "rpc"],
            workingDirectory: cwd.path,
            sandbox: settings,
            proxy: self.proxy,
            projectsRoot: projectsRoot?.path
        )
    }

    // MARK: - Lifecycle

    public func start() async {
        guard eventTask == nil else { return }
        // Bring up the loopback egress first so the spawn picks up the port.
        try? await proxy.start()
        await controller.start()
        eventTask = Task { [weak self] in
            await self?.consumeEvents()
        }
        await refreshState()
        // No model is forced at spawn: the session starts exactly as it would
        // in the terminal TUI — pi applies its own settings
        // (defaultProvider / defaultModel / defaultThinkingLevel) at spawn and
        // the app reads the live model and thinking level from get_state and
        // events. Never switching the model or the thinking level behind the
        // user's back keeps the requests the session produces — and thus the
        // provider-side prompt cache — identical whether the session is driven
        // from the app or the TUI.
        // Switching the model can change which thinking levels it supports, so
        // re-fetch the runtime options (models + levels) for the status bar.
        await refreshRuntimeOptions()
        await refreshContextStats()
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        stopContextPolling()
        await controller.terminate()
        await proxy.stop()
    }

    private func consumeEvents() async {
        do {
            for try await frame in controller.events {
                await handleFrame(frame)
            }
            if connectionState != .disconnected("") {
                connectionState = .disconnected("agent process exited")
            }
        } catch {
            connectionState = .disconnected(error.localizedDescription)
        }
    }

    /// Handles one frame: applies UI-visible state on the main actor, then
    /// folds the transcript off the main thread and notifies the renderer if
    /// anything changed. The main actor yields while the store folds, so a
    /// streamed delta never blocks the UI.
    private func handleFrame(_ frame: RPCFrame) async {
        switch frame.type {
        case "agent_start", "turn_start":
            isStreaming = true
            startContextPolling()
        case "agent_end", "turn_end":
            // turn_end also fires BETWEEN tool rounds inside one agent run —
            // that is not the end of the work, so nothing is flushed here
            // (flushing here raced pi and collapsed the queue).
            isStreaming = false

        case "agent_settled":
            // The whole agent run settled. Flush any queued steering as ONE
            // combined prompt (never one turn per message like the TUI) — or,
            // after an abort, return it to the input for editing instead.
            isStreaming = false
            stopContextPolling()
            if abortReturnsQueuedSteering {
                // The user aborted: don't flush queued steering as a new
                // prompt — return it to the input for editing instead.
                abortReturnsQueuedSteering = false
                if !queuedSteering.isEmpty {
                    let restored = queuedSteeringText
                    queuedSteering = []
                    onRestoreSteeringToInput?(restored)
                }
            } else {
                await flushQueuedSteering()
            }
            // The new assistant messages carry the context reading, so the
            // usage is now accurate.
            await refreshContextStats()
            onAgentSettled?()

        case "thinking_level_changed":
            if let level = frame.levelText() { thinkingLevel = level }
            onStatusTextChanged?()
        case "model_changed":
            if let model = frame.decodeModelChange() { self.model = model }
            onStatusTextChanged?()

        default:
            break // transcript frames are folded by the store below
        }

        let changed = await Task.detached(priority: .userInitiated) { [store] in
            store.apply(frame)
        }.value
        if changed {
            onTranscriptChange?()
        }
    }

    // MARK: - Commands

    /// Set when an abort ends the turn: queued steering is returned to the
    /// prompt input instead of being flushed as a new prompt.
    private var abortReturnsQueuedSteering = false

    /// Hook for the prompt bar: called with the joined queued steering when an
    /// abort returns it to the input.
    public var onRestoreSteeringToInput: ((String) -> Void)?

    public func sendPrompt(_ text: String) async throws {
        abortReturnsQueuedSteering = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let response = try await controller.send(.prompt(message: trimmed))
            if response.success == false {
                throw ProcessError.commandFailed(response.error ?? "prompt rejected")
            }
            lastError = nil
        } catch {
            // Surface send failures (auth/preflight/network) to the UI instead
            // of silently swallowing them.
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    // MARK: - Steering (queued while a turn is in flight)

    /// Steering messages queued while a turn is in flight. They are never sent
    /// individually: when the turn settles, the whole queue is flushed as one
    /// combined prompt (`flushQueuedSteering`), so the agent never starts one
    /// turn per queued message.
    public private(set) var queuedSteering: [String] = []

    /// True while at least one steering message is queued — drives the banner
    /// above the prompt bar.
    public var hasQueuedSteering: Bool { !queuedSteering.isEmpty }

    /// The queued steering, joined for display and for the single flush.
    public var queuedSteeringText: String { queuedSteering.joined(separator: "\n\n") }

    /// Queue a steering message (Return while a turn is in flight). It is held
    /// until the turn settles, then sent as part of one combined prompt.
    public func queueSteering(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queuedSteering.append(trimmed)
    }

    /// Remove one queued steering message (the per-row edit/delete buttons on
    /// the queued-steering banner).
    public func removeQueuedSteering(at index: Int) {
        guard queuedSteering.indices.contains(index) else { return }
        queuedSteering.remove(at: index)
    }

    /// Sends all queued steering messages as one combined prompt. On failure
    /// the combined text is kept so the next settle retries instead of losing
    /// the user's steering.
    private func flushQueuedSteering() async {
        guard !queuedSteering.isEmpty else { return }
        let combined = queuedSteeringText
        queuedSteering = []
        do {
            try await sendPrompt(combined)
        } catch {
            queuedSteering = [combined]
        }
    }

    public func setModel(_ provider: String, _ modelId: String) async throws {
        let response = try await controller.send(.setModel(provider: provider, modelId: modelId))
        if let model = response.dataPayload(ModelInfo.self) {
            self.model = model
        } else if let model = response.decodeModelChange() {
            self.model = model
        }
        onStatusTextChanged?()
        // The set of supported thinking levels depends on the model: re-fetch
        // after a switch so the menu matches the new model. The thinking level
        // itself is left as pi has it — switching the model never forces one.
        await refreshRuntimeOptions()
    }

    public func setThinkingLevel(_ level: String) async throws {
        _ = try await controller.send(.setThinkingLevel(level: level))
        thinkingLevel = level
        onStatusTextChanged?()
    }

    /// Aborts the current agent operation — the in-flight LLM turn (including
    /// thinking) and any running tool execution.
    public func abort() async throws {
        abortReturnsQueuedSteering = true
        _ = try await controller.send(.abort())
    }

    /// Reload = ask the running process what its own session file is, then
    /// `switch_session` to that same path (re-reads state from disk without
    /// restarting the process), then repopulate messages.
    public func reload() async {
        guard let payload = try? await controller.send(.getState()).dataPayload(SessionStatePayload.self),
              let path = payload.sessionFile else { return }
        _ = try? await controller.send(.switchSession(path: path))
        await refreshState()
        await loadMessages()
    }

    /// Resume = switch to another session file, then repopulate.
    public func switchSession(_ path: URL) async {
        _ = try? await controller.send(.switchSession(path: path.path))
        await refreshState()
        await loadMessages()
    }

    /// Refreshes the context-window usage percentage from `get_session_stats`.
    public func refreshContextStats() async {
        guard connectionState == .connected else { return }
        guard let payload = try? await controller.send(.getSessionStats()).dataPayload(SessionStatsPayload.self) else {
            return
        }
        contextUsage = payload.contextUsage
        onStatusTextChanged?()
    }

    /// Starts the continuous context-usage poller (idempotent). Runs until
    /// `stopContextPolling()` — on `agent_settled` or session teardown.
    private func startContextPolling() {
        guard contextPollTask == nil else { return }
        contextPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshContextStats()
                do {
                    try await Task.sleep(for: Self.contextPollInterval)
                } catch {
                    return // cancelled — the loop is done
                }
            }
        }
    }

    private func stopContextPolling() {
        contextPollTask?.cancel()
        contextPollTask = nil
    }

    private func refreshState() async {
        guard let payload = try? await controller.send(.getState()).dataPayload(SessionStatePayload.self) else {
            connectionState = .disconnected("no response from the agent")
            return
        }
        model = payload.model
        thinkingLevel = payload.thinkingLevel
        onStatusTextChanged?()
        if let file = payload.sessionFile { sessionFile = URL(fileURLWithPath: file) }
        sessionName = payload.sessionName
        isStreaming = payload.isStreaming ?? false
        connectionState = .connected
        await refreshRuntimeOptions()
    }

    /// Refreshes the available models and thinking levels (used by the status
    /// bar pickers). The set of supported levels depends on the current model,
    /// so this runs again after the model is switched.
    private func refreshRuntimeOptions() async {
        let models = try? await controller.send(.getAvailableModels()).dataPayload(ModelsPayload.self)
        availableModels = models?.models ?? []
        let levels = try? await controller.send(.getAvailableThinkingLevels()).dataPayload(LevelsPayload.self)
        availableThinkingLevels = levels?.levels ?? []
    }

    /// Rebuilds the transcript from `get_messages` off the main thread,
    /// driving the in-app `isReloading` spinner (not the system beachball)
    /// while the store folds the whole history.
    public func loadMessages() async {
        guard let payload = try? await controller.send(.getMessages()).dataPayload(MessagesPayload.self) else {
            return
        }
        let messages = payload.messages
        isReloading = true
        let changed = await Task.detached(priority: .userInitiated) { [store] in
            store.rebuild(from: messages)
        }.value
        isReloading = false
        // The store was rebuilt — any live search matches reference the OLD
        // session's row ids and must not paint highlights on the new one.
        if isSearchVisible || !searchMatches.isEmpty {
            clearSearchResults()
        }
        if changed {
            onTranscriptChange?()
        }
        await refreshContextStats()
    }
}

// MARK: - Small decode helpers

private struct LevelBox: Decodable { let level: String? }

private extension RPCFrame {
    func levelText() -> String? {
        (try? decode(LevelBox.self))?.level
    }
}
