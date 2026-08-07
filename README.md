# PiNative — native macOS client for the pi coding agent

A lightweight macOS client for the [pi coding agent](https://github.com/earendil-works/pi).
It spawns `pi --mode rpc` as a subprocess and renders the conversation natively
instead of running the terminal TUI. The point: a smooth, low-CPU way to work
with pi.

## Features

- **Native transcript.** A hand-rolled `NSTableView` that stays fast no matter
  how long the conversation is — rendering cost is tied to what's on screen,
  not to history size.
  - Opens long sessions instantly, positioned at the newest messages.
  - Scrolling down is instant (measured heights are kept in memory).
  - Scrolling up loads older history in growing chunks with a small spinner,
    until the whole conversation is in memory.
  - Streaming replies flow smoothly without bouncing, and you can scroll up to
    read while a turn is in flight (the view stops auto-following the moment
    you do).
- **One pi subprocess per project window**, cwd = the project directory.
- **Prompt bar** with Tab path completion (Shift+Return for a newline).
- **Toolbar menus**: reload the session from disk, switch model, set thinking
  level, resume a recent session (plus a full-history sheet).
- **Projects menu** and a menu-bar quick-prompt launcher.
- **Resumes where you left off** — opens in the last selected project folder.

## Stack

- **PiCore** (framework): `PiProcessController` actor on
  [`swift-subprocess`](https://github.com/swiftlang/swift-subprocess), manual
  LF-only JSONL framing, RPC frame decoding, an off-main `TranscriptStore` that
  folds the event stream into rows, session listing, path completion. No AppKit.
- **PiMacApp** (app): SwiftUI shell; the AppKit transcript
  (`NSViewRepresentable` + `NSTableView` + a `Coordinator` that renders a
  windowed slice of the store); AppKit prompt bar; toolbar menus.
- **PiTests** (unit-test bundle): unit tests for framing, request encoding, and
  transcript-store folding, plus live-pi integration tests.

See `AGENTS.md` for the full architecture write-up.

## Requirements

- macOS 26 (Tahoe), Xcode 26.x.
- `pi` / `node` on PATH (global npm install) — the app spawns the same binary
  the TUI uses; nothing is bundled.
- Auth is already set up in the terminal (`ANTHROPIC_API_KEY` / etc.); the app
  inherits it via the environment.

## Build & run from the repo

```bash
# Quickest: generate the project, build, and launch the app
./run.sh

# Or by hand:
xcodegen generate                     # project.yml -> PiNative.xcodeproj
open PiNative.xcodeproj               # run the PiMacApp scheme
```

Headless build + launch:

```bash
xcodebuild -project PiNative.xcodeproj -scheme PiMacApp -configuration Debug build
open "$(find ~/Library/Developer/Xcode/DerivedData/PiNative-*/Build/Products/Debug -maxdepth 1 -name PiMacApp.app)"
```

Tests (unit + integration; integration spawns a real pi and skips if it's not
installed):

```bash
xcodebuild -project PiNative.xcodeproj -scheme PiTests test
```

## Usage

- **Startup**: opens the last project you selected, or a picker if you've never
  chosen one. A window spawns its pi subprocess only once a project is open.
- **Prompt bar**: type a prompt, Return sends, Shift+Return = newline. Input is
  disabled while a turn is in flight. `Tab` completes paths against the local
  filesystem; multiple matches show a list (Tab/↑/↓ cycle, Return commits, Esc
  dismisses).
- **Toolbar**: Reload (re-reads the session from disk without restarting the
  process), Model and Thinking menus, Resume (recent sessions +
  "View Full History…").
- **Menu bar** (terminal icon): quick-prompt launcher.

## Verified against pi 0.84.1

Empirical corrections to the protocol assumptions:

| Assumed | Reality |
|---|---|
| `prompt` with `"prompt"` key | `{"type":"prompt","message":"..."}` |
| `switch_session` with `"path"` | `{"type":"switch_session","sessionPath":"..."}` |
| `ready` frame at startup | none — the process is immediately ready |
| `set_thinking_level` key | `{"type":"set_thinking_level","level":"low"}` |

Session-format notes: tool results may arrive as separate messages with
`role: "toolResult"` carrying `toolCallId`/`toolName`/`isError`; assistant
tool-call blocks use `type: "toolCall"` with an `arguments` object (string JSON
on some providers — the decoder handles both).

## Known scope cuts

- No auth handling, no bundling of node/pi, no packaging/signing/notarization.
- Slash commands other than what the native menus expose are not surfaced.
- Seatbelt sandboxing of the pi subprocess is not implemented.
- `toolcall_*` deltas (assistant content streaming) are not rendered
  separately; tool-call cards render from `tool_execution_*` events.
