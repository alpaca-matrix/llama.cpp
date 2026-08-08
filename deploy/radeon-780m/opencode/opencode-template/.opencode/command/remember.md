---
description: Record a durable fact about this repo in .opencode/memory/
---

Record something in this project's cross-session memory at `.opencode/memory/`.

What to record: $ARGUMENTS

If the line above is empty, review this session and decide what is worth
recording. If it has content, that is the fact to record - the user has already
decided it matters, so do not re-litigate the three-part test against it. Do
still refuse if it is something a `grep` of this repo would answer, and say why
in one line.

Steps:

0. If `.opencode/memory/.gitignore` does not exist, create it first containing
   exactly `*` on one line and `!.gitignore` on the next. Memory is never
   committed, and without this the next `git add -A` would sweep it into the
   repo. Do this before writing any other file.
1. Check whether a memory already covers this ground. The index is in your
   context; if a line looks close, read that file. If it exists, update it in
   place - do not create a near-duplicate.
2. Write or update `.opencode/memory/<slug>.md` in the format given in the core
   rules: frontmatter with `name`, `type`, `updated`, then the fact, then
   **Why it matters:** and **How to apply:** lines. `type` is one of
   `decision`, `constraint`, `gotcha`, `preference`, `reference`.
3. Today's date is !`date +%F` - use it for the `updated` field, and convert any
   relative date in the body to an absolute one.
4. Add or update exactly one pointer line in `.opencode/memory/MEMORY.md`. Create
   that file with an `# Memory index` heading if it does not exist yet. The index
   holds pointers only, never content.

Reply with the slug and the one-line hook you indexed it under. Nothing else.
