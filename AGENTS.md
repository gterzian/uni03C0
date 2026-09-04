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

## The two non-negotiable properties

Every change must preserve both; the rest of this document details the
invariants that keep them true.

1. **Fast, responsive, non-blocking UI.** Rendering cost scales with the
   *visible* rows, never with the context size or message size; the main
   thread never does full-CoreText work on the streaming or session-switch hot
   paths, and no interaction waits on a synchronous re-measure of off-screen
   content. The load-bearing invariants live in *The transcript design* below
   (append-only streaming text storage, per-session height cache, batched
   refresh, off-main folding, windowed/evictable view).
2. **Sandbox.** Every agent subprocess runs under a default-deny Seatbelt
   policy; the loopback whitelist proxy is the agent's *only* internet egress,
   and denials fail closed — never silently bypassed. Nothing may loosen the
   policy, add an egress path, or hide a denial. The policy scaffold and its
   failure modes live in the *Sandbox* section.

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

### Empirical notes (macOS 26)

Confirmed by real failures while building the app, running xcodebuild/SPM, and
running the formal-web end-of-task verification (WPT, TLA+ traces) inside the
sandbox. These are the sandbox's failed fixes — the policy rules above exist
because of them.

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
  cover it, verified). **The in-sandbox way to build and test is the SwiftPM
  harness: `swift test --disable-sandbox` from the repo root** (see *Tests →
  Running* below) — `--disable-sandbox` skips SPM's own manifest sandbox, so
  no Seatbelt policy rule is involved at all. `xcodebuild` remains a
  terminal-only workflow: when its build fails with "Could not resolve
  package dependencies: sandbox-exec: sandbox_apply: Operation not
  permitted", the fix is to run `./run.sh` (or `xcodebuild`) once in the
  terminal to refresh the resolution, then the same build succeeds in the
  sandbox (the build then skips "Resolve Package Graph" and compiles from
  the cached DerivedData `SourcePackages`).
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
  breaks, the load-bearing measurement invariant (rendered height ==
  measured height), the append-only streaming storage regressions
  (`StreamingStorageTests`) and the streaming crossfade
  (`StreamingFadeTests`). Run via `xcodebuild -scheme RenderingTests
  test`; in the sandbox via `scripts/run-rendering-tests.sh` (plain `swiftc` +
  the stub XCTest module, `TEST_FILTER=<substring>` for a subset).
- **CoordinatorTests** (unit-test bundle, XCTest, `MainActor`): end-to-end
  tests for the transcript `Coordinator`'s keyboard navigation — the
  Cmd+Up/Down user-message cycle, its scroll/focus/follow effects, and
  older-history materialization — driven through a REAL offscreen
  `NSTableView` + `NSScrollView` with a REAL `TranscriptStore` folded from
  RPC frames. The target compiles `TranscriptView.swift` + the renderer/
  measurement sources directly (the same trick as RenderingTests) and links
  the real Core framework. `SessionViewModel` is a member-compatible stand-in
  (the real one spawns `pi --mode rpc` at init; tests never spawn pi) — keep
  `CoordinatorTests/SessionViewModelStub.swift` in sync with what
  `TranscriptView.swift` touches. The cycle decision itself lives in
  `TranscriptCycler` (Core) and is covered by ClientTests; the coordinator
  tests prove the view does what the decision says (landed message anchored
  at the viewport top, clamped near the tail, focus taken unless the find
  bar is up). The key monitors (`NSEvent.addLocalMonitorForEvents`) stay
  thin wiring — they need a key window, which tests can't fake headlessly.
  Run from a terminal via `xcodebuild -scheme CoordinatorTests test`; in the
  sandbox via `scripts/run-coordinator-tests.sh` (swiftc + stub XCTest
  against the harness-built Core module).

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

  **Tool-call timeout.** When the limit is enabled, a tool call that runs
  longer than the configured `ToolTimeoutSettings` is aborted automatically:
  the timer starts on `tool_execution_start`, is cancelled on
  `tool_execution_end`, and each tool gets its own fresh limit. The assistant
  itself is NOT limited — long thinking / answer generation, and even many
  short tool calls in a row, are fine; only a single tool that runs too long
  is cut off. It aborts via the same `.abort()` command as the Stop button, so
  an abort surfaces pi's own "Operation aborted" row in the transcript AND a
  banner above the prompt bar explaining it was the timeout. The limit is read
  LIVE at tool-call start (see `ToolTimeoutSettings`).
