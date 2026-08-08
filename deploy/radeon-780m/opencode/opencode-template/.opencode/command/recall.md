---
description: Show what this repo's agent memory knows, optionally filtered
---

Report what is in this project's cross-session memory at `.opencode/memory/`.

Filter: $ARGUMENTS

The index is already in your context - do not read `MEMORY.md` again.

If the filter is empty, list every index line grouped by `type`, one line each,
and stop. Do not open the individual files.

If the filter has content, pick the index lines that bear on it, read only those
memory files, and for each one report:

- the slug and what it says, in one or two lines
- whether it still holds - if it names a file, symbol, flag, or command, check
  that the thing still exists before you vouch for it

Call out anything you find that has gone stale, and offer to delete or update it.
Do not change any file unless the user asks.

If the memory directory does not exist yet, say so in one line. That is the
normal state for a repo you have not worked in before, not an error.
