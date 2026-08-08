# AGENTS.md

## The one rule

**Never use git except for read operations.**

Allowed (read-only):
- `git status`, `git log`, `git diff`, `git show`, `git blame`, `git grep`, `git ls-files`, `git rev-parse`, `git stash list` (and anything else that does not modify the repository).

Forbidden (anything that writes or changes state):
- `git add`, `git commit`, `git push`, `git pull`, `git fetch`, `git checkout`, `git switch`, `git reset`, `git revert`, `git rebase`, `git merge`, `git cherry-pick`, `git stash` (push/pop/drop), `git tag`, `git branch -m`, `git clean`, `git rm`, `git mv`, `git config` writes, `git init`, `git gc`, `git filter-branch`.

The human owns the repository history. When the user asks to "commit" (or a
commit is needed), that means **suggest a commit message** and let the human
run it — the agent never runs `git commit` or any other write operation
itself.

---

## You are running inside a sandbox

This app runs you (the agent) inside a **Seatbelt sandbox** (default-deny).
Everything you can touch is defined by the user in the app's **Settings**
(app menu → Settings…):

- **Working folder — read + write.** Every project inside the top-level
  folder the user chose. This is your workspace.
- **Additional read/write paths — read + write.** Toolchain homes, caches,
  frameworks, Xcode — whatever the user listed there.
- **`~/.pi` — read + write** (your session data).
- **System directories — read-only** (e.g. `/usr`, `/opt/homebrew`,
  `/System/Library`).
- **Internet — only the domains in "Allowed internet domains"** (subdomains
  included), via a loopback whitelist proxy. Your environment carries
  `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`, `NODE_OPTIONS=--use-env-proxy` and
  git proxy config; any tool that ignores proxy env simply cannot connect.

Everything else is blocked — silently (`EPERM`) or as a connection failure.
**When you hit a permission problem, say so explicitly and tell the user what
to change**, rather than guessing or working around it:

- A file or directory you need is denied → ask the user to add it to
  **"Additional read/write paths"** in Settings, or to move the work inside
  the working folder.
- A host you need to reach fails to connect → ask the user to add its domain
  to **"Allowed internet domains"** in Settings.
- A tool that should use the network fails → check whether it honors the
  proxy environment; if it doesn't, tell the user how it must be configured
  (or that the domain needs whitelisting).

Settings are applied when a new agent process starts; after changing them the
user restarts the app (Resume/Reload reuse the running process and do **not**
re-apply the sandbox). See the Sandbox section under Project design for the
mechanism.

---

# Project design

## What this is

