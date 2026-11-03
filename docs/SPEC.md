# Specification — limit-handoff

This is the original design spec (v0.1). Later choices and changes are in [DECISIONS.md](DECISIONS.md); where they differ, DECISIONS.md and the code win.

## One-line purpose
When a Claude Code session dies on a usage/rate/billing limit, automatically leave a clean handoff: mark `HANDOFF.md` as cut off (or create it from the transcript if missing), rescue the last context from the session transcript, build a ready-to-paste continuation prompt, copy it to the clipboard, save it to a file and notify the user — so a brand-new chat (even on a different account) can continue with no lost context. Plus light hooks that keep `HANDOFF.md` fresh and tell the next session to recover.

## Origin
The kit grew out of a small personal StopFailure script that appended a cut-off line to HANDOFF.md, wrote a paste prompt and copied it to the clipboard, plus a UserPromptSubmit reminder and a `/handoff` skill. This spec turned that into a tested, portable tool.
**The kit must never write to `~/.claude` or any real settings during tests. The installer only writes to a path the user passes, and tests always pass temp paths.**

## Verified Claude Code hook facts (from official docs, 2026-10-29)
- Common stdin fields (all events): `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `permission_mode`, optional `prompt_id`, `scratchpad_dir`, `effort` ({level}). Env var `CLAUDE_PROJECT_DIR` = project root.
- **StopFailure**: extra fields `error` (one of `rate_limit`, `overloaded`, `authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`, `billing_error`, `invalid_request`, `model_not_found`, `server_error`, `max_output_tokens`, `cloud_credential_error`, `unknown`), optional `error_details`, optional `last_assistant_message` (API error text). Matcher = exact error values joined by `|`. **Output and exit code are ignored** — side effects only.
- **SessionStart**: extra `source` ∈ `startup|resume|clear|compact|fork`, optional `model`. Plain stdout on exit 0 is added to Claude's context; JSON form `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}`.
- **UserPromptSubmit**: extra `prompt`. No matcher. Plain stdout on exit 0 → context. Default timeout 30 s.
- **PreCompact**: extra `trigger` (`manual|auto`), `custom_instructions`. Exit 2 would block compaction — never do that; always exit 0.
- settings.json shape: `{"hooks":{"EventName":[{"matcher":"...","hooks":[{"type":"command","command":"...","timeout":N}]}]}}` (matcher optional for events without matchers; timeout in seconds).
- Plugin: `.claude-plugin/plugin.json` (only `name` required) + `hooks/hooks.json` (same shape under top-level `"hooks"`), commands reference `"${CLAUDE_PLUGIN_ROOT}/..."` (quoted). `CLAUDE_PLUGIN_DATA` = persistent writable dir.
- Transcript JSONL (internal format, may change — parse defensively, never fail on unknown lines). Observed shape:
  - Real user prompt: `{"type":"user","message":{"role":"user","content":"<string>"}}` with `isMeta` absent/false; content may also be an array of `{"type":"text","text":...}` blocks. **Not real prompts**: `isMeta: true`; content arrays of `tool_result` blocks; text starting with `<task-notification`, `<system-reminder`, `<command-name`, `<command-message`, `<local-command`, `Caveat:`.
  - Assistant: `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":...} | {"type":"thinking",...} | {"type":"tool_use","name":"Edit","input":{"file_path":...}}]}}`.
  - File edits: tool_use names `Edit`, `Write`, `MultiEdit`, `NotebookEdit` with `input.file_path` (or `notebook_path`).
  - Task lists: `TodoWrite` → `input.todos[]` `{content,status,activeForm}`; `TaskCreate` → `input.subject`/`input.description`; `TaskUpdate` → `input.taskId`,`input.status`; any tool whose name ends with `update_plan` → `input.items[]` `{content,status}` (full list) or `{advance:true}` (advance in_progress to next). Use the LAST full list seen; apply later `advance` steps to it.
  - Bash commands: tool_use `Bash` → `input.command` (+ optional `input.description`).
  - Other line types (`attachment`, `system`, `api-request`, `file-history-*`, `custom-title`, `last-prompt`...) → ignore. `last-prompt` lines have `lastPrompt` — may be used as fallback for the latest prompt.

