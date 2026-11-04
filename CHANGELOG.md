# Changelog

All notable changes to this project are listed here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.1] - 2026-11-04

### Fixes from a full test of the public release

- **More secrets are hidden.** Private key blocks, Stripe, Google and npm keys, AWS secret keys (which contain `/`), JWTs, a password in a URL, the value after names like `password=` or `"api_key":`, and Bearer tokens are now replaced with `[redacted]`. The git commit line in the recovered file gets the same rules.
- **No finished step as the next step.** When every item in "Next steps" is ticked `[x]`, the paste prompt no longer says "start with" a finished item; it asks Claude to work out the next step. A `[x]` item is now always skipped.
- **Long prompts no longer stop the handoff.** Removing `<system-reminder>` sections took time that grew with the square of the text, so a prompt with many unclosed tags could run past the hook's 30 s limit. It now takes well under a second.
- **Empty or broken hook input writes nothing.** A hook run by hand with empty or non-JSON input used to write notes into whatever folder the shell was in. A closed stdin no longer makes a hook wait until its timeout.
- **The command line tool works through a symlink** (for example `ln -s …/bin/limit-handoff ~/bin/`).
- **A `--dir` whose name starts with `-`** is used as a folder, not read as a `cd` option.
- **`install` and `uninstall` refuse a settings file that is read-only or a dangling link**, instead of replacing it or making a new file.
- **Safer temp files.** Files are written through a temp file with a random name (`mktemp`), so a link planted at a guessable name cannot send the text elsewhere.
- 16 new tests (517 in all). 13 of them fail on the 1.0.0 code.

## [1.0.0] - 2026-11-03

First public release.

### Added

- **StopFailure handoff.** When Claude Code stops on a usage, rate or billing limit, the kit writes a recovered-context file (your last messages, the task list, files edited, repository state, last commands, last reply), adds a "Session cut off" block to `HANDOFF.md` (or creates `HANDOFF.md` from the transcript), writes `PASTE-PROMPT.txt`, copies it to the clipboard and shows a notification.
- **Limit details.** The cut-off block, paste prompt and notification say which limit was hit and when it resets (for example "5-hour limit, resets Thu 30 Oct 17:40 GMT"), read from the transcript.
- **Catch-up on the next start.** If a session ended on a limit (or on "Prompt is too long") and no handoff was written, the next session in the same project writes it and tells Claude. This covers hooks that never ran.
- **Repository state from git** in the recovered file: branch, last commit, changed files and a diff summary. Read-only git commands with repository-controlled programs turned off.
- **Duplicate protection.** Repeat StopFailure events for the same session within 120 seconds are ignored.
- **Reminder hooks.** SessionStart and UserPromptSubmit remind Claude to read `HANDOFF.md` and to recover an unresolved cut-off. PreCompact saves a snapshot before compaction.
- **CLI** (`limit-handoff`): `install` / `uninstall` (dry run, backup, never touches other hooks), `status`, `prompt`, `recover`, `resolve`, `simulate`, `doctor` (also warns when hooks are registered twice and checks the Claude Code version).
- **Plugin packaging** with a single-plugin marketplace, so it installs with `claude plugin install`.
- **Housekeeping.** `.handoff/` gets its own `.gitignore`, and old recovered files are pruned (30 kept by default).
- 501 tests, run on macOS (bash 3.2) and Linux (bash 5) in CI.

### Security and robustness fixes

These came from a full code review before the first release. Each one has a regression test.

