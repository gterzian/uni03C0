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

After that, pick a project and start prompting; the sandbox is applied uniformly to all sessions.

A settings page is available to change the sandbox policy, taking effect on next launch.