## Hard constraints
- **bash 3.2 compatible** (macOS `/bin/bash`): no associative arrays, no `mapfile`/`readarray`, no `${var,,}`, no `|&`, no `&>>`. Shebang `#!/usr/bin/env bash`. `set -u` is fine; do NOT use `set -e` in hooks (a hook must never die half-way); always `exit 0` from hooks.
- Dependencies: `jq` (required for transcript parsing and installer; if missing, hooks degrade: still write the cut-off marker and a basic prompt using `$PWD`/`$CLAUDE_PROJECT_DIR`, and log "jq missing"). Optional: `pbcopy`|`wl-copy`|`xclip`|`xsel`|`clip.exe`; `osascript`|`notify-send`|`terminal-notifier`.
- Fast: StopFailure hook must finish < 2 s on a 50 MB transcript → only read the tail: `tail -n 4000 "$transcript"` (configurable) piped to jq; never slurp the whole file.
- Safe: never `eval` or `source` content from transcripts, HANDOFF.md or config. Config file is parsed line by line (`KEY=VALUE`, keys must match `^LIMIT_HANDOFF_[A-Z_]+$`). Quote every path (spaces!). Write files atomically (write tmp in same dir, then `mv`). Never write outside the project dir except the kit's state dir.
- Idempotent: running the StopFailure hook twice for the same `session_id` must not add a second cut-off block (update the timestamp inside the existing block instead).
- All user-facing text in plain English.

## Layout
```
bin/limit-handoff                 CLI (bash)
hooks/stop-failure.sh           StopFailure
hooks/prompt-submit.sh          UserPromptSubmit
hooks/session-start.sh          SessionStart
hooks/pre-compact.sh            PreCompact
lib/common.sh                   shared functions (sourced by all scripts; locate via dirname of BASH_SOURCE)
lib/transcript.jq               jq program: transcript tail -> recovered-context JSON
templates/HANDOFF.template.md
templates/paste-prompt.txt
templates/claude-md-snippet.md  the "keep HANDOFF.md current" rules to paste into CLAUDE.md
skills/handoff/SKILL.md         generic /handoff skill (no personal paths)
.claude-plugin/plugin.json      plugin manifest
hooks/hooks.json                plugin hooks (uses "${CLAUDE_PLUGIN_ROOT}")
config/limit-handoff.conf.example
tests/run.sh                    test runner (pure bash): runs tests/test_*.sh, prints PASS/FAIL, exit non-zero on failure
tests/lib.sh                    assert helpers: assert_eq, assert_contains, assert_not_contains, assert_file_exists, assert_exit
tests/shims/                    fake pbcopy, osascript, notify-send, wl-copy writing to $TEST_OUT/clipboard.txt / notify.txt
tests/fixtures/*.jsonl          synthetic transcripts (no real user data!)
tests/test_*.sh
README.md, LICENSE (MIT), CHANGELOG.md
```

## Config (env var > project `.claude/limit-handoff.conf` > user `~/.config/limit-handoff/config` > default)
| key | default | meaning |
|---|---|---|
| LIMIT_HANDOFF_FILE | HANDOFF.md | handoff file name (relative to project dir) |
| LIMIT_HANDOFF_PROMPT_FILE | PASTE-PROMPT.txt | paste prompt file name (relative to project dir) |
| LIMIT_HANDOFF_STATE_DIR | `${CLAUDE_PLUGIN_DATA:-$HOME/.local/state/limit-handoff}` | logs + per-session state |
| LIMIT_HANDOFF_RECOVER_DIR | .handoff | folder in project dir for recovered-context files |
| LIMIT_HANDOFF_TAIL_LINES | 4000 | transcript lines to read |
| LIMIT_HANDOFF_PROMPTS | 5 | last N user prompts to recover |
| LIMIT_HANDOFF_CLIPBOARD | auto | auto / off / command name |
| LIMIT_HANDOFF_NOTIFY | auto | auto / off |
| LIMIT_HANDOFF_REMIND | stale | always / stale / off |
| LIMIT_HANDOFF_STALE_MIN | 20 | minutes before HANDOFF.md counts as stale |
| LIMIT_HANDOFF_CREATE_IF_MISSING | 1 | create HANDOFF.md from transcript when missing |
Tests set `HOME` and `XDG_*` to temp dirs.

