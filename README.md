# limit-handoff

**Ran out of usage on one Claude account? Switch to your other account and carry on with the same task — without explaining it all again.**

[![CI](https://github.com/nicholas-a-saunders/limit-handoff/actions/workflows/ci.yml/badge.svg)](https://github.com/nicholas-a-saunders/limit-handoff/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/nicholas-a-saunders/limit-handoff)](https://github.com/nicholas-a-saunders/limit-handoff/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A free plugin for **Claude Code**, for people who use **more than one Claude account**.

**The problem.** You are deep in a task and Claude Code stops: *"You've hit your session limit."* You switch to your other account and open a new chat. That chat knows nothing. You spend time, and the new account's tokens, explaining the goal, what is done, which files changed and where you stopped. Something always gets missed.

**What limit-handoff does.** The moment the limit hits, it saves your place in your project folder and copies a short message to your clipboard. On the other account you paste that message into a new chat. Claude reads the saved notes and picks up at the exact next step. No re-explaining, no lost context, no tokens spent on catching up.

![Real output of limit-handoff simulate: a cut-off note in HANDOFF.md and a paste prompt that names the next step](docs/demo.svg)

---

## Install (once, about a minute)

**1. Check you have what it needs.** Open Terminal and run:

```bash
claude --version
```

```bash
jq --version
```

- `claude` must be version **2.1.78 or newer**. If it is older, update Claude Code.
- If `jq` is "not found", install it. On a Mac: `brew install jq`. On Linux: `sudo apt install jq` (or your system's package manager).
- It works on **macOS and Linux**. Windows is not supported yet.

**2. Install the plugin:**

```bash
claude plugin install limit-handoff --marketplace nicholas-a-saunders/limit-handoff
```

You should see `Successfully installed plugin: limit-handoff@limit-handoff`.

**3. Restart Claude Code.** Close it and open it again, so it loads the plugin.

That is it. There is nothing to set up. The plugin lives on your computer, not in your Claude account, so it keeps working on **every account** you sign in with.

---

## Use it: switch accounts and carry on

When a limit hits, you type no command. The plugin does its part by itself. You only switch accounts, open a new chat and paste.

**1. The limit hits.** Claude Code stops on account A. limit-handoff saves your place by itself, copies a short message to your clipboard (with your system's copy command, such as `pbcopy` on a Mac), and shows a desktop notification. The stopped chat shows nothing from the plugin, because Claude Code does not display what this hook prints.

**2. Switch to your other account.** In Claude Code, type `/login` and sign in with account B. (In Terminal you can also run `claude auth login`.)

**3. Open a new chat in the same project folder** and **paste** (Cmd+V on a Mac, Ctrl+Shift+V in most Linux terminals). It must be the same folder, with the same files, because the notes are saved there. The message looks like this:

> Continue my task in ~/code/store. My last chat stopped (usage limit reached — 5-hour limit, resets 15:41). First read ~/code/store/HANDOFF.md fully — it has the goal, what is done, decisions, and the exact next steps. Then read …/recovered-….md for the last messages before the cut-off. Check the files for any half-finished step, then start with: Add email and password validation. …

**4. Claude carries on.** It reads the saved notes, checks for a half-finished step, and continues from the next step. Once it has picked up the work, it marks the handoff as done by itself (`limit-handoff resolve`), because the plugin asks it to. That stops the reminder. You do not need to do this.

**If the clipboard is empty or was overwritten:** type *"carry on"* in the new chat instead. The plugin tells a new chat in that folder about the handoff by itself. The same message is also saved in the file `PASTE-PROMPT.txt` in your project folder.

**Moving to the other account before the limit?** This part is not automatic, because no limit has hit yet. Say *"handoff"* in the chat. Claude saves the task and shows the paste message in the chat. The full command is `/limit-handoff:handoff`: Claude Code puts the plugin's name in front of every plugin command.

---

## Try it first (2 minutes, nothing real is touched)

See what a handoff looks like before you need one. In Terminal:

```bash
mkdir -p ~/limit-handoff-test && cd ~/limit-handoff-test && claude
```

In that chat, ask Claude: *Run `limit-handoff simulate --dir .`*

This fakes a limit on a made-up chat. Then open the `limit-handoff-test` folder and look at `HANDOFF.md` and `PASTE-PROMPT.txt`. Next, start a **new** chat in the same folder and say "hi": Claude tells you there is an unfinished handoff and names the next step. Delete the folder when you are done.

---

## Remove it

```bash
claude plugin uninstall limit-handoff@limit-handoff
```

```bash
claude plugin marketplace remove limit-handoff
```

Your project files stay as they are. Delete `HANDOFF.md`, `PASTE-PROMPT.txt` and the `.handoff/` folder yourself if you no longer want them.

---

## What it saves, and where

Everything stays in your project folder, on your computer. Nothing is sent anywhere.

| File | What is in it |
|---|---|
| `HANDOFF.md` | The goal, what is done and the next steps, plus a "Session cut off" note with the time and the reason. If you already keep a `HANDOFF.md`, only the note is added. If you do not, one is made from the chat. |
| `.handoff/recovered-….md` | Your last messages, the task list, the files that were edited, the last commands, the git state and Claude's last reply. |
| `PASTE-PROMPT.txt` | The short message to paste into the new chat. It is also copied to your clipboard. |

The `.handoff/` folder is kept out of git automatically. Read [Safety and privacy](#safety-and-privacy) before you commit `HANDOFF.md` or `PASTE-PROMPT.txt`.

**Tip:** the handoff is best when Claude keeps `HANDOFF.md` up to date during the work. Add the [CLAUDE.md snippet](#add-this-to-your-claudemd) to your project and it will.

---

## Questions

**Does it work when I switch machines too?** Yes, if both machines have the same project folder (for example through git or a sync service) and the plugin is installed on both.

**Does it use tokens?** Almost none. The plugin adds about 70 tokens to each session (the description of its `/limit-handoff:handoff` command). The new chat reads a short summary instead of you retyping the history.

**Why not wait for the limit to reset?** Claude Code has a built-in setting, "Continue automatically at usage limit" (`autoContinueAtUsageLimit`). It waits in the **same open chat on the same account** and goes on when the limit resets. Use it if you can wait. limit-handoff is for when you cannot:

| Situation | Built-in auto-continue | limit-handoff |
|---|---|---|
| Carry on **now** on your **other account** | no | yes |
| Carry on on another machine | no | yes |
| A **weekly** limit (reset is days away) | no | yes |
| The chat was closed, or the terminal was killed | no | yes (the next chat catches up) |
| A chat that ended on "Prompt is too long" | no | yes (the next chat catches up) |
| Same chat, same account, and you can wait | yes | also writes a handoff (harmless) |

You can use both.

**Is it made by Anthropic?** No. It is an independent open-source project.

---

## Install without the plugin system (advanced)

<details>
<summary>Add the hooks to a settings file yourself</summary>

Clone the repository, then let the installer add the four hooks to a settings file you name. It changes nothing unless you pass `--settings`, makes a backup first, and keeps your other hooks.

```bash
git clone https://github.com/nicholas-a-saunders/limit-handoff.git
cd limit-handoff
bin/limit-handoff install --settings ~/.claude/settings.json --dry-run   # shows the change, writes nothing
bin/limit-handoff install --settings ~/.claude/settings.json
bin/limit-handoff status  --settings ~/.claude/settings.json            # check
```

The hook commands point at this folder by full path, so do not move it afterwards (or run `uninstall` and `install` again). To remove only the kit's hooks: `bin/limit-handoff uninstall --settings ~/.claude/settings.json`.

Use the plugin **or** the settings hooks, not both: both at once run every hook twice. `install` and `doctor` warn when they find the plugin turned on.

</details>

---

## How it works

```
Claude Code stops with a usage, rate or billing limit
        |
        v
StopFailure hook (rate_limit | billing_error | unknown)
        |
        +--> reads the end of the transcript (only reads; nothing in it is run)
        +--> .handoff/recovered-<time>-<session>.md   (+ .handoff/LATEST.md)
        +--> HANDOFF.md: adds this chat's "Session cut off" block,
        |                or creates HANDOFF.md from the chat if there is none
        +--> PASTE-PROMPT.txt, clipboard, desktop notification
        v
New chat (any account, same files): paste the prompt. It reads HANDOFF.md,
then the recovered file, checks for a half-finished step, and starts at the next step.
```

The four hooks:

| Hook | When | What it does |
|---|---|---|
| `StopFailure` | A chat stops on a limit error. | The steps above. Repeat events for the same chat within 120 s are ignored. |
| `SessionStart` | A chat starts or resumes. | **Catch-up:** if a recent chat in this project ended on a limit (or on "Prompt is too long") with no handoff, writes it now. Then, if `HANDOFF.md` has an unresolved cut-off, tells Claude to read it and names the first next step. |
| `UserPromptSubmit` | You send a message. | A short reminder to read `HANDOFF.md`: once per session, then when the file is stale. |
| `PreCompact` | Before Claude Code compacts a long chat. | Saves a snapshot to `.handoff/recovered-<time>-<session>-precompact.md`. |

Every hook always exits 0 and never blocks Claude Code. Timeouts: StopFailure 30 s, SessionStart 20 s, PreCompact 30 s, UserPromptSubmit 5 s.

**The cut-off block** sits between two marker comments in `HANDOFF.md`. It names the reason ("usage limit reached — 5-hour limit, resets Sun 01 Nov 15:41 GMT"), the time of the cut-off and the recovered file. Your own text is never changed. Each chat gets its own block. While a block is unresolved, the `SessionStart` and `UserPromptSubmit` hooks tell Claude to run `limit-handoff resolve` once it has picked up the work, so Claude normally marks the block as done itself. The block stays as history. You can also run it yourself:

```bash
limit-handoff resolve                      # all unresolved blocks
limit-handoff resolve --session <id>       # one chat, when several were cut off
```

---

## Safety and privacy

**What it reads:** the end of the transcript file Claude Code already keeps on your disk (at most the last 32 MB and `LIMIT_HANDOFF_TAIL_LINES` lines), `HANDOFF.md`, its config files, and git state through read-only commands with repository-run programs turned off (no fsmonitor, filters, external diff or textconv).

**What it writes:** only the files in [Files it writes](#files-it-writes), inside your project and its state folder. Plus the clipboard and a desktop notification, which you can turn off.

**What it sends:** nothing. No network calls, no telemetry.

**What it runs:** nothing it reads. Transcript text, `HANDOFF.md` and config files are treated as plain text. Clipboard and notification tools are the standard ones (`pbcopy`, `wl-copy`, `xclip`, `xsel`, `clip.exe`, `osascript`, `notify-send`, `terminal-notifier`).

**Cloned repositories cannot steer it.** A repository you clone may ship its own `.claude/limit-handoff.conf`, but these keys are read only from the environment or your user config, never from the project file: `LIMIT_HANDOFF_FILE`, `_PROMPT_FILE`, `_RECOVER_DIR`, `_TAIL_LINES`, `_KEEP`, `_FOLLOW_LINKS`, `_CLIPBOARD`, `_NOTIFY`, `_STATE_DIR`. A `HANDOFF.md`, `PASTE-PROMPT.txt`, `LATEST.md` or recovered file that is a symbolic link out of the project, or into `.git` or `.claude`, is not read or written. If you keep `HANDOFF.md` as a link on purpose (for example into a dotfiles folder), set `LIMIT_HANDOFF_FOLLOW_LINKS=1` in your own config.

**Less private text on disk.** Recovered text has control characters, direction marks and backticks removed from paths and commands, and token-shaped strings (API keys, GitHub and Slack tokens, AWS key ids, long hex or base64 runs) are replaced with `[redacted]`. A `HANDOFF.md` that the kit creates does not copy your recent messages; they stay in the recovered file.

**Keep chat text out of git.** `.handoff/` gets its own `.gitignore` (`*`). `PASTE-PROMPT.txt` and an auto-created `HANDOFF.md` are made from chat text, so check them before you commit them. Many people add these lines to `.gitignore`:

```gitignore
.handoff/
PASTE-PROMPT.txt
HANDOFF.md
```

**Undo:** `claude plugin uninstall limit-handoff@limit-handoff`, or `limit-handoff uninstall --settings <file>` (it keeps a backup). Then delete `.handoff/`, `PASTE-PROMPT.txt`, the cut-off blocks in `HANDOFF.md`, and the state folder.

---

## Requirements

- **Claude Code 2.1.78 or newer** (the version that added the `StopFailure` hook). `limit-handoff doctor` checks it.
- **bash 3.2 or newer.** macOS ships bash 3.2, so nothing extra is needed there.
- **jq.** `brew install jq` on macOS, or your Linux package manager. Without jq the hooks still write the cut-off block and the paste prompt, but the recovered file has only a short note, and `install`/`simulate` stop with a clear message.
- **git** (optional) for the repository section in the recovered file.
- **macOS or Linux.** CI runs the tests on both. Windows is not tested.

---

## Files it writes

| File | What it is |
|---|---|
| `HANDOFF.md` | Your handoff file. The kit adds or updates only its own cut-off block, or creates the file when it is missing. |
| `PASTE-PROMPT.txt` | The paste prompt for a new chat. A file here that the kit did not write is first copied to `PASTE-PROMPT.txt.bak-<time>`. |
| `.handoff/recovered-<time>-<session>.md` | Recovered context. The newest 30 are kept (`LIMIT_HANDOFF_KEEP`); files that an unresolved block names are never deleted. |
| `.handoff/recovered-<time>-<session>-precompact.md` | Snapshot before compaction (counted separately). |
| `.handoff/LATEST.md`, `.handoff/.gitignore` | A copy of the newest recovered file; a `*` rule so git ignores the folder. |
| `<state folder>/…` | Log (`limit-handoff.log`), per-chat markers, and a fallback place for the recovered file and the paste prompt when the project folder cannot take them. |

The state folder is `$CLAUDE_PLUGIN_DATA` for the plugin, otherwise `~/.local/state/limit-handoff`. Change it with `LIMIT_HANDOFF_STATE_DIR`.

---

## Configuration

Nothing needs to be set. Each key is read in this order, the first found wins: environment variable, project file `<project>/.claude/limit-handoff.conf`, user file `~/.config/limit-handoff/config` (or under `$XDG_CONFIG_HOME`), built-in default. Files are read as `KEY=VALUE` lines and never run. [`config/limit-handoff.conf.example`](config/limit-handoff.conf.example) is a commented copy.

Keys marked **user only** are never read from the project file.

| Key | Default | Meaning |
|---|---|---|
| `LIMIT_HANDOFF_ERRORS` | `rate_limit billing_error unknown overloaded server_error` | Stop codes that make a handoff, inside the hook. The plugin's matcher only starts the hook for `rate_limit`, `billing_error` and `unknown`. |
| `LIMIT_HANDOFF_CREATE_IF_MISSING` | `1` | Create `HANDOFF.md` from the chat when it is missing. |
| `LIMIT_HANDOFF_PROMPTS` | `5` | How many of your last messages go into the recovered file. |
| `LIMIT_HANDOFF_GIT` | `1` | Add the git section to recovered files. |
| `LIMIT_HANDOFF_CATCHUP` | `1` | At a new chat, write a missing handoff for a recent chat that ended on a limit. |
| `LIMIT_HANDOFF_CATCHUP_HOURS` | `48` | How far back the catch-up looks (it reads at most 3 chats and stops starting new ones after 10 s). |
| `LIMIT_HANDOFF_DEBOUNCE_SEC` | `120` | Ignore a repeat StopFailure for the same chat within this many seconds. |
| `LIMIT_HANDOFF_REMIND` | `stale` | When the "read HANDOFF.md" reminder shows: `always`, `stale` or `off`. |
| `LIMIT_HANDOFF_STALE_MIN` | `20` | Minutes before `HANDOFF.md` counts as stale. |
| `LIMIT_HANDOFF_CLIPBOARD` | `auto` | **User only.** `auto`, `off`, or a bare command name on your PATH such as `pbcopy` (paths are refused). |
| `LIMIT_HANDOFF_NOTIFY` | `auto` | **User only.** `auto` or `off`. |
| `LIMIT_HANDOFF_FILE` | `HANDOFF.md` | **User only.** Handoff file name, inside the project. |
| `LIMIT_HANDOFF_PROMPT_FILE` | `PASTE-PROMPT.txt` | **User only.** Paste prompt file name, inside the project. Never the handoff file. |
| `LIMIT_HANDOFF_RECOVER_DIR` | `.handoff` | **User only.** Folder for recovered files, inside the project. |
| `LIMIT_HANDOFF_TAIL_LINES` | `4000` | **User only.** How many transcript lines to read from the end. |
| `LIMIT_HANDOFF_KEEP` | `30` | **User only.** Recovered files to keep; `0` keeps all. |
| `LIMIT_HANDOFF_FOLLOW_LINKS` | `0` | **User only.** `1` allows links that point outside the project. |
| `LIMIT_HANDOFF_STATE_DIR` | see above | **User only.** Log and marker folder. |

File names must stay inside the project and may not point into `.git` or `.claude`. A bad value is logged and the default is used.

---

## Command line

```
limit-handoff install   --settings FILE [--errors LIST] [--events LIST] [--dry-run]
limit-handoff uninstall --settings FILE [--dry-run]
limit-handoff status    [--settings FILE] [--dir DIR]
limit-handoff prompt    [--dir DIR] [--no-copy]
limit-handoff recover   --transcript FILE [--dir DIR] [--stdout]
limit-handoff resolve   [--dir DIR] [--session ID]
limit-handoff simulate  [--dir DIR] [--error CODE] [--transcript FILE] [--copy]
limit-handoff doctor    [--settings FILE]
limit-handoff --help | --version
```

| Command | What it does |
|---|---|
| `install` / `uninstall` | Add or remove the kit's hooks in a settings file you name. Backup first, `--dry-run` writes nothing, your other hooks stay. `--errors` sets the StopFailure codes (default `rate_limit\|billing_error\|unknown`); `--events` picks hooks from `stop-failure,prompt-submit,session-start,pre-compact` (kit hooks not listed are removed, and the command says which). |
| `status` | The handoff file's age, unresolved cut-offs, recovered files, installed kit hooks, last log lines. |
| `prompt` | A manual handoff now: builds and prints the paste prompt and copies it (unless `--no-copy`). Use it before you end a chat on purpose. |
| `recover` | Build a recovered-context file from any transcript (`--stdout` prints it). |
| `resolve` | Mark cut-off blocks as resolved. The history stays. |
| `simulate` | Run the real hook on a fake stop (see [Try it first](#try-it-first-2-minutes-nothing-real-is-touched)). |
| `doctor` | Check bash, jq, clipboard, notifications, the state folder, the Claude Code version, and hooks registered twice. Read only. |

`--dir` is the project folder; without it the kit uses `CLAUDE_PROJECT_DIR`, then the current folder. Exit codes: `0` ok, `1` something failed, `2` wrong usage (or a settings file that is not valid JSON).

---

## Add this to your CLAUDE.md

The hooks work on their own. A `HANDOFF.md` that Claude keeps up to date during the chat makes the handoff much better. Paste this into your project or user `CLAUDE.md` (full text in [`templates/claude-md-snippet.md`](templates/claude-md-snippet.md)):

```markdown
## Keep HANDOFF.md current

For any task with more than one or two steps, or any task that edits files:

1. At the start, create or read `HANDOFF.md` in the project root. If it exists, read it first and continue from it.
2. Keep it accurate, not long. Update it after each finished step, before any long or risky action, when the goal changes, and before the final reply.
3. Keep these headings: Goal, Status, Done so far, Next steps (in order), Key decisions & user preferences, Important facts / findings, Open questions / risks, Paste prompt (for a new chat).
4. Keep the current paste prompt at the bottom of `HANDOFF.md`.
5. If a `Session cut off` block appears in `HANDOFF.md`, read it and the recovered context file it names. Check the files for a half-finished step before you continue. Then run `limit-handoff resolve`.
```

The plugin also adds a `/limit-handoff:handoff` skill: it saves the full task state to `HANDOFF.md` and prints a paste prompt, for when you want to move to a new chat yourself.

---

## Known limits

- **Claude Code must run the StopFailure hook.** It does not always:
  - In headless mode (`claude -p`), external programs started by a StopFailure hook can be killed early ([anthropics/claude-code#101420](https://github.com/anthropics/claude-code/issues/101420)). The next chat's catch-up then writes the handoff.
  - "Prompt is too long" fires no StopFailure ([#104951](https://github.com/anthropics/claude-code/issues/104951)). Catch-up covers it at the next start.
  - Background subagents can fire StopFailure on the parent session ([#91419](https://github.com/anthropics/claude-code/issues/91419)). The kit ignores subagent lines and repeat events within 120 s.
- **Limit type and reset time come from the transcript**, because the hook input does not carry them ([#97975](https://github.com/anthropics/claude-code/issues/97975), [#98012](https://github.com/anthropics/claude-code/issues/98012)). Treat the reset time as a guide.
- **The transcript format is internal to Claude Code** and can change. Lines the parser does not understand are skipped, so recovery degrades rather than fails.
- **Only the end of a long chat is read.** The first request can fall outside it; the created `HANDOFF.md` then says the goal was not found.
- **"Same files" means you share the project folder** with the new machine, through git or a sync tool. The handoff lives in the project.
- **A force-quit or sleep in the middle of a stop** can leave no files. The next chat's catch-up, or `limit-handoff prompt`, covers it.
- **Task lists are best effort** for TaskCreate/TaskUpdate, which are matched through Claude Code's reply text.
- **Windows is not tested.**

---

## How it compares

| Approach | Good at | Gap |
|---|---|---|
| Built-in auto-continue | No setup; same chat goes on after the reset | Same open session and account only |
| Resuming the old chat later | No setup | Same account, and the chat must still exist |
| Writing `HANDOFF.md` by hand, or CLAUDE.md rules alone | Full control; keeps the file fresh during work | Nothing runs at the moment of the cut-off; no paste prompt |
| **limit-handoff** | A ready handoff at the moment of the stop, for a new chat anywhere | Needs Claude Code to run the hook (catch-up covers most misses); reads an internal format |

---

## Development

```bash
/bin/bash tests/run.sh
```

490 tests, pure bash and jq, run on macOS (`/bin/bash` 3.2) and Ubuntu in CI. Each test gets a temp HOME and state folder, and clipboard, notification and `claude` are replaced by shims, so a run never touches your real setup. ShellCheck must pass at warning level:

```bash
shellcheck --shell=bash --severity=warning --external-sources bin/limit-handoff hooks/*.sh lib/common.sh
```

Design notes are in [`docs/DECISIONS.md`](docs/DECISIONS.md) and [`docs/SPEC.md`](docs/SPEC.md). See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md) (report problems privately through GitHub) and [CHANGELOG.md](CHANGELOG.md).

Version 1.0.0. MIT licence, see [LICENSE](LICENSE).

Not affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic.
