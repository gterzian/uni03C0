# uni03C0 — native macOS client for the pi coding agent

A lightweight macOS client for the [pi coding agent](https://github.com/earendil-works/pi).
It spawns `pi --mode rpc` as a sandboxed subprocess and renders the conversation
natively (SwiftUI + a hand-rolled `NSTableView` transcript) instead of running
the terminal TUI.

## Getting started

Requirements: macOS 26, Xcode 26.x, and `pi` on PATH (global npm install —
the app spawns the same binary the TUI uses). Auth is inherited from your
environment.

```bash
./run.sh        # generate the project, build, quit any running instance, launch
```

Tests: `xcodebuild -scheme ClientTests test`.

**On first launch** the app walks you through setting up the agent's sandbox:
choose a top-level working folder (everything inside it is read+write for the
agent), review the additional read/write paths, and the allowed internet
domains. After that, pick a project and start prompting. The app is
single-window: it opens on your last project (or the setup screen), and the
Projects menu switches projects by replacing the window.

The prompt bar is the main surface: Return sends (or queues steering while the
agent works), Shift+Return is a newline, Tab completes paths. The toolbar holds
Stop, Reload, the model/thinking-level pickers, and Resume.

## Sandbox approach

The agent runs inside a **Seatbelt sandbox** (default-deny). Everything it can
touch is defined in Settings (app menu → Settings…):

- **Working folder** — the top-level projects folder; every project inside it
  is read+write. This is the agent's workspace.
- **Additional read/write paths** — toolchain homes, caches, frameworks,
  Xcode (prefilled with what macOS development needs).
- **`~/.pi`** — read+write (session data); system dirs — read-only.
- **Internet** — only the whitelisted domains (subdomains included); the model
  provider and the usual code sources (GitHub, crates.io, npm, PyPI, …) are
  prefilled.

Two mechanism notes that shape the design:

- **Applied via a launcher (Strategy A).** The app does not sandbox the child
  from outside — `sandbox_apply(profile, pid)` silently sandboxes the *caller*
  when `task_for_pid` fails. Instead a tiny launcher applies the policy to
  **itself** (`sandbox_init`) and execs the agent; the sandbox survives exec
  and is inherited by everything the agent spawns.
- **Domains enforced by a loopback whitelist proxy.** Seatbelt on macOS 26
  accepts only `*` and `localhost` as network hosts — no hostnames. So the
  sandbox allows loopback outbound only, and a loopback proxy in the app is
  the sole internet egress, enforcing the domain list. The agent inherits
  `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`, `NODE_OPTIONS=--use-env-proxy` (node
  only honors proxy env with this flag) and git proxy config; anything that
  ignores the proxy simply fails to connect — fail-closed, no bypass.

Settings are applied when a new agent process starts (app launch). A running
agent keeps its sandbox until the app restarts.

## Rendering approach

The transcript stays fast and cheap no matter how long the conversation is:
**rendering cost is a function of the visible rows, never of the context
size.** A 600-message session opens and streams like a two-message one.

Three pieces, each with one job:

1. **`TranscriptStore`** (off-main) owns the whole history. It folds the RPC
   event stream into rows and rebuilds from `get_messages` on session switch,
   on a background thread.
2. **`SessionViewModel`** (main) is a thin shim — connection, commands, small
   UI state. It forwards frames to the store off-main so a delta never blocks
   the UI.
3. **`Coordinator`** (main) renders a windowed slice of the store through an
   `NSTableView`: `numberOfRows` is just the window size; every cell and height
   is a store lookup. SwiftUI never reads the transcript entries — updates flow
   store → coordinator → table directly.

Why it stays fast:

- **Append-only streaming.** A change is always "something at the end changed,"
   so new rows append via `insertRows` (O(added)) — inserting at the end never
   shifts existing rows, so a scrolled-up viewport is untouched.
- **Older history loads in compounding blocks** (doubling, capped) with a small
   spinner at the top, and fetched rows are **never evicted** — scrolling back
   down reuses cached heights, so it's always instant.
- **A height cache** keyed by `(row, width)`, seeded from the visible cell's
   own layout (no duplicate CoreText measure — the original 100%-CPU hot
   path). Tool cards invalidate on content update so they grow in place.
- **Smooth streaming, no bounce.** Text is batched (a few words at a time, not
   per character) and each chunk crossfades in; the height change and the
   follow-scroll land in one atomic `CATransaction`, so content flows off the
   top instead of bouncing.
- **Zero rendering when off-screen.** When the window is occluded, minimized,
   or hidden, the coordinator does no per-delta work; one catch-up pass
   materializes the tail when you return.
- **Sticky follow that knows when to stop.** Following is on by default; the
   moment you scroll up it disengages so streaming doesn't drag you back, and
   re-engages when you return to the bottom. Arrow-Down jumps to the tail.
