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

The agent runs inside a **Seatbelt sandbox** (default-deny): the policy
defines everything it can touch, and everything else is off-limits — files,
network, syscalls. Configuration lives in Settings (app menu → Settings…).

### What you configure

- **Working folder** — the top-level projects folder; every project inside it
  is read+write. This is the agent's workspace.
- **Additional read/write paths** — toolchain homes, caches, frameworks,
  Xcode (prefilled with what macOS development needs). One path per line.
- **Allowed internet domains** — the only hosts the agent can reach
  (subdomains included); the model provider and the usual code sources
  (GitHub, crates.io, npm, PyPI, …) are prefilled. One domain per line.
- **Agent RPC endpoint** — the pi executable spawned as `pi --mode rpc`
  (default: pi on PATH); point it at a different binary from Settings.

### What's fixed (not configurable)

Part of the policy scaffold, always present:

- **`~/.pi`** — read+write (sessions, config, auth).
- **System directories** — read-only (`/usr`, `/opt/homebrew`,
  `/System/Library`, …), plus temp folders (read+write).
- **Your git configuration** — read-only (`~/.gitconfig`, `~/.config/git`,
  `~/.git-credentials`, `~/.ssh`, …), so `git status`/`log`/… and SwiftPM
  package resolution work inside the sandbox.
- **Nested sandboxing** — the sandbox module's mac syscalls are permitted so
  tools like SwiftPM can apply their own child sandboxes; they can never
  loosen the outer profile.
- **Mach + POSIX IPC** — allowed in general: tools the agent runs use dynamic
  Mach service names (ipc-channel bootstrap names are random per connection,
  XPC services are launchd-registered) and Python multiprocessing uses named
  semaphores/shared memory, so nothing is name-whitelisted. Privileged
  services still check the caller's entitlements.
- **GPU / Metal** — IOKit access to the GPU services (AGX, Intel/AMD) and
  IOSurface, so graphics stacks (wgpu) can enumerate adapters and create
  devices; without it, adapter enumeration finds nothing.
- **Network** — loopback only (outbound and inbound): local test servers
  (WPT runners, WebDriver, TLA+ tracing) bind on 127.0.0.1, and the domain
  whitelist is enforced by the app's proxy (below) — anything that ignores
  the proxy simply cannot connect.

### When changes take effect

Settings are **snapshotted when a session starts**. A running agent keeps the
sandbox it started with until that session ends — Resume/Reload reuse the
running process and do **not** re-apply settings, so after editing settings,
quit and relaunch the app (new tabs also pick up current settings). Saved
lists from an older app version automatically gain any new default entries
once (one-shot migration); after that, your edits win wholesale.

### Mechanism notes

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
