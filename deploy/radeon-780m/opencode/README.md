# OpenCode against the Radeon 780M box

A Claude-Code-style agent setup running entirely on the local llama-server at
`192.168.254.250:8080`. Three agent modes, cross-session memory scoped to each
repo, and a skill policy tuned for a single-GPU server.

For the server itself - model aliases, quant choices, tuning - see
[`../README.md`](../README.md). This file covers only the client.

## Layout

This directory is the source of truth. Everything below `opencode-template/`
can be installed globally or per repo - see the two install sections - except
`memory/`, which is always per repo and never committed.

```
opencode/
  opencode.json               global config: provider + model aliases
  opencode-template/          the scaffold: install globally or per repo
    opencode.json             agent definitions + instructions wiring
    .opencode/
      prompt/
        core.txt              shared rules, auto-loaded for every agent
        claude-style.txt      default mode: asks before edit/bash
        claude-style-plan.txt read-only investigation and planning
        claude-style-auto.txt high autonomy, edits pre-approved
      memory/
        .gitignore            makes everything else here untracked
        MEMORY.md             index, created on first write (not committed)
        <slug>.md             one fact per file (not committed)
      command/
        remember.md           /remember
        recall.md             /recall
```

## The two config scopes

OpenCode merges a global config with a per-project one, and every piece of this
setup can live in either. The split that matters is not global-versus-local as a
whole - it is that **the rules are the same everywhere while the memory must
not be.**

| | Global | Per-project |
|---|---|---|
| Path | `~/.config/opencode/` | `<repo>/` |
| Config file | `opencode.json` | `opencode.json` |
| Prompts | `prompt/` | `.opencode/prompt/` |
| Commands | `command/` or `commands/` | `.opencode/command/` or `.opencode/commands/` |
| Memory | never | `.opencode/memory/` |

Both the singular and plural command directory names are accepted at both
scopes; all four are scanned and merged.

Config is read once at startup and is **not** hot-reloaded. After editing any
config file, prompt, or command, quit and restart opencode.

## Install A: everything global, memory per repo (recommended)

One machine-wide install, no per-repo setup, and every project still gets its
own private memory. This is the intended shape.

```bash
SRC=deploy/radeon-780m/opencode
mkdir -p ~/.config/opencode/prompt ~/.config/opencode/command
cp    $SRC/opencode.json                     ~/.config/opencode/opencode.json
cp -r $SRC/opencode-template/.opencode/prompt/.  ~/.config/opencode/prompt/
cp -r $SRC/opencode-template/.opencode/command/. ~/.config/opencode/command/
```

That is the whole install. Nothing to merge by hand: the shipped
[`opencode.json`](opencode.json) already carries the `instructions` array and
all three agents alongside the provider block, with prompts referenced at their
global location:

```json
{
  "instructions": ["~/.config/opencode/prompt/core.txt", ".opencode/memory/MEMORY.md"],
  "agent": {
    "claude-style": {
      "description": "General-purpose, asks before edit/bash",
      "prompt": "{file:~/.config/opencode/prompt/claude-style.txt}",
      "model": "llama-local/fast",
      "permission": { "edit": "ask", "bash": "ask" }
    }
  }
}
```

`~` is expanded in both `instructions` entries and `{file:...}` references, on
Windows as well as Linux, so there is no need to hardcode a home directory.
On Windows `~` is your user profile and opencode's config directory is
`C:\Users\<you>\.config\opencode` - note `.config`, not `AppData`. Forward
slashes are fine in the JSON on every platform.

The copy order matters: `opencode.json` references the prompt files, so copy
the `prompt/` directory too. Command files are discovered by scanning the config
directory rather than by path reference, so they must sit in
`~/.config/opencode/command/` itself - a `~` path elsewhere will not pick them
up.