- `TranscriptEntry` / `TranscriptEntryKind` — the row model (user message,
  assistant message with thinking, tool call card).
- `ToolCardExpansion` / `HeightCache` — the per-card expand registry and the
  (id, width) → height cache; pure data, moved into Core so both are
  unit-testable from `ClientTests` (which links Core only). The height cache
  is lock-guarded and `@unchecked Sendable`, its thread-safety exercised by
  `HeightCacheTests`; the coordinator mutates it on the main thread and never
  hands it across a task boundary — the off-main pre-measurer works on
  explicit `Sendable` value structs (`RowMeasureSpec` in, `RowMeasurement`
  out, see `Client/Views/RowMeasurement.swift`), and the results are stored
  into the right session's cache (resolved by key) on a main-actor hop. The
  lock stays as insurance against accidental concurrent use.
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
- `ToolTimeoutSettings` — the configurable tool-call timeout (default
  10 minutes, off when disabled). This is a runtime *behavior*, so unlike the
  sandbox settings / RPC endpoint it is read LIVE at the start of each tool
  call (changing it takes effect on the next tool call; a running tool keeps
  the limit it started with). The timer bounds ONE tool's execution window
  (`tool_execution_start` → `tool_execution_end`) — the assistant itself is
  never limited, so a turn may run indefinitely as long as no single tool runs
  too long. It aborts the operation when a tool exceeds the limit.
- `SandboxPolicy` — builds the Seatbelt policy text (project + dev paths +
  dyld-support + path-ancestors + loopback-only network).
- `WhitelistProxy` — the loopback HTTP proxy (CONNECT + absolute-URI) that
  enforces the host whitelist; the agent's sole internet egress.

### Client

- `MainWindowView` / `SessionTabsView` — the app's single window, tabbed:
  one live session per tab, all sharing the same sandbox settings
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

  **Windowed-paste safety rules** (each one is a past or latent crash):
  - **No storage mutation inside the text system or a layout pass.** A huge
    paste is captured in `shouldChangeTextIn` and applied on the next
    run-loop turn (`applyHugePaste`); the scroll-driven window slide is
    deferred out of the `boundsDidChangeNotification` observer the same way
    (`slideScheduled`). Mutating `NSTextStorage` reentrantly inside those
    callbacks desyncs the layout manager, which crashes later in
    NSLayoutManager's `_replaceElements` during an unrelated layout pass
    (a window resize / bar shrink) — the crash signature seen in the field.
  - **A windowed paste is per-session state.** The representable's NSView and
    coordinator are reused across tab switches; `sessionID` detects a switch
    and `prepareForSessionSwitch` drops the previous session's paste (its
    `pasteActive` would disable the new session's input and its store would
    submit on Enter) and forces the new draft in, bypassing the
    first-responder draft sync (which would mirror the old text upward).
  - **Aborting the paste works from anywhere.** Ctrl+C is handled by a
    global key monitor (like Esc), not just the text view's keyDown — the
    input keeps focus while disabled, so a text-view-only keyDown would miss
    Ctrl+C whenever focus is elsewhere. Esc (turn abort) also discards an
    active windowed
    paste; Ctrl+C discards it without touching the agent turn. Both go
    through `abortWindowedPasteIfAny`, which empties the input, exits
    windowed mode, and reports the height reset — a paste that stays
    windowed silently keeps its store and submits on Enter.
  - **Every discard is undoable (⌘Z).** `PromptTextView` vends a real
    per-instance undo manager (`NSTextView`'s own `undoManager` is nil by
    default, so nothing in the input was undoable before — not even typing,
    Cmd+Z was a no-op). An accidental Ctrl+C / ✕ / Esc-with-paste is never
    destructive: `discardInput` snapshots the input state FIRST and registers
    it as an undo operation, so Cmd+Z restores it exactly — an ordinary
    draft as text, a windowed paste in FULL windowed mode (store + window +
    viewport position, spinner + ✕ back). The restore registers its own
    inverse so Cmd+Shift+Z redoes the clear, and a transient top-right
    "⌘Z to undo" hint (click-through, auto-hidden on the next edit or after
    ~4s) makes the recovery discoverable. AppKit declares no public
    `undo:`/`redo:` responder action — not even stock NSTextViews answer the
    Edit menu's nil-targeted Undo/Redo items, so they used to auto-disable —
    hence `PromptTextView` implements `undo:`/`redo:` plus both validation
    overrides itself: while the input is the first responder the Edit-menu
    items resolve to it, enable/disable from `canUndo`/`canRedo`, and perform
    the same undo/redo as the keyboard (see `PromptInputView.swift`). The
    ⌘Z / ⇧⌘Z LOCAL KEY MONITOR (like the Esc/Ctrl+C ones) remains the
    primary key path: it undoes / redoes the input's own manager only while
    the input is the first
    responder, and passes the event through otherwise (no double-firing with
    menu routing — the monitor runs before key equivalents). Three invariants
    keep the undo stack honest: NSTextView coalesces keystrokes into one undo
    group until it breaks, so `discardInput` calls `breakUndoCoalescing()`
    first — a discard landing INSIDE the open typing group would undo typed
    characters together with the restore (the typing inverse then deletes
    from restored text by stale ranges); and the stack is cleared on submit
    (the text was sent, Cmd+Z must not resurrect it into a re-send), on
    session switch (`prepareForSessionSwitch` — undo must never cross
    sessions), and when a windowed paste begins (`beginWindowedPaste` — the
    old text's typing-undo ops carry stale ranges that would corrupt the
    windowed slice).