**uni03C0 (Client)** is a native macOS client for the [`pi` coding
agent](https://github.com/earendil-works/pi). It spawns `pi --mode rpc` as a
subprocess and renders the conversation natively (SwiftUI + AppKit) instead of
running the terminal TUI. A SwiftUI shell with one deliberately hand-rolled
AppKit piece: the transcript table.

## Naming: no blanket prefixes

The app is a client for a *coding agent*. Today that agent happens to be
`pi` — the executable the app spawns and the RPC protocol it speaks — but the
app's own concepts are **not** named after pi.

A prefix that's applied to *everything* carries no information and is noise.
Give each component a short, concrete name; don't spray a shared prefix over
unrelated things.

- **Targets/modules are short and unprefixed:** `Core` (framework),
  `Client` (app), `ClientTests`. No `PiCore`/`AgentCore`, no `PiMacApp`.
- **Internal types are concrete, not prefixed:** the process actor is
  `ProcessController`, errors are `ProcessError`, client defaults are
  `Defaults`. Don't reach for a `Core`/`Client`/`Agent` prefix just because a
  name sounds generic — a concrete name is better than a prefixed one.
- **`pi` appears only where the code actually talks to the binary or its
  RPC protocol:** `pi --mode rpc`, `PiExecutable.resolve()`, `~/.pi`,
  `get_messages`, `switch_session`. Saying "send `get_state` to pi" or "the
  pi subprocess" is correct; naming *app* components after pi is not.
- **Protocol types exchanged with pi keep the names pi's protocol uses**
  (`AgentMessage`, `ContentBlock`, `RPCFrame`, `ModelInfo`, …). Those are not
  app concepts — they're the wire format, so they follow its conventions.
- **User-visible framing is neutral** — "agent"/"session"/"transcript" —
  not "pi". The app is titled "uni03C0".

## Defaults

A fresh session starts on the client's chosen model and thinking level
(`Defaults` in `Core`): **DeepSeek V4 Flash** (`deepseek` /
`deepseek-v4-flash`) and **thinking = max**. Applied once at spawn by
`SessionViewModel.applyDefaults()`, so resume/reload never override the user's
choices for a running session.

The RPC wire protocol is the single source of truth — the app holds nothing in
parallel that it doesn't derive from the event stream.

## Sandbox

Every pi subprocess runs inside a **Seatbelt sandbox** (default-deny), built
from two user-editable settings (first-run picker + Settings page):

- **Development directories (read + write)** — toolchain homes, caches,
  frameworks, Xcode. The project folder itself and `~/.pi` are always allowed
  (read+write); system dirs and the dyld cryptexes are fixed scaffold.
- **Allowed internet domains** — the only hosts the agent may reach on the
  internet (subdomains included). Defaults cover the model providers
  (DeepSeek, Anthropic, OpenAI, Gemini), the web-spec sites (`whatwg.org`,
  `w3c.org`, `w3c.github.io`) and the code sources a coding agent needs to
  work (GitHub, crates.io, npm, PyPI, the Go proxy, rustup/node downloads).

Settings are snapshotted when an agent process spawns: **at app startup**
(the app is single-window) or when the menu-bar quick prompt starts one. A
running agent keeps its sandbox until the app restarts. Resume/Reload reuse
the running process and never re-apply settings.

### Mechanism — Strategy A via a launcher

The app does **not** apply the sandbox to the child from outside:
`sandbox_apply(profile, pid)` silently sandboxes the *caller* when
`task_for_pid` fails (verified — it sandboxed the app itself). Instead, a
tiny C executable (`SandboxLauncher`, in the app bundle) calls `sandbox_init`
on **itself** and then `execv`s the agent; the sandbox survives exec and is
inherited by everything the agent spawns. Fail-closed: if `sandbox_init`
fails the launcher exits non-zero with the error on stderr.

### The policy

Built by `SandboxPolicy.source(...)` in Core: the **projects root** (every
project inside it is read+write — the workspace) + `~/.pi` + dev dirs
read/write, temp, system read, processes, IPC — plus the macOS dev-tooling
paths (xcode-select's `/var` symlink, `$TMPDIR` in `/var/folders`,
`/usr/share`|`/usr/libexec`, `/etc`, and Preferences for the Xcode license
check) and two empirically required pieces: Apple's **dyld-support rules**
(cryptex graft points + special syscalls; without them dyld aborts at
startup) and **`path-ancestors` rules** for every allowed subtree (node's
`realpathSync` lstats each component).

Network is **loopback-only**: the Seatbelt profile language on macOS 26
accepts only `*` and `localhost` as network hosts (no IPs, no hostnames), so
the domain whitelist is enforced by `WhitelistProxy` — a loopback HTTP proxy
in the app (CONNECT + absolute-URI) that is the agent's sole egress. The
agent's environment carries `HTTP(S)_PROXY`/`ALL_PROXY`, `NO_PROXY`,
`NODE_OPTIONS=--use-env-proxy` (node's undici only honors proxy env with this
flag) and `GIT_CONFIG_COUNT/KEY/VALUE` (git ignores proxy env). Anything that
ignores the proxy env simply fails to connect — fail-closed, no bypass.

Empirical notes are appended to `../formal-web/scratchpad/sandbox-design.md`
(§10).

## Modules

Three targets (see `project.yml`):

- **Core** (framework, default *nonisolated*): the protocol + process
  layer and the data side of the transcript. No AppKit.
- **SandboxLauncher** (tiny C executable, embedded in the app bundle):
  applies the Seatbelt policy to itself (`sandbox_init`) and `execv`s the
  agent — the only reliable way to sandbox the child (see the Sandbox
  section).
- **Client** (app, default *MainActor*): the SwiftUI shell + AppKit views.
  Display name "uni03C0".
- **ClientTests** (unit-test bundle, XCTest): deterministic unit tests for
  framing/request encoding/store folding, plus mock-based response decoding
  built on documented pi RPC behavior. Tests **never** spawn a real `pi`
  process or hit a live model — pi's behavior is faked from its documented
  protocol. Run via `xcodebuild -scheme ClientTests test`.

Concurrency defaults are set per target in `project.yml`:
`Core = nonisolated`, `Client = MainActor`, both Swift 6 strict
concurrency.

### Core

- `ProcessController` — an actor wrapping
  [`swift-subprocess`](https://github.com/swiftlang/swift-subprocess). Spawns
  `pi --mode rpc` (through the sandbox launcher when sandboxing is on),
  encodes outbound RPC commands, demuxes inbound frames by id
  (`response` frames resolve awaited sends; everything else is yielded on an
  `AsyncThrowingStream`).
- `JSONLFramer` — manual LF-only framing. The stdlib treats U+2028/U+2029 as
  line breaks, which are legal inside JSON strings and would corrupt the
  stream, so framing is hand-rolled.
- `RPCFrame` / `RPCRequest` — the decoded envelope; payloads decode lazily.
- `TranscriptStore` — owns the **full conversation history**, off the main
  thread (lock-guarded, `@unchecked Sendable`). Folds RPC frames into
  `TranscriptEntry` rows and rebuilds the whole list from `get_messages` on
  session switch. It is data-only; it never renders.
- `SessionViewModel` — a thin `@MainActor` shim. Owns the connection, the RPC
  commands (prompt/abort/model/thinking/reload/resume), and the small bits of
  UI state SwiftUI reads (`isStreaming`, `model`, `isReloading`,
  `isFetchingOlder`). It forwards frames to the store off-main and does **not**
  hold the transcript.
- `TranscriptEntry` / `TranscriptEntryKind` — the row model (user message,
  assistant message with thinking, tool call card).
- `SessionListing` — recent-session discovery from `~/.pi/agent/sessions`.
- `PathCompletion` — filesystem path tab-completion for the prompt bar.
- `SandboxSettings` — the persisted settings (dev directories, allowed
  hosts); defaults cover macOS development (cargo, rustup, nvm, Xcode, …)
  plus the model provider.
- `SandboxPolicy` — builds the Seatbelt policy text (project + dev paths +
  dyld-support + path-ancestors + loopback-only network).
- `WhitelistProxy` — the loopback HTTP proxy (CONNECT + absolute-URI) that
  enforces the host whitelist; the agent's sole internet egress.

### Client

- `MainWindowView` / `SessionView` — the app's **single** window (one
  pi process per app; no New Window — switching projects replaces the
  window). On startup it opens the **last selected project folder**
  (`AppState.shared.lastProject`, persisted to UserDefaults), or the picker
  if no projects folder has ever been chosen (first run also shows the
  sandbox setup fields). The toolbar (top right) carries the session
  controls: Stop, Reload, the
  **model** + **thinking level** pickers (current choice shown beside the
  icon, a "choose model/thinking level" prompt until one is set), and Resume.
  The live status readout (context %, model, thinking level) sits in the
  prompt bar, not the toolbar. Sending a prompt is disabled until both a
  model and a thinking level have been chosen.
- `TranscriptView` + `Coordinator` — the `NSTableView` transcript. See the
  transcript section below.
- `SessionStatusBar` — removed. The model + thinking-level pickers live in
  the window toolbar (top edge); the live status readout (context %, model,
  thinking level) sits in very light gray at the bottom-right inside the
  prompt input.
- `TextRowView` / `ToolCallCardView` — cells.
- `TranscriptText` — the single source of truth for styling **and**
  measurement, so measured height exactly matches rendered height.
- `PromptInputView` — AppKit prompt bar with Tab path completion. Enabled
  whenever the session is connected (even while a turn is in flight):
  pressing Return while the agent is working queues a **steering message**
  instead of sending (the whole queue is flushed as ONE combined prompt when
  the turn settles — never one turn per queued message, unlike the TUI). The
  queued-steering banner above the bar lists every queued message, each with
  an edit button (restores it into the input; Return re-queues the edited
  version) and a delete button. A live status readout (context %, model,
  thinking level) sits in very light gray at the bottom-right inside the
  bar. **Esc aborts the in-flight turn from anywhere in the window**: a local
  key monitor falls back to the text view's own Esc handling when the input
  has focus, and defers to open dropdowns/sheets (a visible popup-menu-level
  window closes on Esc instead of aborting).
- `FontSettings` / `FontSizeCommands` — app-wide conversation font size
  (View → Font Size menu, persisted). `TranscriptText` and the prompt bar
  read it; the transcript coordinator observes the change, clears its height
  cache, and re-measures, so heights always match the rendered font.
- `SessionHistorySheet` — unbounded session list.
- `AppState` / `AppStorage` / `AppDelegate` — app-wide state, storage paths,
  and subprocess cleanup on termination (every live child gets EOF on quit).
  `AppDelegate` also enforces the single-window rule (closes duplicate main
  windows).
- `SandboxSettingsModel` / `SandboxSettingsView` — the editable sandbox
  settings: the Settings page (app menu → Settings…, and a Projects-menu
  entry) and the first-run picker fields. Saved to the same
  `SandboxSettings`; applied at app startup.

## The transcript design (the load-bearing part)

The design goal, kept simple: **rendering cost is a function of the visible
rows, never of the context size.** A 600-message session opens and streams
like a two-message one.

Three pieces, each with one job:

1. **`TranscriptStore`** (off-main) owns the whole history. It folds events and
   rebuilds on session switch in a background task. The UI reads it through
   lock-guarded accessors; the store never draws.
2. **`SessionViewModel`** (main) is a thin shim — connection, commands, UI
   state. It forwards each frame to the store via `Task.detached`, yielding
   the main thread so a delta never blocks the UI.
3. **`Coordinator`** (main) renders a window `[windowStart, windowEnd)` of
   store indices. `numberOfRows` is the window size; every cell/height is a
   store lookup. SwiftUI never reads the transcript entries — updates flow
   store → coordinator → `NSTableView` directly.

Behavior details that matter:

- **Append-only reality.** pi's stream is append-only, so a change is always
  "something at the end changed." No index diffing is needed — just a monotonic
  `version` (per tail mutation) and a `generation` (per wholesale rebuild).
- **Tail always streams in.** New rows append via `insertRows` (cheap,
  O(added)); inserting at the end never shifts existing rows, so a scrolled-up
  viewport is untouched.
- **Older history loads in compounding blocks.** `windowStart` only ever
  decreases. When the viewport nears the top of the fetched region, a spinner
  appears above the conversation and a block is prepended; the block size
  doubles each time (capped), so sustained scrolling eventually pulls the whole
  conversation into memory. Fetched rows are **never evicted** — scrolling back
  down reuses cached heights, so it's always fast.
- **Sticky follow.** Following is on by default. The moment the user scrolls
  *up*, following disengages so streaming doesn't drag them back down; it
  re-engages when they return to the bottom. Sending a message always jumps to
  the bottom. Direction is detected from the scroll position (whether content
  remains below the viewport), **not** from row indices — a tall streaming row
  fills the viewport, so the last visible row can still be the tail even when
  scrolled up.
- **Smooth streaming (no bounce).** Rows stay full-height (no inner scroll
  views). Streaming text is **batched** — the tail row updates at most every
  0.25s or once ~20 new characters accumulate (a few words), never per
  character-delta — and each batched chunk **crossfades in**, so the text
  materializes in word groups instead of popping character by character. The
  streaming row's cached height is seeded from the cell's own layout and only
  ever grows (never oscillates). The height change and the follow-scroll are
  applied in one atomic `CATransaction` so AppKit renders only the final
  state — content flows off the top instead of bouncing. Tool cards stream
  output with the same batching (their cached height is invalidated on every
  update — content grows in place — so the card actually grows as output
  arrives).
- **Arrow-Down jumps to the tail.** The transcript table overrides Down-arrow
  to scroll to the bottom in one step and re-engage following.
- **Height cache.** Keyed by `(id, width)`, seeded from the visible cell's
  layout (avoids a duplicate CoreText measure — that was the original 100%-CPU
  hot path). `noteHeightOfRows` queries hit the cache. Tool-card heights are
  invalidated on every content update (they grow in place); text rows are
  seeded from the cell and only invalidated on genuine change.
- **Tool cards show their content, expandable.** One card per call: pi's RPC
  strips the cumulative `message` from `message_update`, so `toolcall_start`/
  `toolcall_delta` carry only a `contentIndex` — the card is created at
  `toolcall_end` from the completed call block (real id + name + args), so it
  never shows a placeholder "tool" name and `tool_execution_*` always matches
  by the real id (no duplicate card; the result is appended into the same
  card as output arrives). Output previews at 30 lines (args at 2), with a
  chevron button in the card header that expands to the full content (the
  row re-measures via a shared expansion registry). User messages are
  highlighted light-blue to stand out from assistant replies.
- **Zero rendering when off-screen.** When the window is occluded, minimized,
  or the app is hidden, the coordinator does **no** per-delta work: `applyModelChanges`
  bails and only sets `needsCatchUp`. The store keeps folding off-main; on return
  to the foreground one catch-up pass materializes the tail and refreshes the
  streaming row. (Visibility = occlusion state + not minimized + not hidden.)
- **Context % in the prompt-bar readout.** pi pushes no context event, so
  `SessionViewModel` polls `get_session_stats` every 2s while a turn streams
  (plus on settle and after load/reload) and surfaces `contextUsage.percent`
  in the status readout at the bottom-right inside the prompt input.
- **Session switch** is a `generation` bump → full `reloadData()` positioned at
  the tail, behind an in-app `isReloading` spinner (never the system beach-ball).

Validation notes: a `sample` during a long streaming turn should show the main
thread mostly idle in the event loop (the per-tick work is confined to the
streaming row); a large-context session should scroll smoothly and open
instantly; streaming while the window is occluded should do no render work.

## Conventions

- `project.yml` drives `xcodegen` — regenerate the project after adding/removing
  files: `xcodegen generate`.
- Keep Core free of AppKit. Height measurement and rendering stay in
  Client.
- Follow the naming rule above: app concepts use `Agent`/`Session`/`Transcript`/
  `Client` stems, never `Pi`; `pi` only appears where the code actually talks
  to the binary or its RPC.
- Build/launch: `./run.sh` (generates the project, builds, opens the app).

## Design docs

- `scratchpad/transcript-architecture.md` — the architecture write-up.
- `scratchpad/transcript-overview.md` — a plain-terms overview.

## TODO

- **Code-block copy button.** Fenced code blocks (```) in assistant messages
  should offer a copy button to grab the whole block, shown only when the
  block is part of the main response (not inside thinking traces).