## lib/common.sh functions (names fixed)
`hk_log level msg` (append ISO timestamp line to `$STATE_DIR/limit-handoff.log`), `hk_conf KEY default` (resolution order above), `hk_read_input` (reads stdin JSON into `HK_INPUT`; extracts `HK_CWD`, `HK_SESSION`, `HK_TRANSCRIPT`, `HK_ERROR`, `HK_SOURCE` with jq; empty when absent), `hk_project_dir` (CLAUDE_PROJECT_DIR > input cwd > PWD; must be an existing directory), `hk_now_iso`, `hk_now_human` (`YYYY-MM-DD HH:MM`), `hk_atomic_write path` (stdin → tmp → mv), `hk_copy_clipboard text`, `hk_notify title body`, `hk_file_age_min path` (portable: `stat -f %m` on macOS, `stat -c %Y` on Linux), `hk_has_unresolved_cutoff file`, `hk_first_next_step file` (first list item under a heading matching `^## Next steps` until next `## `; strip leading `1. `/`- `/`* `/checkbox; empty if none), `hk_render_template file KEY=VAL...` (replace `{{KEY}}` safely — use awk or bash parameter expansion, not sed with unescaped user data).

## Recovered context (lib/transcript.jq)
Input: transcript tail lines (use `jq -R 'fromjson?'` per line so broken lines are skipped, then `-s` slurp). Output JSON:
```json
{"first_prompt": "...", "last_prompts": ["...", "..."], "last_assistant_text": "...",
 "tasks": [{"content":"...","status":"completed|in_progress|pending"}],
 "files_touched": ["/abs/a.py", "..."], "last_commands": [{"command":"...","description":"..."}],
 "line_count": 1234}
```
Rules: prompts deduplicated consecutively, each truncated to 600 chars (append `…`); last_assistant_text = last assistant `text` block, truncated 800; files unique in last-touched order, max 20; commands last 5, each truncated 200. `first_prompt` = first real user prompt within the tail (note in docs that a very long session may have scrolled the true first prompt out of the tail).

Recovered markdown file: `<project>/.handoff/recovered-<YYYYmmdd-HHMMSS>-<session8>.md` with sections: `# Recovered context`, metadata (session id, error, time, transcript path), `## Last things you asked`, `## Task list at cut-off` (checkbox list: `[x]` completed, `[~]` in progress, `[ ]` pending), `## Files touched (most recent first)`, `## Last commands`, `## Last assistant message`. Also update `<project>/.handoff/LATEST.md` (copy). Add `.handoff/` hint to README (users may gitignore it).

## hooks/stop-failure.sh
1. Read input; project dir; if `HK_ERROR` is non-empty and NOT in the configured list `LIMIT_HANDOFF_ERRORS` (default `rate_limit billing_error unknown overloaded server_error`), log and exit 0.
2. Build recovered context (if jq + transcript readable) → recovered file.
3. If HANDOFF.md exists → upsert cut-off block at the end:
```
<!-- limit-handoff:cutoff session="<id>" at="<iso>" error="<error>" status="unresolved" -->
> ⚠️ **Session cut off** (<human reason>) at <human time>. The steps above may be slightly behind.
> Check the files for a half-finished step before continuing. Recovered context: `.handoff/recovered-....md`
<!-- /limit-handoff:cutoff -->
```
   Human reasons: rate_limit → "rate or usage limit reached" ("usage limit reached" when limit details are known, see DECISIONS 184), billing_error → "billing/credit limit", overloaded → "API overloaded", server_error → "API server error", unknown → "unknown API error", other → error value.
   If a block for this session exists → replace it (same session id) instead of appending. Blocks from other sessions stay.
