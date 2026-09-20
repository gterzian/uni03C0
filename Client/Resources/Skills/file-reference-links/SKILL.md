---
name: file-reference-links
description: >
  Emit clickable file/line references in chat responses so the user can jump
  straight to the referenced code in the Changes (diff) viewer. Use whenever a
  response names a file, function, or line range that HAS UNCOMMITTED CHANGES
  and the user would plausibly want to jump to it — e.g. "the bug is in
  Core/Renderer.swift:118" where that file was just edited.
---

# File reference links

When mentioning a specific file that is part of the current uncommitted
changeset — especially a specific line or range — write it as a Markdown link
instead of plain text, so the client renders a clickable jump-to-diff link:

    [<path>:<line>](pi-file:///<path>#L<line>)
    [<path>:<start>-<end>](pi-file:///<path>#L<start>-<end>)
    [<path>](pi-file:///<path>)                (whole-file reference, no line)

Rules:
- A link opens the file's section in the **Changes (diff) viewer** — the only
  file surface in the app. It can therefore only land on a file with
  uncommitted changes. Check `git status`/`git diff` first and only link files
  that appear there; a link to an unchanged file is dead (clicking it does
  nothing), so name those files in plain text instead.
- `<path>` is relative to the project root (the same form you already use as
  the `path` argument to `read`/`edit`/`write`), forward slashes, no leading
  `./`.
- Percent-encode `#`, `%`, and whitespace in the path if the filename
  contains them — an unescaped `#` in the path is parsed as the start of the
  fragment.
- Line numbers are 1-based and inclusive, matching how you already report
  line numbers in `read` tool output.
- Don't wrap the link in a code span — `` `[file.ts:10](pi-file:///file.ts#L10)` ``
  renders as literal text, not a link.
- One link per distinct location; don't repeat the same reference twice in
  one response.

## Examples

Bug report:
> The off-by-one is in [Core/TextDiff.swift:42-48](pi-file:///Core/TextDiff.swift#L42-48) —
> the loop's upper bound should be exclusive.

Pointing at a whole changed file:
> Sandbox rules live in [Core/Sandbox/SandboxPolicy.swift](pi-file:///Core/Sandbox/SandboxPolicy.swift).

Naming an unchanged file (no link — it is not in the diff):
> The entry point is `Core/Sandbox/main.swift`; it was not touched this turn.
