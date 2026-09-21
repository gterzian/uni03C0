# AGENTS.md

## What belongs in this file (read before editing it)

This file carries only guidance an agent **cannot derive from the code**: hard
rules, sandbox constraints, commands, and paid-for gotchas — not a design doc.

- Keep: an instruction, a constraint, a command, a non-obvious failure mode.
- Cut: type-by-type descriptions, architecture narration, feature inventories,
  "how it works" prose, design rationale — the code and commits are the source.
- Prefer one imperative line; record history only when it prevents a regression.
- **Budget: under 300 lines.** Adding a section means deleting as much stale
  text; if a change only makes the file longer, it belongs in a code comment.

---

## The one rule

**Never use git except for read operations.** The human owns the repository
history.

- Allowed: `git status`, `log`, `diff`, `show`, `blame`, `grep`, `ls-files`,
  `rev-parse`, `stash list` — anything that only reads.
- Forbidden: `add`, `commit`, `push`, `pull`, `fetch`, `checkout`, `switch`,
  `reset`, `revert`, `rebase`, `merge`, `cherry-pick`, `stash` push/pop/drop,
  `tag`, `branch -m`, `clean`, `rm`, `mv`, config writes, `init`, `gc`,
  `filter-branch` — anything that writes.
- When the user asks to "commit", **suggest a commit message**; never run it.

## Two properties every change must preserve

1. **Fast UI** — cost scales with *visible* rows, never context/message size;
   no full-CoreText work or synchronous re-measure on hot paths.
2. **Sandbox fails closed** — default-deny policy, loopback proxy the only
   egress, denials never bypassed or hidden.

---

## You are running inside a sandbox

You run under a default-deny **Seatbelt** policy. **Settings** (app menu →
Settings…) defines what you can touch: working folder and extra paths
(read+write), `~/.pi` (read+write), system dirs (read-only), and the **allowed
internet domains** reachable through a loopback whitelist proxy. `HTTP_PROXY`/
`HTTPS_PROXY`/`ALL_PROXY`, `NODE_OPTIONS=--use-env-proxy` and git proxy config
are set; a tool that ignores them cannot connect.

Everything else is denied silently (`EPERM`) or as a connection failure. **When
something is denied, say so and tell the user what to change** — do not guess or
work around it:

- Missing file/dir → ask the user to add it under **Additional read/write
  paths**, or move the work under the working folder.
- Host unreachable → ask the user to add its domain under **Allowed internet
  domains**.
- Network tool fails → check whether it honors the proxy env; if not, say how it
  must be configured.

Settings are snapshotted at agent spawn. Changing them requires an app restart;
**Resume/Reload reuse the running process and do NOT re-apply the sandbox.**

---

## Stable session data (provider prompt cache)

The provider caches the session's prompt prefix, so request bytes must stay
identical whether driven from the app or the TUI. pi owns the data; the app is a
read-only mirror. **Never alter what pi records or sends for the same actions.**

- The app never writes session data; it reads only through pi's read-only RPCs
  (`get_state`, `get_messages`, `get_session_stats`, `get_available_models`,
  `get_available_thinking_levels`).
- Send only the commands pi's TUI sends, for the same user actions. Session
  defaults are pi's: never force or auto-change the model or thinking level, and
  offer exactly what `get_available_thinking_levels` reports.
- A prompt is the user's text verbatim (only whitespace trimming, as the TUI
  does). No re-sends, retries, or duplicates; `ProcessController.send` writes
  each request exactly once.
- Rendering caches (heights, expansion, fonts, diffs) are pure UI: never sent,
  and nothing derived from them may feed back into what pi records.
- One deliberate deviation: queued steering flushes as ONE combined prompt,
  appended in order — never re-sent, split, or reordered.

Ask before a feature: does it change what pi records or sends? If yes, find another way.

## Naming

