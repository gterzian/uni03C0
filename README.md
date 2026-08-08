# uni03C0 — native macOS client for the pi coding agent

A lightweight macOS client for the [pi coding agent](https://github.com/earendil-works/pi).
It spawns `pi --mode rpc` as a sandboxed subprocess and renders the conversation
natively (SwiftUI + a hand-rolled `NSTableView` transcript) instead of running
the terminal TUI.

Status: pre-alpha; but already what yours truly uses for pi on a daily basis.

## Getting started

Requirements: macOS 26, Xcode 26.x, and `pi` on PATH (global npm install —
the app spawns the same binary the TUI uses). Auth is inherited from your
environment.

```bash
./run.sh        # generate the project, build, quit any running instance, launch
```

Tests: `xcodebuild -scheme ClientTests test`.

**On first launch** the app walks you through setting up the agent's sandbox:

1. choose a top-level working folder (everything inside it is read+write for the
agent), 

2. review the additional read/write paths, and 

3. the allowed internet domains. 

After that, pick a project and start prompting. The app is
single-window, but **tabbed**: your project opens as the first tab, a "+"
adds more sessions (one tab per folder, each a separate agent process with
the same sandbox settings), and tabs show at a glance whether their session
is idle or working. The Projects menu switches the window to another
project.

## Sandbox 

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
- **Agent RPC endpoint** — the pi executable the client spawns as
  `pi --mode rpc` (default: pi on PATH); point it at a different binary from
  Settings.

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