- **Untrusted repositories.** A `HANDOFF.md`, `PASTE-PROMPT.txt`, `LATEST.md` or recovered file that is a link out of the project (or into `.git` or `.claude`) is not read or written, unless you set `LIMIT_HANDOFF_FOLLOW_LINKS=1` in your own settings. The settings that choose files or sizes (`LIMIT_HANDOFF_FILE`, `_PROMPT_FILE`, `_RECOVER_DIR`, `_TAIL_LINES`, `_KEEP`, `_FOLLOW_LINKS`), like `_CLIPBOARD`, `_NOTIFY` and `_STATE_DIR`, are read only from the environment and your user config, never from a project's `.claude/limit-handoff.conf`. The `*` `.gitignore` is never written into a folder that holds your own files.
- **Less private text on disk.** An auto-created `HANDOFF.md` no longer copies your recent messages (they stay in the git-ignored recovered file; its goal is the first request), and token-shaped strings (API keys, GitHub and Slack tokens, AWS key ids, long hex or base64 runs) are replaced with `[redacted]`.
- **Safe text.** Control characters, line separators, direction marks and backticks are removed from file paths, task text and commands, so a file name cannot add a heading or a fake next step. The fallback recovered file (used without jq) never runs its values as commands.
- **Bounded work.** Only the last 32 MB of a transcript is read, a long run of spaces in a prompt stays fast, template values are cut at 100 KB, and the catch-up stops starting new chats after 10 seconds (the newest chat is always handled).
- **Catch-up.** A hook that was stopped half way is retried; a chat that is still being handled, or already has a block, is skipped; chats with no limit are remembered so they do not use up the 3-chat budget; chats are handed off oldest first; a limit line needs a `cwd` from this project; the git section is left out of catch-up files.
- **Right facts in the output.** The cut-off time is the limit line's own time; a reset time in the past says so; an old limit no longer shows after the chat went on; the newest unresolved block is chosen by time, and several open blocks are listed by session id; recovered files that open blocks name are never pruned.
- **Honest messages.** The paste prompt names `HANDOFF.md` and the recovered file only when they exist, and asks the new chat to work out the next step when none is known. The notification says what was really saved and where. When the project folder cannot take a file, the recovered file and the paste prompt go to the state folder. Two recovered files made in the same second get different names (the kit waits up to 3 seconds for a free name). Reminders use your configured file name.
- **CLI.** `simulate` uses a realistic sample chat with fresh times, so the demo shows a limit that resets in the future; `install`/`uninstall` say when jq is missing; `install` names hooks it removed and lists valid error codes; `simulate` checks only its own files; `resolve`, `status`, `doctor` and `prompt` give clear errors for bad input.
- **Locking on new Linux.** Two chats that stop at the same moment no longer lose a cut-off block on Ubuntu 26.04, whose Rust `mkdir` is not atomic: the lock is now a file made with bash's noclobber option, and a lock left by a process that has ended is cleared.
- **Portability.** Tests no longer use BSD-only `sed -i ''`, `stat -f` or `date -v`; leading-zero numbers in config work; ShellCheck (warning level) passes, with directives and `.shellcheckrc`; one version number, kept the same in `HK_VERSION` and `plugin.json` by a test.

### Fixes from a first-time-user test

These came from testing the repository the way a new user would, before the first release: install from GitHub, every command, edge cases, and a real Claude Code session. Each code change has a regression test.

- **Rate-limit wording.** A `rate_limit` stop with no limit details now says "rate or usage limit reached" (in `HANDOFF.md`, the paste prompt, the notification and the hook reminders). "Usage limit reached" is kept when the transcript or the last message names the limit (5-hour, weekly, session) or its reset time. A short API rate limit no longer reads like an account limit.
- **`resolve` marks the visible line too.** The first line of a resolved block changes from "⚠️ **Session cut off**" to "✅ **Session cut off (resolved)**", so a person reading `HANDOFF.md` can see it. Text outside the blocks is not changed.
- **Other open cut-offs in the paste prompt.** When `HANDOFF.md` has unresolved cut-offs from other chats, the paste prompt (from a stop, or from `limit-handoff prompt`) says so and asks the new chat to read the recovered file each one names.
- **`CLAUDE_CONFIG_DIR`.** `doctor` and the `install` plugin check use `$CLAUDE_CONFIG_DIR/settings.json` when that is set (some people keep one config folder per account), else `~/.claude/settings.json`.
- **A log line for ignored keys.** When a project's `.claude/limit-handoff.conf` sets a key that is read only from the environment or your own config, the StopFailure hook logs which keys it ignored (names only, never values).
- **README.** The pitch is about carrying on in a new chat, with a "What it does not do" line (no limit is changed or bypassed; use each account within Anthropic's terms); why a second account is needed (the limit is per account); paste is the main way and "carry on" the fallback; Claude usually, not always, marks the handoff as done; `limit-handoff` runs inside a Claude chat, not in your own Terminal (full path given); "Remove it" no longer says to delete your own `HANDOFF.md`; the state folder, the created goal, the token cost and the subagent and debounce limits are described as they are.
- **SECURITY.md.** The next-step line from `HANDOFF.md` is named as the one text a project file can show to Claude.

[Unreleased]: https://github.com/nicholas-a-saunders/limit-handoff/compare/v1.0.1...HEAD
[1.0.1]: https://github.com/nicholas-a-saunders/limit-handoff/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/nicholas-a-saunders/limit-handoff/releases/tag/v1.0.0
