## Keep HANDOFF.md current

For any task with more than one or two steps, or any task that edits files:

1. At the start, create or read `HANDOFF.md` in the project root. If it exists, read it first and continue from it.
2. Keep it accurate, not long. Update it after each finished step, before any long or risky action, when the goal changes, and before the final reply.
3. Keep these headings: Goal, Status, Done so far, Next steps (in order), Key decisions & user preferences, Important facts / findings, Open questions / risks, Paste prompt (for a new chat).
4. Keep the current paste prompt at the bottom of `HANDOFF.md`, in this form:
   `Continue my task in <project folder>. First read <HANDOFF.md path> fully. Do not redo finished steps. Start with next step 1: <the step>. Keep updating HANDOFF.md as you work.`
5. If a `Session cut off` block appears in `HANDOFF.md`, read it and the recovered context file it names. Check the files for a half-finished step before you continue. Then run `limit-handoff resolve`.
