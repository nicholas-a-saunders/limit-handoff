## What this changes and why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `/bin/bash tests/run.sh` passes on macOS (bash 3.2) or I explain why I could not run it.
- [ ] New behaviour has a test in `tests/`.
- [ ] Hooks still exit 0 on every path and never block Claude Code.
- [ ] No `eval`, no `source` of user text, every variable quoted, bash 3.2 syntax only.
- [ ] No new network calls, telemetry, or writes outside the project and the state folder.
- [ ] README.md and CHANGELOG.md ("Unreleased") are updated if users will notice the change.
