# Contributing

Thanks for helping. This file says how to run the tests, what the code rules are, and what kind of change fits the project.

## Run the tests

You need bash (3.2 or newer) and jq. git is optional (the git tests skip without it).

```bash
/bin/bash tests/run.sh
```

The run ends with `RESULT: PASS`. Every test gets its own temporary `HOME`, config and state folders, and fake clipboard and notification tools from `tests/shims/`. The tests never touch your real home folder, Claude Code settings or clipboard.

To try the hooks by hand without touching anything real:

```bash
bin/limit-handoff simulate --dir "$(mktemp -d)"
```

CI runs the suite on macOS (`/bin/bash` 3.2) and Ubuntu (bash 5), runs [ShellCheck](https://github.com/koalaman/shellcheck) on the shipped scripts, and runs `claude plugin validate --strict`. If you have ShellCheck locally:

```bash
shellcheck --shell=bash --severity=warning --external-sources bin/limit-handoff hooks/*.sh lib/common.sh
```

Run it from the repository root. The settings it needs (`external-sources` and `source-path`) are in `.shellcheckrc` at the root, so the same command gives the same result in CI and on your machine. Each `# shellcheck source=lib/common.sh` line sits directly above the dynamic `source` line it describes.

## Code rules

These keep the hooks safe to run on every Claude Code session.

- **bash 3.2 only.** macOS ships it. No associative arrays, `mapfile`, `${var,,}`, `|&` or `&>>`.
- **Hooks never fail.** No `set -e` in hooks. Every hook ends with `exit 0`, and its main body runs as `main || true`.
- **Text is data, never code.** No `eval`. Never `source` anything except `lib/common.sh`. Never use data as a `printf` format. Quote every variable.
- **Sanitise what you show.** Text from a transcript, `HANDOFF.md`, git or a hook payload goes through the existing checks (`hk_clean_token`, `hk_known_code`, `hk_shown_path_ok`, the `fence_for` rule) before it reaches a file, a notification or hook output.
- **Write files atomically** with `hk_atomic_write`.
- **No network, no telemetry.** The kit runs only local tools: `jq`, `git` (read-only commands), the clipboard tool and the notification tool.
- **Every change has a test.** Put it in `tests/test_<topic>.sh`, next to the existing ones. Use synthetic fixtures only, never a real transcript.
- **Match the style.** `hk_` function names, a short plain-English comment above each function, `LIMIT_HANDOFF_*` config keys added to `config/limit-handoff.conf.example`.

Design choices and the reasons for them are in [docs/DECISIONS.md](docs/DECISIONS.md). Please add an entry when you make a new one.

## Scope

limit-handoff does one job: when Claude Code stops on a limit, leave everything a **new** chat needs to carry on, and make sure that chat picks it up.

Good fits: better recovery from the transcript, more reliable triggers, clearer messages, more platforms, fewer surprises.

Not planned:

- Waiting for a limit to reset and continuing the same session. Claude Code does this itself now (`autoContinueAtUsageLimit`).
- Switching accounts, storing credentials, or calling any API.
- Sending data anywhere, including "anonymous" usage data.
- Summarising the chat with a model. The kit only copies what the transcript shows.

If you are unsure, open a feature request first and describe the problem.

## Pull requests

1. Fork, branch, change, and add a test.
2. Run `/bin/bash tests/run.sh`.
3. Add a line under "Unreleased" in `CHANGELOG.md` if users will notice the change.
4. Open the pull request and fill in the checklist.

Small pull requests are reviewed faster. Replies usually come within a week.

## Releases (maintainer)

1. Move the "Unreleased" notes in `CHANGELOG.md` under a new version heading, `## [x.y.z] - YYYY-MM-DD`.
2. Set the same version in `.claude-plugin/plugin.json` and in `HK_VERSION` in `lib/common.sh`. The CLI prints `HK_VERSION`, and the tests and the release workflow fail if the two differ.
3. Commit, then tag `vx.y.z` and push the tag. The release workflow tests the tag, checks the version, builds the tarball with a provenance attestation, and publishes the GitHub Release.
