---
name: file-reference-links
description: >
  Emit clickable file/line references in chat responses so the user can jump
  straight to the referenced code in the Files pane. Use whenever a response
  names a specific file, function, or line range the user would plausibly
  want to open — e.g. "the bug is in Core/Renderer.swift:118" or "see the
  config in package.json".
---

# File reference links

When mentioning a specific file — especially a specific line or range — write
it as a Markdown link instead of plain text, so the client renders a
clickable jump-to-file-and-line link:

    [<path>:<line>](pi-file:///<path>#L<line>)
    [<path>:<start>-<end>](pi-file:///<path>#L<start>-<end>)
    [<path>](pi-file:///<path>)                (whole-file reference, no line)

Rules:
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

Pointing at a whole file:
> Sandbox rules live in [Core/Sandbox/SandboxPolicy.swift](pi-file:///Core/Sandbox/SandboxPolicy.swift).