If you only want the provider and not these agents, delete the `agent` and
`instructions` keys after copying, or use [Install B](#install-b-per-repo)
instead.

### The one asymmetry that makes this work

Look at the two `instructions` entries. `core.txt` is an **absolute** path;
the memory index is **relative**. That is deliberate and load-bearing.

A relative path in a *global* `instructions` array is resolved against whatever
project directory you launched opencode in. So a single global config gives
every repo its own `.opencode/memory/`, automatically, with no per-repo
configuration and no way for one repo to see another's memory.

Verified: with an identical global config, a session started in repo A answered
from A's index and a session started in repo B answered from B's, with no
cross-contamination in either direction.

Nothing else needs to be per-repo. Prompts, commands, agents, and the provider
are all machine-wide.

### Keeping memory out of git

Because nothing is copied into the repo, no `.gitignore` is there to protect
you. The prompts handle this: before its first write in any repo, the agent
creates `.opencode/memory/.gitignore` containing `*` and `!.gitignore`. Memory
stays untracked in every project without setup.

For belt and braces, add one line to your machine-wide ignore file - git honors
`~/.config/git/ignore` by default, with no `core.excludesfile` needed:

```bash
echo '.opencode/memory/' >> ~/.config/git/ignore
```

Confirm either mechanism is working from inside any repo:

```bash
git check-ignore -v .opencode/memory/MEMORY.md
```

### Verify the install

```bash
opencode models llama-local
opencode debug agent claude-style     # run this from inside a project
```

The agents carry no `model` of their own and inherit the top-level
`"model": "llama-local/fast"`, so `debug agent` reports an **empty** model for
them. That is expected: the field shows an agent's override, not the effective
model. To see what a session actually uses, start one - the header reads
`> claude-style . fast`.

Whenever you do write a model reference, use the qualified
`llama-local/<alias>` form. A bare alias like `"model": "fast"` parses the alias
as a *provider* and yields an empty `modelID`, which fails at request time.

### Install A under WSL

WSL adds one trap that will silently waste an afternoon, so check for it before
following any of the steps above.

**Typing `opencode` inside WSL probably runs the Windows binary.** WSL puts the
Windows `PATH` on your Linux `PATH`, so a shell with no Linux-native opencode
still resolves the command - to the `.exe`. It then reads the *Windows* config
and expands `~` to your Windows profile, which means a config you carefully
placed in `/home/<user>/.config/opencode/` is never read and nothing appears to
take effect.

Diagnose it in two commands:

```bash
command -v opencode          # /mnt/c/... means you are running the Windows binary
opencode debug paths         # "config  C:\Users\..." confirms it
```

A native Linux install shows `/usr/local/bin/opencode` and
`config  /home/<user>/.config/opencode`.

#### Decide which side actually runs opencode

Pick based on **where the repos live**, because crossing the filesystem
boundary is what hurts:

| Your repos live in | Run opencode from | Install A goes in |
|---|---|---|
| Windows (`C:\...`, OneDrive) | Windows | `C:\Users\<you>\.config\opencode\` |
| WSL (`/home/<user>/...`) | WSL, native install | `/home/<user>/.config/opencode/` |
| Both | Both, two installs | both, kept in sync from this repo |

Do not mix. Driving a Windows-resident repo from WSL means every file the agent
reads crosses `/mnt/c`, which is slow enough to matter for an agent doing
hundreds of reads. Driving a WSL-resident repo from the Windows binary hands it
a `\\wsl.localhost\...` UNC path, which is slower still and occasionally
resolves oddly.

This repo lives on the Windows side, so for llama.cpp work the Windows install
is the right one and WSL adds nothing.

#### Installing opencode natively in WSL

Only if you keep repos inside WSL. Use the install script:

```bash
curl -fsSL https://opencode.ai/install | bash
```

**Do not use `npm install -g opencode-ai` from WSL** unless you have installed
Linux Node first. With only Windows Node on the path, `npm` resolves to
`/mnt/c/Program Files/nodejs/npm` with prefix `C:\Users\<you>\AppData\Roaming\npm`,
so it reinstalls the *Windows* binary and leaves you exactly where you started.

Confirm the native binary now wins:

```bash
command -v opencode          # must NOT start with /mnt/c
opencode debug paths         # config must be under /home/<user>
```

`/usr/local/bin` precedes every `/mnt/c` entry on the default WSL path, so a
binary there shadows the Windows one automatically. If the installer chose a
different directory, put that directory ahead of the Windows entries in your
shell profile rather than relying on install order.

#### Then run Install A unchanged

With a native opencode, every command in Install A works verbatim - `~` is
`/home/<user>`, so `~/.config/opencode/prompt/core.txt` resolves on the Linux
side. Copy from the Windows checkout through `/mnt/c`:

```bash
SRC="/mnt/c/Users/<you>/OneDrive/Documents/Personal Folders/Homelab/llama.cpp/deploy/radeon-780m/opencode"
mkdir -p ~/.config/opencode/prompt ~/.config/opencode/command
cp    "$SRC/opencode.json"                        ~/.config/opencode/opencode.json
cp -r "$SRC/opencode-template/.opencode/prompt/."  ~/.config/opencode/prompt/
cp -r "$SRC/opencode-template/.opencode/command/." ~/.config/opencode/command/
```

Quote the paths - `Personal Folders` and `OneDrive` contain spaces.

The per-repo memory design needs no change. The relative
`.opencode/memory/MEMORY.md` entry still resolves against whatever project you
launch in, WSL-side or not.

#### WSL-specific follow-ups

- **Repeat the global git ignore.** WSL has its own `~/.config/git/ignore`,
  separate from the Windows one, and a fresh Ubuntu has no such file at all:
  ```bash
  mkdir -p ~/.config/git && echo '.opencode/memory/' >> ~/.config/git/ignore
  ```
  The agent's self-created `.opencode/memory/.gitignore` covers you either way;
  this is only belt and braces.
- **Networking needs nothing.** WSL2 reaches the box on the LAN directly -
  measured at 16 ms to `192.168.254.250:8080` with no port forwarding or
  mirrored-mode networking.
- **Two installs means two configs.** They do not share anything. Keep this
  directory as the source of truth and re-copy to both sides after editing, or
  they will drift.

### Trade-offs

The agents apply to every project, including ones where you would rather have
plain opencode - use `--pure` or a different agent there. Global config is also
not version-controlled with any repo, so keep this directory as the source of
truth and re-copy after editing it here.

## Install B: per-repo

Use when a project needs rules that differ from your global defaults, or when
you want the setup committed and shared with other people.

```bash
cp -r /path/to/llama.cpp/deploy/radeon-780m/opencode/opencode-template/. .
```

That drops in `opencode.json` and `.opencode/` with paths already relative, so
it works as-is. The provider block should still be global - it describes your
hardware, not the project.

If the target repo already has an `opencode.json`, merge rather than overwrite:
take the `agent` block and the `instructions` array.

Project config wins over global for the same key, so a repo installed this way
overrides your global agents cleanly.

### Committing it into a shared repo

The prompts and commands are ordinary files and are fine to commit. Memory is
not: the shipped `.opencode/memory/.gitignore` contains `*` plus `!.gitignore`,
so the ignore rule itself stays tracked and travels with a clone while every
memory file stays local to each person's working copy.

## The three agents

| Agent | Edit | Bash | Use for |
|---|---|---|---|
| `claude-style` | ask | ask | Default. You review each edit and command. |
| `claude-style-plan` | deny | read-only | Investigation. Produces a plan, executes nothing. |
| `claude-style-auto` | allow | allow, minus destructive | Long unattended runs. |

```bash
opencode --agent claude-style-plan
opencode run --agent claude-style "fix the failing vulkan test"
```

`claude-style-auto` still asks before `rm -rf`, force push, `git reset --hard`,
and anything outside the project directory. Autonomy covers routine steps, not
irreversible ones.

None of the three declares a model. All inherit the top-level
`"model": "llama-local/fast"`, so changing that one line moves every agent at
once - which is what you want when the `fast` alias is repointed at a new
build.

To pin one agent to a different alias, add a `model` to just that agent - useful
for putting `claude-style-plan` on `deep` for architecture work while execution
stays on `fast`:

```json
"claude-style-plan": { "model": "llama-local/deep", "...": "..." }
```

Do that sparingly. The server runs `models-max = 1`, so every switch between
aliases inside one session costs a 14-31 s model swap.

## How the prompts compose

Each agent's `prompt` is only its mode-specific delta - what it may do, its
reasoning posture, its operating loop. Everything shared lives in `core.txt`,
loaded through the `instructions` array, which opencode appends to the system
prompt of *every* agent:

```json
"instructions": ["~/.config/opencode/prompt/core.txt", ".opencode/memory/MEMORY.md"]
```

So the rules exist in exactly one place and cannot drift between the three
modes. Adding a fourth agent means writing only its delta.

In a per-repo install both entries are relative
(`.opencode/prompt/core.txt`); in a global install the first becomes absolute
and the second stays relative, which is what scopes memory to each project. See
[The one asymmetry that makes this work](#the-one-asymmetry-that-makes-this-work).

A missing `instructions` file is skipped silently, which is why a repo with no
memory yet starts cleanly.

## Memory

The point of the setup: opencode has no built-in memory, so sessions start
blank. `.opencode/memory/` is a small store of facts a repo has taught the
agent, and `MEMORY.md` - the index - rides into every session's system prompt
through `instructions`.

Only the index is auto-loaded. Individual `<slug>.md` files are read on demand,
so context cost stays roughly flat as the store grows.

A memory is written only if all three hold:

1. It will still be true in a week.
2. It is not recoverable from the repo - not the code, the git log, the README,
   `AGENTS.md`, or a config file.
3. Knowing it at session start would have changed how the agent worked.

Most of what happens in a session fails that test. Forty weak index lines are
worse than six good ones, because every line is re-read in every future session.

### Commands

```
/remember <fact>    record it; with no argument, the agent picks from the session
/recall             list the index grouped by type
/recall vulkan      read the matching memories and check they still hold
```

### Format

```markdown
---
name: vulkan-shader-cache-invalidation
type: gotcha
updated: 2026-08-08
---

Rebuilding after a shader source change does not invalidate the pipeline cache;
the old binary is reused and the change silently does not take effect.

**Why it matters:** benchmark results after a shader edit are meaningless until
the cache is cleared, so a "no regression" result can be a false negative.

**How to apply:** delete the cache directory before any build whose diff touches
a shader source.
```

`type` is one of `decision`, `constraint`, `gotcha`, `preference`, `reference`.
Cross-link with `[[other-slug]]`. The index gets one pointer line per memory and
never any content.

Memories record what was true when written. The prompts require confirming that
any file, symbol, or flag a memory names still exists before acting on it.

## Skills

The `superpowers` plugin in the global config registers 14 skills alongside
opencode's built-in `customize-opencode`. Names and descriptions are always in
context (~640 tokens, cheap); a skill *body* loads only on invocation and is
not cheap - at ~313 t/s prompt processing:

| Skill | Load cost |
|---|---|
| `subagent-driven-development` | ~6,900 tok, 22 s |
| `writing-skills` | ~6,500 tok, 21 s |
| `customize-opencode` | ~4,000 tok, 13 s |
| `brainstorming` | ~2,400 tok, 8 s |
| `systematic-debugging` | ~2,300 tok, 7 s |
| `test-driven-development` | ~2,200 tok, 7 s |

`core.txt` sets the policy below. Three of these conflict with running on one
local GPU, and the policy overrides them explicitly.

**Encouraged:** `verification-before-completion`, `systematic-debugging`. Both
sharpen rules already in `core.txt` and are cheap.

**On demand:** `using-git-worktrees`, `finishing-a-development-branch`,
`requesting-code-review`, `receiving-code-review`, `writing-skills`,
`customize-opencode`.

**Only if you ask:** `brainstorming` hard-gates all implementation behind an
approved design and asks one question per message - many slow round trips for a
small change. `test-driven-development` mandates deleting implementation written
before its test, which is wrong in a codebase where the change has no natural
unit test. `writing-plans` / `executing-plans` collide with the plan agent's own
output format.

**Disabled here:** `dispatching-parallel-agents` and
`subagent-driven-development`. Both assume subagents run concurrently on elastic
capacity. The box serves one model at a time across a small fixed number of
slots, so parallel dispatch serializes anyway while each fresh subagent re-pays
a full cold system prompt. Inline work is strictly faster.

The `using-superpowers` bootstrap is the sharpest conflict: it requires invoking
a skill before *any* response, including clarifying questions, and treats a 1%
chance of relevance as a mandate. That is written for a fast hosted model where
loading a skill is free. `core.txt` states that it does not apply, and that its
own rules outrank any instruction inside a skill body that tells the agent to
load more skills or gate work behind unrequested approval.

To drop skills entirely, remove the `plugin` array from the global config or run
with `--pure`.

## Verifying a change to any of this

Config resolution is inspectable offline, without spending a model call:

```bash
opencode debug config              # merged config
opencode debug agent <name>        # model, permissions, fully expanded prompt
opencode debug skill               # every registered skill with its body
opencode debug paths               # where data, cache, state live
```

`--pure` skips plugin loading, which makes these fast when you only care about
config.

What `debug` cannot show is whether `instructions` actually reach the model.
Test that with a sentinel: put a distinctive fact in `.opencode/memory/MEMORY.md`,
start a fresh session, and ask for it with "do not use any tools." If it comes
back, the memory path works.

## Known sharp edges

- Config is not hot-reloaded. Restart after every edit.
- `"model": "fast"` silently resolves to provider `fast` with an empty model ID.
  Always write `llama-local/fast`.
- Keep every agent on the same alias where you can. The server runs
  `models-max = 1`, so a mixed-alias session pays a 14-31 s model swap per
  switch.
- `claude-style-plan` allows `cat*` and `grep*` through bash for convenience,
  but the prompt tells the agent to prefer the read and grep tools. Harmless,
  and intentional.
- Eval aliases in the global config (`*-eval`) are not load-on-startup and are
  not wired to any client. Selecting one costs a model load.
- In a global install, keep the memory entry in `instructions` **relative**.
  Making it absolute would point every repo at one shared memory store and let
  projects read each other's notes.
- `opencode run` does not expand slash commands - they are a TUI feature. To
  check a command is registered, look for it in `opencode debug config` under
  the `command` key rather than trying to invoke it from `run`.
- Under WSL, `opencode` silently resolves to the Windows binary unless a native
  Linux one is installed, and then reads the Windows config. Always confirm with
  `command -v opencode` before concluding a config change had no effect.