4. If missing and CREATE_IF_MISSING=1 → create from `templates/HANDOFF.template.md`: Goal ← first_prompt; Status ← "cut off (<reason>) at <time> — auto-created by limit-handoff from the transcript; verify before trusting"; Done so far ← completed tasks + files touched; Next steps ← in_progress then pending tasks (numbered), else "Read the recovered context file named in the cut-off block, then confirm the goal with the user". The recent messages are not copied into the created file (they can hold secrets); the status line says to check the file before committing it; plus the cut-off block.
5. Paste prompt from `templates/paste-prompt.txt`. Its parts are built in `hk_paste_text`: `{{PROJECT_DIR}}`, `{{WHY}}` ("My last chat stopped (<reason>).", or for a manual handoff "I am moving this work to a new chat on purpose."), `{{READ}}` (names HANDOFF.md only when it exists, and the recovered file only when one was written; with neither: "There is no HANDOFF.md or recovered file for this stop."), `{{NEXT}}` ("start with: <next step>", or when there is no next step: read the recovered file, work out the next step, and say what it is before any change), `{{KEEP}}` ("Keep HANDOFF.md updated as you work." only when HANDOFF.md exists). Default template text:
   `Continue my task in {{PROJECT_DIR}}. My last chat stopped (<reason>). First read <HANDOFF.md> fully — it has the goal, what is done, decisions, and the exact next steps. Then read <recovered file> for the last messages before the cut-off. Check the files for any half-finished step, then start with: <next step>. Do not redo finished steps. Keep HANDOFF.md updated as you work.`
6. Write PASTE-PROMPT.txt (atomic), copy to clipboard, notify (title "Claude Code stopped: <reason>"; the body says what was saved and where, then "Paste it into a new chat."; see hooks/stop-failure.sh). Log every step. Exit 0 always — wrap the main body in a function and `trap 'exit 0' ERR`.

## hooks/prompt-submit.sh
- If no HANDOFF.md → print nothing.
- If unresolved cut-off block exists → print: `HANDOFF.md has an unresolved cut-off from a previous session (<time>, <reason>). Read HANDOFF.md and <recovered file> before anything else, check for a half-finished step, then run \`limit-handoff resolve\` (or delete the cut-off block) once recovered.`
- Else per REMIND mode: `always` → original reminder text: `HANDOFF.md exists here. Read it if you have not yet. Update it after each step so a usage-limit cut-off loses nothing.`; `stale` → print reminder only on the first prompt of a session (track `$STATE_DIR/sessions/<session_id>.seen`) OR when file age ≥ STALE_MIN minutes, and then include the age: `HANDOFF.md was last updated N minutes ago. ...`; `off` → nothing.

## hooks/session-start.sh
- source `compact` and HANDOFF.md exists → print: context was compacted; re-read HANDOFF.md before continuing.
- unresolved cut-off exists (any source) → print the recovery instruction (as above) plus the first next step.
- `startup`/`resume` with a fresh HANDOFF.md → print one line: `This project has HANDOFF.md (updated N min ago). Read it before starting.`
- Otherwise nothing.

## hooks/pre-compact.sh
- Writes a recovered-context snapshot (`recovered-...-precompact.md`) only; prints nothing; exit 0.

