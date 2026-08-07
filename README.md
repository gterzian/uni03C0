# uni03C0 — native macOS client for the pi coding agent

> π (low p) = π (pi, uni03C0)

A lightweight macOS client for the [pi coding agent](https://github.com/earendil-works/pi).
It spawns `pi --mode rpc` as a subprocess and renders the conversation natively
instead of running the terminal TUI. The point: a smooth, low-CPU way to work
with agents.

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
- **Zero rendering off-screen.** When the window is occluded, minimized, or the
  app is hidden, the transcript does no per-tick work at all; it catches up in
  one pass when you come back.
- **Context length % in the status bar** under the prompt input, refreshed when
  a turn settles.
- **Model and thinking level pick right next to the input** at the bottom of
  the window. A new session starts on **DeepSeek V4 Flash** with **max**
  thinking.
- **One pi subprocess per project window**, cwd = the project directory.
- **Prompt bar** with Tab path completion (Shift+Return for a newline).
- **Toolbar menus**: reload the session from disk, resume a recent session
  (plus a full-history sheet).
- **Projects menu** and a menu-bar quick-prompt launcher.
- **Resumes where you left off** — opens in the last selected project folder.

## Stack

- **Core** (framework): `ProcessController` actor on
  [`swift-subprocess`](https://github.com/swiftlang/swift-subprocess), manual
  LF-only JSONL framing, RPC frame decoding, an off-main `TranscriptStore` that
  folds the event stream into rows, session listing, path completion. No AppKit.
- **Client** (app): SwiftUI shell; the AppKit transcript
  (`NSViewRepresentable` + `NSTableView` + a `Coordinator` that renders a
  windowed slice of the store); AppKit prompt bar; bottom status bar.
- **ClientTests** (unit-test bundle): deterministic unit tests for framing,
  request encoding, and transcript-store folding, plus mock-based response
  decoding built on documented pi RPC behavior. Nothing spawns a real `pi`
  process or hits a live model.

## Requirements

- macOS 26 (Tahoe), Xcode 26.x.
- `pi` / `node` on PATH (global npm install) — the app spawns the same binary
  the TUI uses; nothing is bundled.
- Auth is already set up in the terminal; the app
  inherits it via the environment.

## Build & run from the repo

```bash
# Quickest: generate the project, build, and launch the app
./run.sh

# Or by hand:
xcodegen generate                     # project.yml -> Client.xcodeproj
open Client.xcodeproj            # run the Client scheme
```

Headless build + launch:

```bash
xcodebuild -project Client.xcodeproj -scheme Client -configuration Debug build
open "$(find ~/Library/Developer/Xcode/DerivedData/Client-*/Build/Products/Debug -maxdepth 1 -name Client.app)"
```

Tests:

```bash
xcodebuild -project Client.xcodeproj -scheme ClientTests test
```

## Usage

- **Startup**: opens the last project you selected, or a picker if you've never
  chosen one. A window spawns its pi subprocess only once a project is open.
  A new session begins by default on DeepSeek V4 Flash with max thinking.
- **Prompt bar**: type a prompt, Return sends, Shift+Return = newline. Input is
  disabled while a turn is in flight. `Tab` completes paths against the local
  filesystem; multiple matches show a list (Tab/↑/↓ cycle, Return commits, Esc
  dismisses).
- **Status bar** (under the prompt): context-window usage % on the left; the
  model and thinking-level pickers on the right.
- **Toolbar**: Reload (re-reads the session from disk without restarting the
  process), Resume (recent sessions + "View Full History…").
- **Menu bar** (terminal icon): quick-prompt launcher.

