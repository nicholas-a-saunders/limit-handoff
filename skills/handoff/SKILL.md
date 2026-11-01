---
name: handoff
description: Save the full task state to HANDOFF.md and print a paste prompt so a new chat (any account, same files) can continue the work. Use when the user types /handoff, says "handoff", "limit", or "new chat", or when the session or context limit is near.
---

# Handoff

Goal: a fresh chat, even on another account, can continue the work with no loss of context.

## Steps

1. Find `HANDOFF.md` in the root of the project folder. If it exists, read it first and continue from it.
2. Write or update it. Keep these headings, in this order: Goal, Status, Done so far, Next steps (in order), Key decisions & user preferences, Important facts / findings, Open questions / risks, Paste prompt (for a new chat).
   - Goal: what the user wants, in their words, plus success criteria.
   - Status: one line. In progress, blocked, or done.
   - Done so far: each finished step, with the result and the file paths touched.
   - Next steps: the exact next action first.
   - Keep it accurate and short. Replace stale lines. Do not just append.
3. Update the paste prompt at the bottom of the file. Use this form, with real paths:

   > Continue my task in `<absolute project folder>`. First read `<absolute path>/HANDOFF.md` fully — it has the goal, what is done, decisions, and the exact next steps. Do not redo finished steps. Start with next step 1: <the step>. Keep updating HANDOFF.md as you work.

4. Print the paste prompt in a code block in your reply, with one line above it that says `[paste prompt]`.

## Notes

- Do not put secrets, tokens or passwords in `HANDOFF.md`.
- A `HANDOFF.md` that limit-handoff created by itself holds no copy of your recent messages (they stay in the git-ignored recovered file), and token-shaped strings are redacted. It is still made from chat text: check it before you commit it.
- If a `Session cut off` block is in the file, read the recovered context file it names and check for a half-finished step first.
