# Changelog

All notable changes to this project are listed here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-10-30

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
- 484 tests, run on macOS (bash 3.2) and Linux (bash 5) in CI.

### Security and robustness fixes

These came from a full code review before the first release. Each one has a regression test.

- **Untrusted repositories.** A `HANDOFF.md`, `PASTE-PROMPT.txt`, `LATEST.md` or recovered file that is a link out of the project (or into `.git` or `.claude`) is not read or written, unless you set `LIMIT_HANDOFF_FOLLOW_LINKS=1` in your own settings. The settings that choose files or sizes (`LIMIT_HANDOFF_FILE`, `_PROMPT_FILE`, `_RECOVER_DIR`, `_TAIL_LINES`, `_KEEP`, `_FOLLOW_LINKS`) are read only from the environment and your user config, never from a project's `.claude/limit-handoff.conf`. The `*` `.gitignore` is never written into a folder that holds your own files.
- **Less private text on disk.** An auto-created `HANDOFF.md` no longer copies your recent messages (they stay in the git-ignored recovered file), and token-shaped strings (API keys, GitHub and Slack tokens, AWS key ids, long hex or base64 runs) are replaced with `[redacted]`.
- **Safe text.** Control characters, line separators, direction marks and backticks are removed from file paths, task text and commands, so a file name cannot add a heading or a fake next step. The fallback recovered file (used without jq) never runs its values as commands.
- **Bounded work.** Only the last 32 MB of a transcript is read, a long run of spaces in a prompt stays fast, template values are cut at 100 KB, and the catch-up stops starting new chats after 10 seconds (the newest chat is always handled).
- **Catch-up.** A hook that was stopped half way is retried; a chat that is still being handled, or already has a block, is skipped; chats with no limit are remembered so they do not use up the 3-chat budget; chats are handed off oldest first; a limit line needs a `cwd` from this project; the git section is left out of catch-up files.
- **Right facts in the output.** The cut-off time is the limit line's own time; a reset time in the past says so; an old limit no longer shows after the chat went on; the newest unresolved block is chosen by time, and several open blocks are listed by session id; recovered files that open blocks name are never pruned.
- **Honest messages.** The paste prompt names `HANDOFF.md` and the recovered file only when they exist, and asks the new chat to work out the next step when none is known. The notification says what was really saved and where. When the project folder cannot take a file, the recovered file and the paste prompt go to the state folder. Two recovered files made in the same second never share a name. Reminders use your configured file name.
- **CLI.** `simulate` uses a realistic sample chat with fresh times, so the demo shows a limit that resets in the future; `install`/`uninstall` say when jq is missing; `install` names hooks it removed and lists valid error codes; `simulate` checks only its own files; `resolve`, `status`, `doctor` and `prompt` give clear errors for bad input.
- **Portability.** Tests no longer use BSD-only `sed -i ''`, `stat -f` or `date -v`; leading-zero numbers in config work; ShellCheck (warning level) passes, with directives and `.shellcheckrc`; one version source (`HK_VERSION` = `plugin.json`).

[Unreleased]: https://github.com/nicholas-a-saunders/limit-handoff/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/nicholas-a-saunders/limit-handoff/releases/tag/v1.0.0
