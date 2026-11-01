#!/bin/bash
# Tests for hooks/session-start.sh (SessionStart).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

start_run() {
  # start_run source: runs the SessionStart hook with the given source value.
  local payload
  payload="$(tl_payload_plain SessionStart "ss-sess" "$CLAUDE_PROJECT_DIR" "$1")"
  tl_run "$TL_HOOK_SESSION" "$payload"
}

test_no_handoff_is_silent_for_every_source() {
  local s
  for s in startup resume compact clear; do
    start_run "$s"
    assert_exit 0 "$TL_RC"
    assert_eq "" "$TL_OUT" "source $s without HANDOFF.md should be silent"
  done
}

test_compact_asks_to_reread() {
  printf '%s\n' '# H' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  touch -t 202001010000 "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  start_run "compact"
  assert_contains "$TL_OUT" "This session was compacted. Re-read HANDOFF.md before continuing."
}

test_startup_with_fresh_file_announces_it() {
  printf '%s\n' '# H' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  start_run "startup"
  assert_contains "$TL_OUT" "This project has HANDOFF.md (updated 0 min ago). Read it before starting."
  start_run "resume"
  assert_contains "$TL_OUT" "This project has HANDOFF.md" "resume too"
}

test_startup_with_old_file_is_silent() {
  printf '%s\n' '# H' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  touch -t 202001010000 "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  start_run "startup"
  assert_eq "" "$TL_OUT" "old file is not fresh"
}

test_clear_source_is_silent_for_fresh_file() {
  printf '%s\n' '# H' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  start_run "clear"
  assert_eq "" "$TL_OUT"
}

test_unresolved_cutoff_gives_instruction_and_next_step() {
  local p="$CLAUDE_PROJECT_DIR"
  {
    printf '%s\n' '# H' '## Next steps' '1. Finish the password check' ''
    printf '%s\n' '<!-- limit-handoff:cutoff session="x" at="2026-10-29T10:00:00Z" error="billing_error" status="unresolved" -->' \
      '> ⚠️ **Session cut off** (billing/credit limit) at 2026-10-29 10:00. The steps above may be slightly behind.' \
      '> Check the files for a half-finished step before continuing. Recovered context: `.handoff/recovered-x.md`' \
      '<!-- /limit-handoff:cutoff -->'
  } > "$p/HANDOFF.md"
  start_run "startup"
  assert_contains "$TL_OUT" "unresolved cut-off from a previous session (2026-10-29 10:00, billing/credit limit)"
  assert_contains "$TL_OUT" ".handoff/recovered-x.md"
  assert_contains "$TL_OUT" "First next step: Finish the password check"
}

test_unresolved_is_reported_on_resume_and_compact_too() {
  local p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# H' '<!-- limit-handoff:cutoff session="x" at="2026-10-29T10:00:00Z" error="rate_limit" status="unresolved" -->' \
    '> ⚠️ **Session cut off** (usage limit reached) at 2026-10-29 10:00. The steps above may be slightly behind.' \
    '> Check the files. Recovered context: `.handoff/r.md`' '<!-- /limit-handoff:cutoff -->' > "$p/HANDOFF.md"
  start_run "resume"
  assert_contains "$TL_OUT" "unresolved cut-off"
  start_run "compact"
  assert_contains "$TL_OUT" "This session was compacted."
  assert_contains "$TL_OUT" "unresolved cut-off" "both messages when both apply"
}

test_session_start_exits_zero_on_garbage() {
  tl_run "$TL_HOOK_SESSION" "[]"
  assert_exit 0 "$TL_RC"
}

run_tests