- `FontSettings` / `FontSizeCommands` — app-wide conversation font size
  (View → Font Size menu, persisted). `TranscriptText` and the prompt bar
  read it; the transcript coordinator observes the change, clears every
  session's cached heights, and re-measures, so heights always match the
  rendered font.
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
  it re-engages when they return to the bottom. **Sending a prompt (or a
  queued-steering flush) jumps to the tail** — the moment the user's message
  echoes into the store, the view scrolls to the bottom and re-engages
  following, so the response streams into view.
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
- **Batched find: results stream in, the loop runs off the main actor.**
  `TranscriptStore.search` takes a range; the view model searches the session
  from the TAIL upward in slices of `searchBatchSize`, each slice in its own
  detached task and applied as it lands — the find bar fills in near the
  bottom first (the rows the user can already see) and shows "x of
  ⟨spinner⟩" until the whole session is covered, while cycling works on the
  partial list. Results are presented in REVERSE session order — the
  bottom-most (most recent) match is index 0, so the find bar reads 1/270
  and the search jump lands near the viewport (never yanking up to earlier
  history, which fought the user's own scrolling). Enter/Cmd+G/↑ move to the
  NEXT result in list order (1 → 2 → 3, up the session toward older content);
  Shift+Enter/Shift+Cmd+G/↓ the other way. Cycling never wraps while the
  search is in flight (the partial list is still growing) — it clamps at the
  ends instead. The batch LOOP is
  `nonisolated` — it runs on the search
  task's executor, OFF the main actor — and hops to the main actor once per
  batch, only to apply the results (the apply mutates the match list/current
  index and notifies the coordinator, so it must be on main; nothing else in
  the search is). The main thread never drives the loop and never waits on a
  scan, so scrolling/streaming stay free for the whole search. Rows appended
  while a search runs are not covered by that run (the ranges are snapshotted
  at search start); re-running or the next Enter picks them up. The store
  uses a **reader-writer lock** (`StoreLock`, pthread_rwlock) precisely so
  this works: the batched search scan takes a READ lock, as do the renderer's
  per-tile/scroll reads (`entry(at:)`), so readers never block each other — a
  scan over the tail's huge tool outputs can't freeze scrolling (the first
  batch is the worst offender) — while `apply`/`rebuild` mutations take the
  exclusive WRITE lock and wait for any scan to finish. Highlight refreshes
  are coalesced to one per 0.25s while the search runs, and each refresh is a
  SELECTIVE reload — `reloadData(forRowIndexes:columnIndexes:)` on only the
  rows whose highlight membership, current-match shade, or query changed (a
  full `reloadData` per batch re-typesets every visible row's markdown and
  freezes scrolling); the search completion always flushes, so the final
  highlights are never stale.
- **Smooth streaming (no bounce).** Rows stay full-height (no inner scroll
  views). Streaming text is **batched** by `StreamingRefreshGate` (Core): the
  tail row updates at most every 0.25s (a hard cap, never per character-delta),
  plus immediately on a new message's first chunk and on the streaming→final
  flag flip — and each batched chunk **crossfades in**, so the text
  materializes in word groups instead of popping character by character. The
  crossfade writes colors INTO the shared text storage, so it must always end
  where the string says: a batch superseded before its ~0.3s fade finished is
  **settled** to its final colors (`TextRowView.settlePendingFade`, called from
  `configure` before the new string lands), and the last fade step restores the
  captured color OBJECT rather than `withAlphaComponent(1)`. Both are
  load-bearing — see *Failed fixes*.
  The
  streaming row's height comes from the cell's own layout manager
  (`TextRowView.contentHeight`), which lays out **incrementally** — only the
  newly-appended characters are typeset — never from a fresh CoreText
  `measuredHeight` of the whole growing text (a full re-typeset of a
  newline-heavy message costs hundreds of ms and saturates the main thread at
  the batch rate). The incremental layout depends on `configure`'s
  **append-only text storage** (`TextRowView.applyAttributedString`): each
  batch replaces only the appended tail, so the layout manager's existing line
  fragments survive. Replacing the whole storage per batch, or re-measuring
  the whole message per batch, re-introduces the hot spot — see *Failed fixes*
  below. The height change and the follow-scroll are applied in one atomic
  `CATransaction` so AppKit renders only the final
  state — content flows off the top instead of bouncing. Tool cards stream
  output with the same batching (their cached height is invalidated on every
  update — content grows in place — so the card actually grows as output
  arrives).
- **Arrow-Down jumps to the tail.** The transcript table overrides Down-arrow
  to scroll to the bottom in one step and re-engage following.
- **Height cache.** Keyed by `(id, width)` where `width` is the row's render
  width (`rowWidth`), and **scoped per session**: the coordinator keeps one
  `HeightCache` per `SessionViewModel` (`heightsBySession`, LRU-capped) and
  activates the right one on bind/rebind (`activateSessionCache`). A session
  switch never clears or re-measures — switching back to a visited session
  reuses its cached heights; only rows whose content genuinely changed
  re-measure (the content tag catches that). Same-session reloads reuse the
  cache too; a font-size change is app-wide and clears every session's cache.
  ONE measurement function — `TranscriptText.measuredHeight` — feeds both
  `heightOfRow` (on cache miss, via `entry.measuredHeight`) and the
  pre-measurer (via `RowMeasurer`), so the two paths agree by construction.
  Settled
  rows' heights are ALSO seeded **off the main thread**: when rows enter the
  materialized window (appends, history prepends, post-reload windows,
  font-size changes), the coordinator builds a `RowMeasureSpec` per row on
  the main actor — content + cache tag + session key, all plain `Sendable`
  values, so the worker never touches the row model, a `HeightCache`, or
  view state — and schedules a background task that runs the SAME
  `measuredHeight` (markdown parse + CoreText `boundingRect` — both
  thread-safe; `NSFontManager` is avoided in favor of descriptor trait
  synthesis) and stores the results into the session's cache (resolved by
  key) via one
  main-actor hop, so `heightOfRow` degrades to an O(1) lookup for rows the
  background pass reached before the table asked. A font-size change bumps a
  generation counter that discards in-flight results measured at the old
  size. Streaming
  rows carry a **content tag** (text/thinking/streaming-flag fingerprint):
  `heightOfRow` serves whatever the renderer seeded (the table must match the
  cell, not the store's newer unrendered content) and
  `updateVisibleCell`/`makeCell` re-measure only on a genuine content change.
  Streaming rows are seeded from the cell's incremental layout
  (`contentHeight` + the 2pt slack, so the settled-row `measuredHeight` lands
  on the same height — no jump at settle); the full CoreText measure runs once
  per message (on the settle refresh, then cached). Tool-card heights are
  invalidated on every content update (they grow in place) and measured by
  ONE reused `NSHostingController` (a per-query controller built a fresh
  SwiftUI graph per measurement — the `StackLayout`/`ViewLayoutEngine` cost in
  samples); the card cell also skips the SwiftUI `rootView` swap on a
  scroll re-entry whose card content is identical. Text rows are
  invalidated on genuine change and when their rows are evicted from the
  window (so the cache tracks the window, not the conversation). Rows are
  layer-backed (`wantsLayer` on the table and cells; the flat-fill overlay
  views opt into `canDrawConcurrently`), so each cell's raster lives in its
  own backing store instead of repainting through the window's shared store
  on every delta.
- **Cells are pre-sized at creation.** `makeCell` frames every cell to its
  row's measured height before returning it — NSTableView does not reliably
  re-frame a cell whose height changed (the width follows via autoresizing,
  the height does not), so a cell recycled from a shorter row would otherwise
  lay out at the stale short height and clip the message's top.
- **Whoever renders a row owns telling the table its height changed.** The
  CELL is authoritative: `makeCell` renders the store's CURRENT content, while
  `heightOfRow` may just have served a height measured for OLDER content (a
  streaming row materialized between two batched refreshes — the documented
  "the table must match the cell" rule cuts the other way here). The row is
  then shorter than the text it renders, and since the text view is
  bottom-anchored in the (non-flipped) cell, the overflow leaves the row
  UPWARD: the first line is painted behind the row above — the "top cut off"
  symptom, persisting until some reload re-queried the height (the user-visible
  tell: **switching tabs and back healed it**, because `reloadData` re-queries
  every row). `noteHeightOfRows` is illegal inside the table's own view/height
  request, so `makeCell` compares its height against `rect(ofRow:)` and, on a
  mismatch, defers a coalesced re-query (`scheduleHeightRequery` →
  `flushHeightRequery`, which re-verifies each row before noting it). Any new
  code path that renders a row's content must either note the height itself or
  schedule the re-query.
- **The settle must find the row the CELLS show streaming, not the row the
  gate last batched.** While the user is scrolled up nothing renders, so
  `StreamingRefreshGate.lastStreamedID` is never advanced; in a multi-message
  turn (thinking → tool call → more thinking, no user echo in between) it then
  points at an EARLIER message than the one the cells actually show streaming.
  The backward search for "the streaming row" stopped at that stale row, so
  the newer one never got its final render: stale half-streamed text, an
  immortal blinking caret, and a row height measured for the half-streamed
  text (the clip above). The coordinator therefore tracks
  `renderedStreamingRowID` — what a cell was last configured with as streaming
  — and the search matches it too.
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

### Failed fixes (do not re-introduce)

Each of these saturated the main thread in `sample` profiles; the current code
works around them, and reintroducing any of them breaks the fast-UI property.

- **Replacing the whole text storage on every streaming batch.**
  `TextRowView.configure` used to call `setAttributedString` on every 0.25s
  batch: the layout manager treated every character as a hole and re-typeset
  the entire (single-paragraph) thinking block from scratch — a fresh
  CTTypesetter plus a full GPOS kerning pass — per batch (~80% of the main
  thread in a `sample` of a streaming thinking block). The fix is the
  append-only `applyAttributedString`: replace only the delta (guarded by a
  shared-prefix text + attribute check), full-replace only when the prefix
  genuinely re-styles (a code fence or `**` closing mid-stream, a font-size
  change). Search highlights are re-applied from scratch every configure (the
  previous query's backdrops are dropped first — search colors only, leaving
  inline-code backgrounds alone) because the incremental path preserves the
  prefix's attributes.
- **Clearing the height cache on session switch.** `resetToTail` used to
  `heights.clear()` on every rebind, so `reloadData()` re-measured every row
  synchronously on the main thread — full markdown parse + `boundingRect`
  glyph encode per row, 100% of the main thread for ~2s (the tab-switch
  beachball in `sample`). The fix is the per-session `heightsBySession`.
  Nothing on a tab switch may re-measure the window synchronously on the main
  thread.
- **Re-measuring streaming rows on every `heightOfRow` / re-typesetting per
  delta.** The table queries `heightOfRow` on every tile and scroll; serving
  each query with a fresh full measure of the (possibly huge) growing text
  pegged the main thread at 100% (a DeepSeek "high" thinking stream and a
  newline-heavy markdown stream both reproduced it). Streaming heights come
  from the cell's own incremental layout, seeded into the cache, and the
  refresh is batched at 0.25s — see the Smooth streaming bullet.

- **Letting the streaming crossfade write colors that nothing restores.** The
  per-batch fade-in dims the appended range and steps it back over ~0.3s. Two
  ways that drifted, both healed by a tab switch (a full re-render) and
  therefore reported as "weird formatting only while streaming":
  a batch superseded before its fade finished had its remaining steps skipped
  by the generation guard, and since the incremental storage path keeps the
  prefix's colors (`.foregroundColor` is excluded from the prefix equality
  check on purpose), that text stayed frozen at whatever alpha it had reached —
  every superseded batch adding another, lighter region, i.e. a growing
  washed-out block mid-message; and the fade's last step wrote
  `color.withAlphaComponent(1)`, which is NOT the color it captured (the
  semantic colors are not opaque — `labelColor` is alpha ~0.85), so every
  faded-in run ended slightly darker than its surroundings and read as stray
  bold. `settlePendingFade` + restoring the captured color object fix both;
  `RenderingTests/StreamingFadeTests.swift` pins them. Anything new that
  animates attributes in the row's storage must settle to the built string's
  values.

