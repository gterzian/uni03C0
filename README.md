# uni03C0 — native macOS client for the pi coding agent

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
  - Streaming replies flow smoothly without bouncing: text streams in batched
    word-chunks that crossfade in (never per-character), and you can scroll up
    to read while a turn is in flight (the view stops auto-following the
    moment you do). **Arrow-Down** jumps back to the tail in one step.
  - A pulsing blue caret appears the moment a turn starts — feedback during
    time-to-first-token, before any content has streamed back.
  - Tool calls appear the instant the model starts writing them; output is
    shown (30-line preview) and the whole card expands when you click it.
  - User messages are highlighted light-blue.
- **Zero rendering off-screen.** When the window is occluded, minimized, or the
  app is hidden, the transcript does no per-tick work at all; it catches up in
  one pass when you come back.
- **Toolbar controls** (top right): context-window usage %, Stop, Reload, the
  **model** + **thinking level** pickers (current choice shown beside the icon,
  a "choose model/thinking level" prompt until set), and Resume. Sending is
  disabled until both a model and a thinking level are chosen. A new session
  starts on **DeepSeek V4 Flash** with **max** thinking.
- **One pi subprocess per project window**, cwd = the project directory.
- **Prompt bar** with Tab path completion (Shift+Return for a newline,
  Ctrl+C clears the draft). It stays enabled while a turn is in flight:
  pressing Return during work **queues a steering message** instead of
  sending — the queue (each message editable/deletable in a banner above the
  bar) is flushed as **one combined prompt** when the run settles, never one
  turn per message. If you abort, queued messages are returned to the input.
- **View → Font Size** menu for the conversation font (Smaller/Larger, presets).
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
  windowed slice of the store); AppKit prompt bar; toolbar pickers.
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
# Quickest: generate the project, build, quit any running instance, and launch
./run.sh

# Or by hand:
xcodegen generate                     # project.yml -> Client.xcodeproj
open Client.xcodeproj            # run the Client scheme
```

Headless build + launch:

```bash
xcodebuild -project Client.xcodeproj -scheme Client -configuration Debug build
open "$(find ~/Library/Developer/Xcode/DerivedData/Client-*/Build/Products/Debug -maxdepth 1 -name uni03C0.app)"
```

Tests:

```bash
xcodebuild -project Client.xcodeproj -scheme ClientTests test
```

## Usage

- **Startup**: opens the last project you selected, or a picker if you've never
  chosen one. The picker explains that the chosen folder is the top-level
  folder for all projects the agent can work on (it can be a single project).
  A window spawns its pi subprocess only once a project is open.
- **Prompt bar**: type a prompt, Return sends (or queues steering while the
  agent is working), Shift+Return = newline, Ctrl+C clears the draft. `Tab`
  completes paths against the local filesystem; multiple matches show a list
  (Tab/↑/↓ cycle, Return commits, Esc dismisses).
- **Toolbar** (top right): context %, Stop, Reload, model + thinking-level
  pickers, Resume. The context % refreshes when a turn settles.
- **Menu bar** (terminal icon): quick-prompt launcher.
