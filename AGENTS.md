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
  `ProcessController`, errors are `ProcessError`, client settings are
  `SandboxSettings`. Don't reach for a `Core`/`Client`/`Agent` prefix just because a
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

The app follows pi's own defaults: a session starts exactly as it would in
the terminal TUI. pi applies its settings (`defaultProvider` /
`defaultModel` / `defaultThinkingLevel` in `~/.pi/agent/settings.json`) at
spawn, and the app reads the live model + thinking level from `get_state`
and events. Neither the model nor the thinking level is ever forced or
auto-changed by the app — a session starts exactly as it would in the
terminal TUI, so the requests it produces (and the provider-side prompt
cache) are identical whether the session is driven from the app or the
TUI. The thinking-level menu offers exactly the levels pi reports via
`get_available_thinking_levels`, matching the TUI's selector.

The RPC wire protocol is the single source of truth — the app holds nothing in
parallel that it doesn't derive from the event stream.

## Stable session data (provider prompt cache)

The provider caches the session's prompt prefix, so the request bytes must
stay identical whether the session is driven from the app or the TUI. pi owns
the session data; the app is a read-only mirror. **No future code change may
alter what pi records or what it sends to the provider.** The rules that keep
this true:

- **The app never writes session data.** pi writes `~/.pi/agent/sessions/…`;
the app only reads it, and only through pi's read-only RPCs (`get_state`,
`get_messages`, `get_session_stats`, `get_available_models`,
`get_available_thinking_levels`). `TranscriptStore` is a local mirror of the
event stream: it folds frames and rebuilds from `get_messages`, and it must
never send, reorder, or rewrite anything.
- **Only the commands pi's TUI sends, for the same user actions.** A new
state-changing RPC (`prompt`, `set_model`, `set_thinking_level`, `abort`,
`switch_session`) needs the same justification the TUI has for it. The model
and thinking level are never forced or auto-changed; a session starts exactly
as pi's own defaults would.
- **A prompt is the user's text, verbatim.** The only transformation is
whitespace trimming (pi's TUI trims identically). No re-sends, no retries, no
duplicates — `ProcessController.send` writes each request exactly once. The
full pasted text is what is submitted; windowed pastes are a view-only
optimization.
- **Rendering caches are pure UI.** `HeightCache`, tool-card expansion, text
measurement, fonts, diffs — in-memory layout data, never serialized, sent, or
written, and nothing derived from them may feed back into what pi records.
- **The one deliberate deviation stays deterministic and append-only.**
Queued steering is flushed as ONE combined prompt (the TUI records each
queued message separately). Each flush appends exactly one new user message
in order — never re-sends, never splits, never reorders.

When adding a feature, ask: does this change what pi would record or send for
the same user actions? If yes, it breaks the stable prefix — find another way.

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

Settings are snapshotted when an agent process spawns: per session — the
initial window session and each additional **tab** (all tabs share the same
sandbox settings; each spawns its own process with a fresh snapshot). A
running agent keeps its sandbox until its session ends; new sessions pick up
the current settings. Resume/Reload reuse the running process and never
re-apply settings.

### Mechanism — Strategy A via a launcher

The app does **not** apply the sandbox to the child from outside:
`sandbox_apply(profile, pid)` silently sandboxes the *caller* when
`task_for_pid` fails (verified — it sandboxed the app itself). Instead, a
tiny C executable (`SandboxLauncher`, in the app bundle) calls `sandbox_init`
on **itself** and then `execv`s the agent; the sandbox survives exec and is
inherited by everything the agent spawns. Fail-closed: if `sandbox_init`
fails the launcher exits non-zero with the error on stderr.

### The policy

Built by `SandboxPolicy.source(...)` in Core. The **user-configurable** part
comes from `SandboxSettings` (the Settings page): the dev directories and the
allowed hosts. Everything else is a **fixed scaffold**, always present:

- **Projects root (read + write)** — the top-level working folder; every
  project inside it is the agent's workspace.
- **`~/.pi` (read + write)** — pi's sessions, config, auth.
- **Dev directories (read + write)** — the user's list: toolchain homes,
  caches, frameworks, Xcode, TLA+ Toolbox, …
- **Temp (read + write)** — `/tmp`, `/private/tmp`, `/private/var/tmp` (both
  the literal and the symlink spelling — seatbelt does not resolve the `/tmp`
  symlink, so tools writing to `/tmp` literally need that entry too).
- **System (read-only + executable mapping)** — `/usr/local`, `/opt/homebrew`,
  `/usr/bin`, `/bin`, `/usr/lib`, `/System/Library`, `/Library/Frameworks`,
  `/Library/Java` (JVM runtimes — the TLA+ verification runs TLC via system
  java), `/dev`.
- **macOS dev-tooling (read)** — the `/var` symlink root (xcode-select),
  `/etc` configs, `/usr/share`, `/usr/libexec`, `/Library/Apple`, and
  Preferences (the Xcode license check reads `com.apple.dt.Xcode.plist`
  directly, not via cfprefsd).
- **Git configuration (read-only)** — `~/.gitconfig`, `~/.gitattributes`,
  `~/.gitignore_global`, `~/.git-credentials`, `~/.config/git`, `~/.ssh`.
  Without these every git command fails ("unable to access '~/.gitconfig':
  Operation not permitted") — and SwiftPM package resolution needs them too.
- **Mach syscalls (allowed)** — the sandbox module's syscalls are permitted so
  tools like SwiftPM can apply their *own* child sandboxes (`sandbox-exec`);
  they can never loosen the outer profile. (Apple's own restrictive profiles
  allow all mac syscalls.)
- **Mach IPC (allowed in general)** — `mach-lookup` + `mach-register` are not
  name-whitelisted: tools the agent runs use dynamic service names
  (ipc-channel bootstrap names are random per connection,
  `org.rust-lang.ipc-channel.<rand>`; XPC services are launchd-registered),
  so a name whitelist is impossible. Privileged services (tccd, securityd, …)
  still check the caller's entitlements, which the agent process does not
  have.
- **POSIX IPC (allowed in general)** — `ipc-posix-sem` + `ipc-posix-shm`:
  Python's multiprocessing uses named semaphores and shared memory, so
  `multiprocessing.Lock()`/`SharedMemory` fail with "Operation not
  permitted" without them.
- **GPU / Metal (IOKit)** — wgpu and other graphics stacks enumerate adapters
  and create devices through IOKit GPU services (AGX on Apple Silicon, Intel/
  AMD on Intel) plus IOSurface; without `iokit-open-*` rules adapter
  enumeration finds nothing ("metal found no adapters"). Mirrors Apple's
  `com.apple.gputoolsserviced.sb`.
- **Processes** — fork/exec, process info; signal targets are self,
  same-sandbox processes (the session's own children), and other processes,
  so `pkill`/kill work both on the session's own processes and on leftovers
  from earlier sessions. (Verified: `(target others)` alone denies kill on
  the session's own children.)
- **dyld-support rules** — Apple's cryptex graft points + special
  syscalls/fcntls, taken verbatim from
  `/System/Library/Sandbox/Profiles/dyld-support.sb`; without them dyld
  aborts at startup.
- **`path-ancestors` rules** — for every allowed subtree, because node's
  `realpathSync` lstats each path component and a denied lstat of an ancestor
  aborts startup with EPERM.

Network is **loopback-only, both directions**: the Seatbelt profile language
on macOS 26 accepts only `*` and `localhost` as network hosts (no IPs, no
hostnames), so the domain whitelist is enforced by `WhitelistProxy` — a
loopback HTTP proxy in the app (CONNECT + absolute-URI) that is the agent's
sole internet egress. Outbound on `localhost` is allowed so the proxy is
reachable; inbound on `localhost` is allowed so local test servers (WPT
runners, WebDriver, TLA+ tracing) can bind ports inside the sandbox. The
agent's environment carries `HTTP(S)_PROXY`/`ALL_PROXY`, `NO_PROXY`,
`NODE_OPTIONS=--use-env-proxy` (node's undici only honors proxy env with this
flag) and `GIT_CONFIG_COUNT/KEY/VALUE` (git ignores proxy env). Anything that
ignores the proxy env simply fails to connect — fail-closed, no bypass.

Saved settings lists from an older app version automatically gain any new
default entries once (one-shot migration in `SandboxSettings.load()`); after
that, user edits win wholesale.

### Empirical notes (verified on macOS 26, 2026-08)

Everything above was confirmed by real failures during this session's work
(building the app, running xcodebuild/SPM, and running the formal-web
end-of-task verification — WPT, TLA+ traces — inside the sandbox).

- **Diagnosing a denial**: the sandbox logs denials only to the unified log,
  and `log show`/`log stream`, `dtruss`, and `lldb` attach are all blocked
  inside the sandbox (no root, no debugserver attach). What works: direct
  probes (`ls`, `stat`, `kill -0`, `mdfind`, `mdutil`, `/usr/sbin/ioreg`,
  `otool -L`/`nm -u`/`strings` on the tool's binaries). `DYLD_INSERT_LIBRARIES`
  interposition is refused on hardened Apple system binaries. The policy's
  deny rules carry `(with message …)` explanations — every denial logs a
  "uni03C0 sandbox …" line to the unified log under
  `com.apple.sandbox.reporting:violation`, next to the kernel's own
  `Sandbox: <proc> deny(<n>) <op>` line. The agent never sees these: the
  messages are unified-log-only (there is no stderr surface for denials on
  macOS), so the operator reads them via `log show --last 10m --predicate
  'eventMessage CONTAINS "uni03C0 sandbox"'` (must be run unsandboxed) and
  tells the agent; the agent's own copy of this knowledge lives here.
- **xcode/SPM builds do NOT work from inside the sandbox.** `xcodebuild`
  resolving Swift packages runs SPM, which wraps manifest execution in
  `sandbox-exec`; the sandbox denies the nested `sandbox_apply` (EPERM, and
  no policy rule can lift it — even `(allow system-mac-syscall)` does not
  cover it, verified). Building from the sandbox works only when the package
  graph is already resolved: the build then skips "Resolve Package Graph"
  and compiles from the cached DerivedData `SourcePackages`. When a build
  fails with "Could not resolve package dependencies: sandbox-exec:
  sandbox_apply: Operation not permitted", the fix is to run `./run.sh`
  (or `xcodebuild`) once in the terminal to refresh the resolution, then the
  same build succeeds in the sandbox.
- **Not every failure is the sandbox — check the machine first.**
  `java_home`/`/usr/bin/java` reporting "Unable to locate a Java Runtime"
  looked sandbox-caused but was not: JVM discovery goes through the Spotlight
  catalog (`JavaLaunching.framework`), and this machine has Spotlight
  indexing disabled (`mdutil -s /` → "Indexing and searching disabled"), so
  discovery fails unsandboxed too. `JAVA_HOME` set to the JDK's `Contents/Home`
  makes `/usr/bin/java` work inside the sandbox (verified).
- **Signal targets are context-scoped.** `(allow signal (target others))`
  covers processes outside the sandbox context but NOT the session's own
  children — kill on a child fails with EPERM until `(target same-sandbox)`
  is added. Verified: `kill -0` on an unsandboxed process succeeds, on the
  agent's own child it is denied.
- **SPM's package resolution runs `sandbox-exec`** (its own nested sandbox)
  and fails with "sandbox_apply: Operation not permitted" unless the outer
  profile allows `system-mac-syscall`. This also surfaced as the reason
  xcodebuild could not resolve Swift packages inside the sandbox.
- **`xcodebuild` package resolution also needs the git-config reads** — SPM
  shells out to git to clone dependencies, so a denied `~/.gitconfig` fails
  the whole build, not just `git status`.
- **Python `multiprocessing` needs POSIX IPC** (`ipc-posix-sem` for
  `sem_open`, `ipc-posix-shm` for `shm_open`) — without them `Lock()` and
  `SharedMemory` raise `PermissionError: Operation not permitted`.
- **Local test servers bind loopback ports inside the sandbox** — the WPT
  runner and the TLA+ tracing embedder bind 127.0.0.1; `network-inbound` on
  `localhost` was missing and surfaced as "failed to allocate local port:
  Operation not permitted".
- **Policy edits take effect only for new sessions after an app rebuild +
  restart** (Resume/Reload reuse the running process — see above). Iterating
  on the policy is one probe → edit → rebuild/restart per round trip; the
  probes in the first bullet make each round trip decisive.

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
- **RenderingTests** (unit-test bundle, XCTest, `MainActor`): unit tests for
  the AppKit rendering layer (`MarkdownText`, `TranscriptText`, `TextRowView`,
  `CodeCopyButton`). Because the renderer lives in the Client target (which
  ClientTests cannot link — it links Core only), this target compiles the
  renderer sources directly alongside the tests. Covers inline/block styling,
  code-block ranges and cards/copy buttons, block spacing, soft/hard line
  breaks, and the load-bearing measurement invariant (rendered height ==
  measured height). Run via `xcodebuild -scheme RenderingTests test`; can also
  be run with plain `swiftc` + a tiny XCTest shim when the sandbox blocks
  package resolution.

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
- `ToolCardExpansion` / `HeightCache` — the per-card expand registry and the
  (id, width) → height cache; pure data, moved into Core so both are
  unit-testable from `ClientTests` (which links Core only).
- `TextDiff` / `EditToolArgs` — the pure line diff (prefix/suffix trim +
  bounded LCS, GitHub removed-then-added ordering) and the edit-tool
  arguments decoder behind the tool card's red/green diff view.
- `StreamedPaste` — pure head/tail + chunk splitting for streaming very large
  pastes into the prompt input (surrogate-safe boundaries).
- `SessionListing` — recent-session discovery from `~/.pi/agent/sessions`.
- `PathCompletion` — filesystem path tab-completion for the prompt bar.
- `SandboxSettings` — the persisted settings (dev directories, allowed
  hosts); defaults cover macOS development (cargo, rustup, nvm, Xcode, …)
  plus the model provider.
- `RPCEndpointSettings` — the persisted agent RPC endpoint: the local pi
  executable spawned as `pi --mode rpc`. Defaults to `PiExecutable.resolve()`
  (pi on PATH); the Settings page lets the user point at a different binary.
- `SandboxPolicy` — builds the Seatbelt policy text (project + dev paths +
  dyld-support + path-ancestors + loopback-only network).
- `WhitelistProxy` — the loopback HTTP proxy (CONNECT + absolute-URI) that
  enforces the host whitelist; the agent's sole internet egress.

### Client

- `MainWindowView` / `SessionTabsView` — the app's **single window**, now
  tabbed: one live session per tab, all sharing the same sandbox settings
  (each session snapshots them at spawn). The window opens on the **last
  selected project folder** (`AppState.shared.lastProject`, persisted to
  UserDefaults) as the first tab, or the picker if no projects folder has
  ever been chosen (first run also shows the sandbox setup fields). The
  tab bar shows every session's folder name plus its live status — the same
  spinner/stop icons as the toolbar's Stop button — so background tabs show
  whether they're idle or working; a **"+"** button starts a new session in
  a folder of the user's choice (NSOpenPanel). Only the active tab renders
  its transcript; background tabs keep folding their event stream off-main.
  The toolbar (top right) carries the active session's controls: Stop,
  Reload, the **model** + **thinking level** pickers (current choice shown
  beside the icon, a "choose model/thinking level" prompt until one is
  set), and Resume. The live status readout (context %, model, thinking
  level) sits in the prompt bar, not the toolbar. Sending a prompt is
  disabled until both a model and a thinking level have been chosen.
- `SessionTab` — one tab's state: owns its `SessionViewModel` plus the
  per-session UI bits (recent sessions, history sheet, prompt draft).
- `SessionContent` / `SessionToolbar` — the shared session UI: transcript +
  prompt bar + queued-steering banner, and the toolbar items, both bound to
  whichever session owns them.
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
  an edit button (appends it to whatever is already in the input — a quick
  push-back that coexists with an in-flight streamed paste, which keeps
  pushing to the front; Return then sends the combined input) and a delete
  button. A live status readout (context %, model, thinking level) sits in
  very light gray at the bottom-right inside the bar, below a reserved strip
  so text can never scroll under it. **Esc aborts the in-flight turn from
  anywhere in the window** and then focuses the input so typing can start
  immediately: a local key monitor falls back to the text view's own Esc
  handling when the input has focus, and defers to open dropdowns/sheets (a
  visible popup-menu-level window closes on Esc instead of aborting). The
  bar is **resizable**: a drag handle above it pins the height (clamped
  64…400); until dragged it auto-grows with the text and snaps back to the
  minimum on send. **Large pastes become a windowed paste** (`StreamedPaste`
  in Core): the full pasted text lives in a store (plain data, never laid
  out), the text view holds only a bounded ~64KB window starting at the
  bottom of the paste, and the input is disabled (editing a slice would
  desync it from the store) with a spinner + ✕ visible. Scrolling slides the
  window toward the head or the tail with a re-anchored viewport, so layout
  stays bounded regardless of paste size — a multi-megabyte paste never
  blocks the main thread and the conversation keeps scrolling. Enter submits
  the full store.
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
  `SandboxSettings`; applied per session at spawn. The Settings page also
  edits the agent RPC endpoint (`RPCEndpointSettings`).

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
- **Older history loads in compounding blocks, and is evictable once the
  user scrolls back down.** `windowStart` decreases as older history is
  prepended (scroll up; the block doubles each time, capped), and *increases
  again* when the user scrolls back down and the rows above a buffer (a few
  viewports) are no longer needed — those rows leave the table and their
  cached heights are dropped. The **store keeps the full conversation**, so a
  later scroll-up re-materializes them instantly (no RPC round trip); only
  the view's window and height cache are pruned. The streaming tail (the
  front of the window) is **never** popped.
- **Sticky follow, no jumps.** Following is on by default. The moment the user
  scrolls *up*, following disengages so streaming doesn't drag them back down;
  it re-engages when they return to the bottom. Sending a message (or a
  queued-steering flush) **never jumps the scroll** — the view stays exactly
  where the user left it, even while the response streams in off-screen.
  Direction is detected from the scroll position (whether content remains
  below the viewport), **not** from row indices — a tall streaming row fills
  the viewport, so the last visible row can still be the tail even when
  scrolled up.
- **Stream failures surface in the transcript.** When an LLM stream ends with
  `stopReason` `error`/`aborted`/`length` (network failures, provider errors,
  truncation), the store appends a red error row below the partial assistant
  message — the same wording as pi's TUI (`assistant-message.js`). Send
  preflight failures (auth, rejected prompts) and a dead agent process surface
  as an error banner above the prompt bar instead of being silently swallowed.
- **Smooth streaming (no bounce).** Rows stay full-height (no inner scroll
  views). Streaming text is **batched** — the tail row updates at most every
  0.25s or once ~20 new characters accumulate (a few words), never per
  character-delta — and each batched chunk **crossfades in**, so the text
  materializes in word groups instead of popping character by character. The
  streaming row's height is re-measured on each batched refresh via the same
  `measuredHeight` function the authoritative path uses (the fast path and the
  fallback can never disagree). The height change and the follow-scroll are
  applied in one atomic `CATransaction` so AppKit renders only the final
  state — content flows off the top instead of bouncing. Tool cards stream
  output with the same batching (their cached height is invalidated on every
  update — content grows in place — so the card actually grows as output
  arrives).
- **Arrow-Down jumps to the tail.** The transcript table overrides Down-arrow
  to scroll to the bottom in one step and re-engage following.
- **Height cache.** Keyed by `(id, width)` where `width` is the row's render
  width (`rowWidth`). ONE measurement function —
  `entry.measuredHeight(forWidth:)` — feeds both `heightOfRow` (on cache
  miss) and the visible-cell refresh (`updateVisibleCell`), so the two paths
  agree by construction; the fast path stores that measured value rather than
  seeding from the cell's own layout. Tool-card heights are invalidated on
  every content update (they grow in place); text rows are invalidated on
  genuine change, and `resetToTail` clears the whole cache on session switch
  (ids are only unique within a session).
- **Cells are pre-sized at creation.** `makeCell` frames every cell to its
  row's measured height before returning it — NSTableView does not reliably
  re-frame a cell whose height changed (the width follows via autoresizing,
  the height does not), so a cell recycled from a shorter row would otherwise
  lay out at the stale short height and clip the message's top.
- **Tool cards show their content, expandable.** One card per call: pi's RPC
  strips the cumulative `message` from `message_update`, so `toolcall_start`/
  `toolcall_delta` carry only a `contentIndex` — the card is created at
  `toolcall_end` from the completed call block (real id + name + args), so it
  never shows a placeholder "tool" name and `tool_execution_*` always matches
  by the real id (no duplicate card; the result is appended into the same
  card as output arrives). Output previews at 30 lines (args at 2), with a
  chevron button in the card header that expands to the full content (the
  row re-measures via a shared expansion registry). **Edit calls render a
  GitHub-style diff** (removed lines red, added lines green) from the raw
  `edits[]` arguments via `TextDiff`, instead of the raw JSON; the successful
  tool output (a diff/patch string) is omitted as redundant, while errors
  always show. User messages are highlighted light-blue to stand out from
  assistant replies.
- **Zero rendering when off-screen.** When the window is occluded, minimized,
  or the app is hidden, the coordinator does **no** per-delta work: `applyModelChanges`
  bails and only sets `needsCatchUp`. The store keeps folding off-main; on return
  to the foreground one catch-up pass materializes the tail and refreshes the
  streaming row. (Visibility = occlusion state + not minimized + not hidden.)
- **Context % in the prompt-bar readout.** pi pushes no context event, so
  `SessionViewModel` polls `get_session_stats` every 2s while a turn streams
  (plus on settle and after load/reload) and surfaces `contextUsage.percent`
  in the status readout at the bottom-right inside the prompt input.
- **Per-turn cache rate under the final answer.** Every LLM call's usage
  (`input`/`cacheRead`/`cacheWrite`, carried on `message_end` and in
  `get_messages`) is folded into the `TranscriptStore`'s per-turn accumulator;
  the row ending the turn shows `⚡ cache N%` — the **turn average** across all
  steps (tool-use calls included), not just the final request. Below 99% it
  renders orange; a step that re-billed more than 20k previously-cached tokens
  (pi's own `cache-stats.js` miss math: `min(prevPrompt, prompt) − cacheRead`)
  flags the turn `· large miss`. Detection is cross-turn: the first request of
  a turn compares against the previous turn's last request, so an idle gap
  (cache eviction) between turns is caught. Aborted turns (`EMPTY_USAGE`, all
  zeros) never attach a rate. The line is entry-level data (not part of the
  row kind) so it flows through the same height cache / measurement as the
  text, and precision adapts so a 99.97% hit never rounds to a false 100%.
- **Session switch** is a `generation` bump → full `reloadData()` positioned at
  the tail, behind an in-app `isReloading` spinner (never the system beach-ball).

Validation notes: a `sample` during a long streaming turn should show the main
thread mostly idle in the event loop (the per-tick work is confined to the
streaming row); a large-context session should scroll smoothly and open
instantly; streaming while the window is occluded should do no render work.

## Rendering lessons (verified on macOS 26, 2026-08)

These cost real debugging time this session; check them before touching the
markdown renderer or the transcript rows.

- **`paragraphSpacingBefore`/`paragraphSpacing` inflate EVERY line fragment**
  of a multi-line paragraph on this SDK — a 16pt line becomes 30pt with 8/6
  spacing, applied per line, not once at the paragraph boundary (verified in
  isolation). Never use them for block separation. `MarkdownText` separates
  blocks with explicit spacer lines (an empty line whose font height equals
  the gap).
- **Soft breaks parse to a SPACE, not `\n`.** `AttributedString(markdown:)`
  emits a single newline inside a paragraph as a dedicated run with
  `.softBreak` intent whose text is a space (hard breaks — two trailing
  spaces — are `.lineBreak` runs with `\n`). Re-emit a real `\n` for both,
  or multi-line prose collapses to one line.
- **The text view is flipped; the row is not.** Layout-manager rects
  (`boundingRect`, line fragments) are in the text view's (flipped, top-down)
  container coordinates. Positioning subviews of the row requires
  `textView.convert(rect, to: row)`. Worse: **in a non-flipped cell, a text
  view taller than the row overflows UPWARD — clipping the TOP of the
  message, not the bottom** (the intuitive assumption is backwards). This is
  why the code-card overlay and any row-height under-measure manifest as
  "the top of the message is cut off, as if scrolled down".
- **A row's height must be measured at the width it RENDERS at — the table
  column's width, not `tableView.bounds.width`.** The bounds include the
  scroller gutter (a legacy vertical scroller costs ~32pt), so measuring at
  the bounds width over-reports: the text wraps narrower than measured, the
  row renders short, and the taller text overflows upward — the "top cut
  off" symptom. All height measurement goes through the coordinator's
  `rowWidth(in:)` (the column width), used by `heightOfRow`, `makeCell`, and
  the streaming refresh alike.
- **The load-bearing measurement invariant**: `TranscriptText.measuredHeight`
  (`boundingRect`, `.usesFontLeading`) must equal the cell's layout-manager
  `usedRect` height. Every test that compares them catches clipping/padding
  drift. The text view and the measurement must use the same usable width
  (container width − 2×8 line-fragment padding) and the same insets.
- **`NSTextAttachmentViewProvider` is not exposed in Swift on this SDK.**
  Interactive elements inside text use the cell API (`NSTextAttachmentCell`);
  the layout manager sizes attachments from the `cellSize` property (never
  `cellSize(forBounds:)`). The code-card/copy-button chrome is drawn as
  overlay views instead, positioned from the layout manager per code-block
  range.
- **DeepSeek context caching is best-effort and node-local**: identical
  prompts intermittently miss entirely after short gaps (76s, 3min, 46min
  all observed) and fully recover on the very next request. The app's
  cross-turn "large miss" detection is working as designed — the miss is
  real on the provider side, not an app-data artifact.

## Tests

Two unit-test bundles, both deterministic (no pi process, no network, no
live model):

- **ClientTests** — Core-only logic: framing, request encoding, response
  decoding, store folding, diff, sandbox policy. Links Core only.
- **RenderingTests** — the AppKit renderer. Compiles the renderer sources
  (Client/Views/MarkdownText.swift, TextRowView.swift, CodeCopyButton.swift,
  Client/Accessibility/DisplayOptions.swift, Client/Support/FontSettings.swift)
  directly into the bundle, because ClientTests cannot link the Client target
  and Core must stay AppKit-free. Default actor isolation `MainActor` (the
  renderer sources assume the Client target's default).

### Running

From a terminal (package resolution cannot run inside the sandbox):

```
xcodebuild -scheme ClientTests test
xcodebuild -scheme RenderingTests test
```

Inside the sandbox, xcodebuild's "Resolve Package Graph" step fails (SPM's
`sandbox-exec`), so run the rendering tests with plain `swiftc` instead — the
same files, driven by a tiny XCTest shim:

```
# build a stub XCTest module + library once (it provides XCTestCase + the
# assertion functions the real test files import)
swiftc -emit-library -module-name XCTest -swift-version 6 \
  -default-isolation MainActor -target arm64-apple-macosx26.0 \
  -emit-module -emit-module-path /tmp/xctest/mod XCTestStub.swift \
  -o /tmp/xctest/libXCTest.dylib
# compile the renderer + tests + a runner into one binary and run it
swiftc -swift-version 6 -default-isolation MainActor \
  -target arm64-apple-macosx26.0 -o /tmp/xctest/rendertests \
  /tmp/xctest/main.swift Client/Views/MarkdownText.swift \
  Client/Views/TextRowView.swift Client/Views/CodeCopyButton.swift \
  Client/Accessibility/DisplayOptions.swift /tmp/Stubs/FontSettings.swift \
  RenderingTests/*.swift -I /tmp/CoreStub -I /tmp/xctest/mod \
  -L /tmp/xctest -lXCTest && DYLD_LIBRARY_PATH=/private/tmp/xctest \
  /tmp/xctest/rendertests
```

(The exact flags live in the shell history / scratch space; the essential
pieces are: the stub `XCTest` module must be compiled with
`-default-isolation MainActor`, `FontSettings` must be stubbed because the
`@Observable` macro's plugin server is blocked in the sandbox, `Core` needs an
empty stub module for TextRowView's `import Core`, and the runner calls every
`test*` method explicitly since pure-Swift methods are not ObjC-visible.)

### Adding a rendering test

- Add a `RenderingTests/SomeThingTests.swift` file — the target's sources are
the whole `RenderingTests` directory, so `xcodegen generate` picks it up
(no project.yml edit).
- Tests are plain `XCTestCase` subclasses on the main actor; use the
  `RenderTestHelper` utilities in `RenderingTests/TestHelpers.swift`
  (attribute extraction, text layout, line pitches, measurement).
- **The load-bearing invariant**: `TranscriptText.measuredHeight`
  (`boundingRect`) must agree with the cell's `contentHeight` (layout
  manager) — keep tests asserting this; it is what catches row-height drift
  (clipping).
- Pass the **same** parameters to `configure` and `measuredHeight` when
  comparing heights (a `cacheHitRate` adds the cache line, ~15pt).
- `TextRowView` exposes internal test hooks (`renderedCodeBlockCount`,
  `renderedCopyButtonCount`, `renderedCodeCardFrame(at:)`,
  `codeBlocksForTesting`, `copyButtonsForTesting`) for the chrome/layout
  tests; add more if a new test needs them.
- Prefer asserting **rendered geometry and attributes** (fonts, traits,
  ranges, rects) over internals, and keep the two historical regressions
  covered: no paragraphSpacingBefore/After on blocks (per-line inflation),
  and soft breaks preserved (newline collapse).

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

_Empty — the copy-button TODO (fenced code blocks in assistant messages) is
implemented via the corner `CodeCopyButton` + card overlay in `TextRowView`
(driven by `MarkdownText`'s reported code-block ranges)._