Validation notes: a `sample` during a long streaming turn should show the main
thread mostly idle in the event loop (the per-tick work is confined to the
streaming row); a large-context session should scroll smoothly and open
instantly; streaming while the window is occluded should do no render work.

## Rendering lessons (macOS 26)

Failed fixes / hard-won behavior of the AppKit renderer. Check these before
touching the markdown renderer or the transcript rows.

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

Three deterministic bundles (no pi process, no network, no live model):

- **ClientTests** — Core-only logic: framing, request encoding, response
  decoding, store folding, diff, sandbox policy, the streaming-refresh
  regression (`StreamingRefreshGateTests` replays a realistic delta stream
  through the real store + gate and asserts the refresh count is bounded by
  the batch interval — never per delta), and the user-message cycle decision
  (`TranscriptCyclerTests`). Links Core only.
- **RenderingTests** — the AppKit renderer. Compiles the renderer sources
  (Client/Views/MarkdownText.swift, TextRowView.swift, CodeCopyButton.swift,
  Client/Accessibility/DisplayOptions.swift, Client/Support/FontSettings.swift)
  directly into the bundle, because ClientTests cannot link the Client target
  and Core must stay AppKit-free. Default actor isolation `MainActor` (the
  renderer sources assume the Client target's default).
- **CoordinatorTests** — the transcript `Coordinator`. Compiles
  `TranscriptView.swift` + the renderer/measurement sources against the REAL
  Core framework and drives an offscreen `NSTableView` with a real store:
  the Cmd+Up/Down cycle, scroll geometry (top-anchored vs near-tail clamped),
  follow state, key focus after a jump, older-history materialization, and the
  **row-height/clipping invariant** (`assertNoClipping`: no materialized row
  may render more content than its row rect is tall) across a streaming turn,
  a window resize, and a message that streams + settles while the user is
  scrolled up. `SessionViewModel` is stubbed (spawns pi at init — see
  CoordinatorTests/SessionViewModelStub.swift). Run from a terminal via
  `xcodebuild -scheme CoordinatorTests test`; in the sandbox via
  `scripts/run-coordinator-tests.sh` (`TEST_FILTER=<substring>` runs a subset).
  Notes for writing these: the clip view's bounds-change notification is
  COALESCED (posted when idle), so a programmatic scroll needs a run-loop spin
  before the coordinator sees it; a never-shown `NSWindow` reads as occluded,
  so rows must be materialized before the window is created; and a folded user
  message legitimately re-engages following (as sending a prompt does), so a
  "scrolled up" scenario must turn following off AFTER the echo.

### Running inside the sandbox (the normal case for an agent)

**`swift test --disable-sandbox` from the repo root** builds and runs
ClientTests — the real Core, the real XCTest overlay (auto-discovery,
async test methods), no stubs, no xcodebuild:

```
swift test --disable-sandbox
# one suite only, e.g. the search tests:
swift test --disable-sandbox --filter SessionViewModelSearchTests
```

How this works and what can go wrong:

- The committed `Package.swift` is a test harness: a `Core` target over the
  real sources plus a `ClientTests` test target, depending on
  swift-subprocess / swift-system by URL. It is **ignored by `xcodegen` and
  `xcodebuild`** — the Xcode project is unchanged by it.
- `--disable-sandbox` is required: without it SPM evaluates the manifest
  inside its own `sandbox-exec`, which the Seatbelt policy denies
  (`sandbox_apply: Operation not permitted`).
- The first run resolves the dependencies (from the local SCM cache
  populated by `./run.sh`, or over the app's whitelist proxy — GitHub is on
  the default allowlist) and writes `Package.resolved`. Later runs build
  incrementally in `.build/` (gitignored). If a build looks stale, `rm -rf
  .build` and re-run.
- Both `ClientTests` and the new `SessionViewModelSearchTests` are plain
  `XCTestCase` subclasses (the view-model ones `@MainActor`, since
  `SessionViewModel` is). XCTest discovers `test*` methods automatically,
  including `async` ones — no runner is needed.

### Running from a terminal (xcodebuild only works there)

```
xcodebuild -scheme ClientTests test
xcodebuild -scheme RenderingTests test
```

### RenderingTests in the sandbox (swiftc + stub — do not "fix")

**`scripts/run-rendering-tests.sh`** runs them (`TEST_FILTER=<substring>` for a
subset). It reuses the coordinator harness's stub XCTest + FontSettings stub
(`CoordinatorTests/Harness/`) and GENERATES the runner from the test sources on
every run, so adding a test file needs no harness edit.

Why the stub route is the only one: RenderingTests are deliberately NOT in the `Package.swift` harness, and the
Xcode `RenderingTests` target cannot build either — under Swift 6 language
mode, `-default-isolation MainActor` (which the renderer sources require)
makes the `XCTestCase` subclasses' `override func setUp()` and the inherited
`init()`s MainActor-isolated, and the compiler rejects that against real
XCTest's nonisolated ObjC declarations (even an explicit `@MainActor
override` fails; verified). The working route is plain `swiftc` with a stub
`XCTest` module compiled under the *same* default isolation, so the override
isolation check passes by construction.

What the script does (the essential pieces, if it ever needs rebuilding):

- the stub `XCTest` module is compiled with `-default-isolation MainActor` so
  its `setUp`/`init` match the renderer's isolation;
- `FontSettings` is stubbed because the `@Observable` macro's plugin server is
  blocked in the sandbox;
- `Core` is linked from the SwiftPM harness build (`swift test
  --disable-sandbox` once, for `TextRowView`'s `import Core`);
- the generated runner calls every `test*` method explicitly (pure-Swift
  methods are not ObjC-visible), with `setUp`/`tearDown` around each, and
  instantiates `NSApplication.shared` first — without an app instance
  `NSButton.performClick` sends no action and the copy-button tests fail
  spuriously.

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
  ranges, rects) over internals, and keep the regressions covered: no
  paragraphSpacingBefore/After on blocks (per-line inflation), soft breaks
  preserved (newline collapse), and the streaming-storage behavior
  (`StreamingStorageTests`: a pure append keeps the prefix's text and
  attributes, closing markdown / a font-size change re-styles the prefix,
  a changed search query drops stale highlights) and the streaming crossfade
  (`StreamingFadeTests`: a superseded batch settles to its final colors, a
  settled message has no dim text, a completed fade lands on the captured
  color and is never forced opaque).
- Nothing here spins the run loop unless it says so, so the fade's async steps
  cannot interleave — keep new tests deterministic the same way (spin
  explicitly with `RunLoop.current.run(until:)` when a timer must fire).

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

