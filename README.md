# uni03C0 — native macOS client for the pi coding agent

A macOS client for the [pi coding agent](https://github.com/earendil-works/pi).
It spawns `pi --mode rpc` as a sandboxed subprocess and renders the conversation
with native macOS frameworks.

Status: pre-alpha; already what yours truly uses for pi on a daily basis.

## Getting started


On Mac OS, follow the Pi [Quickstart](https://pi.dev/docs/latest/quickstart). 

This project does not configure Pi or your authentication with an LLM provider.

Then, build and run with:

```bash
./run.sh        # generate the project, build, quit any running instance, launch
```

**On first launch** the app walks you through setting up the agent's sandbox:

1. choose a top-level working folder (everything inside it is read+write for
   the agent),
2. review the additional read/write paths,
3. review the allowed internet domains.

After that, pick a project and start prompting.

## Sandbox

The agent runs inside a **Seatbelt sandbox** (default-deny): the policy
defines everything it can touch, and everything else is off-limits — files,
network, syscalls. Configuration lives in Settings (app menu → Settings…).

### What you can configure (or use the default)

- **Working folder** — the top-level folder containing all coding projects; every project inside it
  is read+write. This is the agent's workspace.
- **Additional read/write paths** — toolchain homes, caches, frameworks,
  Xcode (prefilled with what macOS development needs). One path per line.
- **Allowed internet domains** — the only hosts the agent can reach
  (subdomains included); the model provider and the usual code sources
  (GitHub, crates.io, npm, PyPI, …) are prefilled. One domain per line.
- **Agent RPC endpoint** — the pi executable spawned as `pi --mode rpc`
  (default: pi on PATH); point it at a different binary from Settings.