No blanket prefixes; short concrete names. Targets are `Core`, `Client`,
`ClientTests` (not `PiCore`/`PiMacApp`); types are concrete (`ProcessController`,
`SandboxSettings`), not prefixed to sound generic. `pi` appears only where code
talks to the binary or its RPC (`pi --mode rpc`, `PiExecutable.resolve()`,
`~/.pi`, `get_messages`). Wire types keep pi's protocol names (`AgentMessage`,
`ContentBlock`, …). User-visible framing is "agent"/"session"/"transcript"; the
app is titled "uni03C0".

## Working in this repo

- `project.yml` drives `xcodegen`; regenerate after adding/removing files:
  `xcodegen generate`.
- Build/launch: `./run.sh`.
- **Core stays AppKit-free**; height measurement and all rendering live in
  Client.
- Concurrency defaults in `project.yml`: `Core = nonisolated`,
  `Client = MainActor`, Swift 6 strict concurrency.

## Running tests (inside the sandbox)

- **Core/ClientTests:** `swift test --disable-sandbox` from the repo root. The
  committed `Package.swift` is a test harness (ignored by xcodegen/xcodebuild).
  `--filter <SuiteName>` runs one suite; `rm -rf .build` if a build looks stale.
- **RenderingTests:** `scripts/run-rendering-tests.sh` (`TEST_FILTER=<substr>`
  for a subset). **Do not "fix" this stub route** — under Swift 6
  `-default-isolation MainActor`, the real XCTest target cannot compile the
  renderer sources' `XCTestCase` overrides; the script uses a stub `XCTest`
  module plus `swiftc`.
- **CoordinatorTests:** `scripts/run-coordinator-tests.sh`
  (`TEST_FILTER=<substr>` for a subset).
- `--disable-sandbox` is required (SPM's manifest `sandbox-exec` is denied).
  xcodebuild works only from a terminal; if package resolution fails in the
  sandbox, run `./run.sh` once in the terminal.

Writing tests: use `RenderTestHelper` in `RenderingTests/TestHelpers.swift`; keep
`TranscriptText.measuredHeight` equal to the cell's layout-manager height (pass
the **same** parameters to `configure` and `measuredHeight`). Tests never spawn a
real `pi` or hit a live model.

---

## Sandbox internals (non-obvious; do not undo)

- **Mechanism.** The app does not sandbox the child from outside —
  `sandbox_apply(profile, pid)` sandboxes the *caller* when `task_for_pid`
  fails (verified). The bundled `SandboxLauncher` calls `sandbox_init` on itself
  and `execv`s the agent; the sandbox survives exec and is inherited by
  grandchildren. Fail-closed: a failed `sandbox_init` exits non-zero with the
  error on stderr.
- **Policy source of truth:** `SandboxPolicy.source(...)`. Read it before
  changing paths. Pieces that must stay, each because it was a real failure:
  - temp in **both** symlink and literal spellings (`/tmp` and `/private/tmp`);
  - `path-ancestors` for every allowed subtree (`realpathSync` lstats each component);
  - the dyld-support rules (verbatim from Apple's profile; dyld aborts without
    them);
  - `system-mac-syscall` (SwiftPM applies its own nested `sandbox-exec`);
  - general Mach IPC (dynamic service names), POSIX sem/shm (Python
    multiprocessing), IOKit GPU/IOSurface (wgpu/Metal);
  - `(target same-sandbox)` signal targets, or killing the session's own
    children fails with EPERM;
  - loopback-only network in both directions (proxy reachable; local test
    servers can bind).
- **Network** is loopback-only both ways; the host whitelist is enforced by
  `WhitelistProxy` (CONNECT + absolute-URI). macOS 26's profile language accepts
  only `*`/`localhost` as network hosts, so the proxy is the only egress.
- Denials are unified-log only; `log show`, `dtruss`, and `lldb` attach are
  blocked inside the sandbox, and `DYLD_INSERT_LIBRARIES` is refused on hardened
  binaries. Working probes: `ls`, `stat`, `kill -0`, `mdfind`, `mdutil`,
  `ioreg`, `otool -L`/`nm -u`/`strings`. The policy's deny rules carry
  `(with message …)`; the operator can run (unsandboxed) `log show --last 10m
  --predicate 'eventMessage CONTAINS "uni03C0 sandbox"'` — ask them for an
  exact denial.
