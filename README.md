# PiNative — native macOS client for the pi coding agent

A lightweight SwiftUI shell around `pi --mode rpc`. The point: stop the terminal
TUI from hogging CPU. The transcript is the one deliberate AppKit component —
an `NSTableView` with row virtualization, per-row height caching, and explicit
scroll anchoring (see §3.5 of the design).

## Stack

- **PiCore** (static-ish framework): `PiProcessController` actor on Apple's
  [`swift-subprocess`](https://github.com/swiftlang/swift-subprocess)
  (SubprocessFoundation trait, LF-only manual JSONL framing), RPC frame
  decoding, `@Observable` session-state folding, session listing, path
  completion.
- **PiMacApp**: SwiftUI shell; AppKit transcript (`NSViewRepresentable` +
  `NSTableView` + `NSTableViewDiffableDataSource`), AppKit prompt bar
  (`NSTextView`) with Tab path completion, toolbar menus for Model/Thinking/
  Resume, a Reload button, a Projects menu, and a menu-bar quick-prompt window.
- **PiCLI**: headless smoke test of the protocol layer against a live pi.

## Requirements

- macOS 26 (Tahoe), Xcode 26.x.
- `pi` / `node` on PATH (global npm install) — the app spawns the same binary
  the TUI uses; nothing is bundled.
- Auth is already set up in the terminal (`ANTHROPIC_API_KEY` / etc.); the app
  inherits it via the environment.

## Build & run

```bash
xcodegen generate            # project.yml -> PiNative.xcodeproj
open PiNative.xcodeproj      # run the PiMacApp scheme
```

Or headless:

```bash
xcodebuild -project PiNative.xcodeproj -scheme PiMacApp -configuration Debug build
open "$(find ~/Library/Developer/Xcode/DerivedData/PiNative-*/Build/Products/Debug -maxdepth 1 -name PiMacApp.app)"
```

Smoke test (spawns pi, round-trips `get_state`, runs one real prompt):

```bash
xcodebuild -project PiNative.xcodeproj -scheme PiCLI -configuration Debug build
"$(find ~/Library/Developer/Xcode/DerivedData/PiNative-*/Build/Products/Debug -name PiCLI)"
```

## Usage

- **Projects** menu (main menu bar): set the projects root once ("Choose
  Projects Folder…"), then open a project window from the list. Windows are
  per-project: one `pi --mode rpc` subprocess each, cwd = project.
- **Prompt bar**: type a prompt, Return sends (Shift+Return = newline). Input
  is disabled while a turn is in flight. `Tab` completes paths against the
  local filesystem (same cwd the subprocess was spawned with); multiple
  matches show a list — Tab/↑/↓ cycle, Return commits, Esc dismisses.
- **Toolbar**: Reload (get_state → switch_session to the same file — re-reads
  the session from disk without restarting the process), Model and Thinking
  menus (RPC `get_available_models` / `get_available_thinking_levels`), Resume
  (recent `~/.pi/agent/sessions/--<project>--/` files → `switch_session`).
- **Menu bar** (terminal icon): quick-prompt window reusing the same view.

## Verified against pi 0.84.1

Empirical corrections to the design doc:

| Design doc | Reality |
|---|---|
| `prompt` with `"prompt"` key | `{"type":"prompt","message":"..."}` |
| `switch_session` with `"path"` | `{"type":"switch_session","sessionPath":"..."}` |
| `ready` frame at startup | none — process is immediately ready |
| `set_thinking_level` key uncertain | `{"type":"set_thinking_level","level":"low"}` |
| `reconfigureItems` on macOS | `reloadItems(_:)` (iOS-only API); reloads only the identified rows |

## Known scope cuts (per design)

- No auth handling, no bundling of node/pi, no packaging/signing/notarization.
- Slash commands other than what the native menus expose are not surfaced
  (a literal `/…` typed in the prompt still goes to pi's `prompt` handler).
- Seatbelt sandboxing of the pi subprocess (§9) is not implemented — optional
  per the design.
- Tool-call cards render from `tool_execution_*` events; `toolcall_*` deltas
  (assistant content streaming) are intentionally not rendered separately.