## bin/limit-handoff
```
limit-handoff install   --settings <path/to/settings.json> [--errors "rate_limit|billing_error|unknown"] [--events stop-failure,prompt-submit,session-start,pre-compact] [--dry-run]
limit-handoff uninstall --settings <path>
limit-handoff status    [--settings <path>] [--dir <project>]
limit-handoff prompt    [--dir <project>] [--no-copy]          # build + print + copy the paste prompt now (manual handoff)
limit-handoff recover   --transcript <file.jsonl> [--dir <project>] [--stdout]
limit-handoff resolve   [--dir <project>] [--session <id>]     # mark cut-off blocks status="resolved" (keeps history)
limit-handoff simulate  [--dir <project>] [--error rate_limit] [--transcript f]   # feed a fake StopFailure payload to the hook
limit-handoff doctor                                         # checks jq, bash version, clipboard, notifier, state dir writable
limit-handoff --help | --version
```
- `install`: requires `--settings` explicitly (no implicit default path — print the suggested path `~/.claude/settings.json` in help, but never write unless passed). Creates file if missing (`{}`), makes timestamped backup `<file>.bak-YYYYmmddHHMMSS` before changing an existing file, merges hook groups with jq without touching other keys/hooks, idempotent (detects existing kit entries by command containing `limit-handoff` path marker `/hooks/stop-failure.sh` etc. and replaces them), uses absolute path of the kit's hooks, `timeout`: stop-failure 30, prompt-submit 5, session-start 20, pre-compact 30 (the same numbers as hooks/hooks.json). `--dry-run` prints the resulting JSON diff-ish (old vs new) and writes nothing. Validate JSON before and after; on invalid input JSON → error, exit 2, write nothing.
- `uninstall`: removes only kit entries; removes empty groups/events; backup first.
- `status`: lists installed kit hooks found in settings, HANDOFF.md presence/age/unresolved cut-offs, last 5 log lines.
- Exit codes: 0 ok, 1 operational failure, 2 usage error.

## Tests (tests/run.sh must pass with `/bin/bash tests/run.sh` on macOS bash 3.2)
Each test runs in a fresh temp dir with `HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, `CLAUDE_PROJECT_DIR`, `PATH` (shims first) set; never touch real HOME. At least:
- stop-failure: existing HANDOFF.md gets one block; second run same session → still one block, timestamp updated; different session → two blocks; missing HANDOFF.md → created with goal from first prompt, tasks as next steps; CREATE_IF_MISSING=0 → not created but prompt still written; error not in list → nothing written; clipboard shim received prompt; notifier shim called; PASTE-PROMPT.txt content contains project path, next step, recovered file; paths with spaces; no transcript_path / unreadable transcript → still works; malformed JSON lines in transcript skipped; jq missing (PATH without jq — create shim dir without jq; ensure the hook still exits 0 and writes the marker); always exit 0 even when project dir is read-only.
- transcript parsing: isMeta/system-reminder/task-notification/tool_result excluded; TodoWrite list; update_plan list + advance; Edit/Write/MultiEdit/NotebookEdit file paths; Bash commands; truncation; text block arrays.
- prompt-submit: no file → silent; always/stale/off modes; first prompt of session reminds, second doesn't (stale mode, fresh file); old file (touch -t) reminds with age; unresolved cut-off → recovery instruction.
- session-start: compact; unresolved; startup fresh; nothing.
- next-step parsing: numbered, bullets, checkboxes, no section.
- CLI install: new file; existing settings with other hooks preserved (byte-compare unrelated keys via jq); idempotent (twice → same); backup created; dry-run writes nothing; invalid JSON → exit 2 unchanged; uninstall removes only kit entries; resolve marks blocks; prompt command; recover --stdout; doctor exit 0; simulate end-to-end.
- Security: transcript text containing `$(rm -rf /)`, backticks, `{{PROJECT_DIR}}` and `%s` appears literally in outputs and is never executed; LIMIT_HANDOFF_FILE=../../etc/passwd rejected (must stay inside project dir).
- Plugin: `hooks/hooks.json` and `.claude-plugin/plugin.json` are valid JSON (jq empty) and every referenced script exists and is executable.

## README must include
What it does (before/after story), install as plugin vs. as settings hooks (`limit-handoff install --settings ~/.claude/settings.json`), what happens on a cut-off (diagram), files it writes, config table, the CLAUDE.md snippet, privacy (everything local, nothing sent anywhere), limitations (transcript format is internal and may change; StopFailure output ignored by Claude Code so the kit only does side effects; no hook fires if the app is killed), comparison with alternatives (auto-retry/auto-continue hooks resume the SAME session; this hands off to a NEW chat/account), license MIT.

## Definition of done
`/bin/bash tests/run.sh` → all PASS on macOS bash 3.2; `bin/limit-handoff doctor` exits 0; `bin/limit-handoff simulate --dir <tmp>` produces HANDOFF.md block + PASTE-PROMPT.txt + recovered file; README complete.
