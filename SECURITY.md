# Security policy

limit-handoff runs as Claude Code hooks, which run with your full user permissions. Security reports are taken seriously.

## Reporting a problem

Please **do not** open a public issue for a security problem.

Report it privately through GitHub: [Report a vulnerability](https://github.com/nicholas-a-saunders/limit-handoff/security/advisories/new).

Please include:

- what an attacker can do, and what they need first (for example, "a cloned repository with a crafted `HANDOFF.md`");
- the steps or a small test that shows it;
- the limit-handoff version, Claude Code version, and operating system.

This is a one-person project. You can expect a first reply within 7 days. A fix for a confirmed problem is aimed for within 30 days, and you will be credited in the release notes unless you ask not to be.

## Supported versions

Only the latest release gets security fixes.

## What counts as a security problem

The kit promises the following. A way to break any of these is a security problem:

- Text from a transcript, `HANDOFF.md`, a config file, git output, or a hook payload is never run as code.
- A project's own files (`.claude/limit-handoff.conf`, `HANDOFF.md`, a cut-off block) cannot choose a program to run, cannot make the kit write outside the project or its state folder, and cannot inject arbitrary text into Claude's context through the kit's hook output. The one exception is on purpose: the "first next step" line from `HANDOFF.md` is shown to Claude (see Out of scope).
- The kit makes no network calls and sends nothing anywhere.
- `install` and `uninstall` never remove settings or hooks they did not add, and always back up a settings file before changing it.
- Hooks always exit 0 and never block Claude Code.

## Out of scope

- Anything that needs the attacker to already control your user account, your `~/.claude/settings.json`, or your user config file `~/.config/limit-handoff/config`.
- The content of your own handoff files. The "first next step" line from `HANDOFF.md` is shown to Claude on purpose. Keep handoff files in projects you trust.
- Bugs in Claude Code itself. Report those to Anthropic.