- Policy edits take effect only for new sessions after a rebuild + restart.

### Sandbox gotchas (each cost a real failure)

- **Not every failure is the sandbox — check the machine.** e.g. `/usr/bin/java`
  "Unable to locate a Java Runtime" is Spotlight catalog discovery
  (`JavaLaunching.framework`) with indexing disabled; set `JAVA_HOME` to the
  JDK's `Contents/Home`.
- **xcodebuild package resolution also needs the git-config reads** — SPM shells
  out to git, so a denied `~/.gitconfig` fails the whole build.
- **Python `multiprocessing` needs POSIX IPC** (`ipc-posix-sem`/`ipc-posix-shm`),
  or `Lock()`/`SharedMemory` raise `Operation not permitted`.

---

## Renderer lessons (macOS 26 — hard-won, do not relearn)

- **Never** use `paragraphSpacingBefore`/`paragraphSpacing` for block
  separation: on this SDK they inflate **every line fragment** of a multi-line
  paragraph (verified). `MarkdownText` uses explicit empty spacer lines.
- **Soft breaks parse to a SPACE, not `\n`.** `AttributedString(markdown:)` emits
  an intra-paragraph newline as a `.softBreak` run whose text is a space; re-emit
  a real `\n` for soft and hard (`.lineBreak`) breaks or multi-line prose collapses.
- **`AttributedString(markdown:)` has no table extension.** `MarkdownText` detects
  GFM header + delimiter rows (never inside a fence) and renders tab-stop lines in
  the row's one attributed string, so the measurement invariant holds. Use
  `NSTextTab`s at column edges; space padding drifts, and a leading stop at 0 is
  skipped, so add a leading tab only when column 1 is not left-aligned. Keep the
  no-`|` fast path on the streaming hot path.
- **Row-height under-measure clips the TOP.** The text view is flipped but the
  row is not, so a too-tall text view overflows **upward**; and measuring at
  `tableView.bounds.width` (which includes the ~32pt scroller gutter) over-reports,
  rendering the row short. Measure at the table column width (`rowWidth(in:)`) and
  convert layout-manager rects with `textView.convert(rect, to: row)`.
- **Load-bearing invariant:** `TranscriptText.measuredHeight` (`boundingRect`,
  `.usesFontLeading`) must equal the cell's layout-manager height; same usable
  width (container − 2×8 padding) and same insets. Keep tests asserting it.
- **`NSTextAttachmentViewProvider` is not exposed in Swift on this SDK.**
  Interactive elements use `NSTextAttachmentCell` (sized from `cellSize`); the
  chrome is overlay views positioned per code-block range.

---

## Transcript (do not break)

`TranscriptStore` (Core, off-main) owns the full history; `SessionViewModel`
(main) is a thin command/UI shim; `Coordinator` (main) renders only a
`[windowStart, windowEnd)` window. SwiftUI never reads entries; updates flow
store → coordinator → `NSTableView`.

Rules:

- Streaming is append-only and batched (`StreamingRefreshGate`, at most every
  0.25s, plus the first chunk and the settle).
- Follow is sticky; sending a prompt (or steering flush) jumps to the tail, and
  direction comes from scroll position / content-below, not row indices. History
  loads in compounding blocks and is evictable when scrolled back down; the store
  keeps everything, so a later scroll-up re-materializes with no RPC.
- A stream ending in `error`/`aborted`/`length` gets a red error row below the
  partial message; preflight/process failures get a banner above the prompt.
- Search runs off the main actor in batches applied on main; highlight refreshes
  are coalesced and applied with selective `reloadData(forRowIndexes:)`.
- Zero per-delta render work when occluded/minimized/hidden or the page is
  inactive; on return, one catch-up pass.
- Tool cards are created at `toolcall_end` (RPC strips the cumulative `message`
  from `toolcall_delta`), so no placeholder names and `tool_execution_*` matches
  by real id. Edits render a `TextDiff` diff; errors always show.
- Heights are cached per session (`heightsBySession`), keyed by `(id, width)`;
  settled rows are pre-measured off-main and stored on one main-actor hop.

Failed fixes (each saturated the main thread; do not re-introduce):

- Replacing the whole text storage every batch instead of the append-only
  `applyAttributedString` delta.
- Clearing the height cache on session switch, or pre-measuring rows already
  cached for the same tag+width (a rebind re-offers the whole window).
- Serving `heightOfRow` with a fresh full measure of growing text.
- A streaming crossfade that doesn't settle to the built string's colors:
  superseded batches must be settled, the last step must restore the captured
  color object (semantic colors are not opaque), and the fade must never dim
  below a legible floor / must interpolate to each run's own alpha.
- Letting a cell render taller than its row. The cell is authoritative — compare
  against `rect(ofRow:)` and schedule the coalesced height re-query
  (`scheduleHeightRequery`); `noteHeightOfRows` is illegal inside the table's own
  view/height request.
- Letting the settle search stop at the gate's last-batched id instead of
  `renderedStreamingRowID` (the row the cells actually show streaming).

---

## Session pages & the Changes viewer (do not break)

The conversation and Changes pages stay mounted and swap by visibility — never
rebuild the transcript for Changes.

Rules:

- A page switch is a visibility flip (opacity + hit-testing), never a rebuild:
  transcript has **no `.id`** and is rebound; Changes is `.id`-keyed per tab.
- The inactive page does zero work, gated by `pageActive` — no file IO, no diff
  loading, no highlighting.
- Changed files + stats via `GitStatus.classify` (one batched `git diff
  --numstat`), off-main; `DiffLoader` diffs, a `path` event reloads that file only.
- The store advances only on `GitStatus.didChangeNotification` (a `git commit`
  emits none); a tab switch only re-counts the badge and re-applies the cache.
- The viewer is ONE `CodePaneContainer` (scroll view + code view + ruler +
  edit-map scroller) over every file's diff in path order, each opened by a
  header band. A file renders only its changed runs + 3 context lines
  (`DiffPlan`, Core); each unchanged gap collapses to ONE expand control
  revealing a compounding block from both edges — never the contiguous
  first-change→last-change span. Built PLAIN off-main (`DiffDocumentBuilder`);
  colors go only to the VISIBLE `codeLineRanges` (`DiffHighlighter`, off-main,
  120ms gate). `sizeThatFits` fills the slot; a copy tags the `CodeReference`
  to the FILE via the section's canonical path.
- Header bands paint full-width in `ReadOnlyCodeTextView.drawBackground`, never
  a `.backgroundColor` attribute. The scroller IS the edit map
  (`EditMarkerScroller`): green/red ticks at rendered changed-line fractions.
- Cmd+Up / Cmd+Down jump between changed-line runs (`DiffEditCycler`, Core),
  anchored at the viewport top like the transcript's user-message cycle.
- A tab switch commits the selected-tab frame before the incoming session's
  rebind: `Coordinator.beginSwitch(to:)` blanks a first visit behind an AppKit
  spinner and defers `rebind` one run-loop turn.
- Search (`CodeSearchModel`) scans the whole viewer buffer and re-runs on expansion.
- `pi-file://` links reveal the file only when it is in the changeset (unchanged
  → dead), at the named line; a pre-document reveal defers to the next build.
- Diff egress uses the interleaved view (removed lines inline in red), not
  added-lines-only; spinners are AppKit `SpinnerView`, never a SwiftUI one.
- New `NSEvent` window monitors: use a NONISOLATED `@Sendable` closure handing
  off via `MainActor.assumeIsolated`; an inferred `@MainActor` closure crashes in
  `swift_getObjectType`.

Failed fixes (do not re-introduce):

- A first-change→last-change contiguous window (renders the whole file when
  changes sit far apart); collapse the gaps into hunks.
- Rendering only added lines, so a deletion-only change looked uncolored.
- Rebuilding the viewer document on every scroll tick/tab switch, or loading
  diffs on main.
- Highlighting the whole diff, or on the main thread: color only the visible range.
- `sizeToFit` without `allowsNonContiguousLayout`: full-document layout is seconds.
