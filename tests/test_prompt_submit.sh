#!/bin/bash
# Tests for hooks/prompt-submit.sh (UserPromptSubmit reminder).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

prompt_run() {
  # prompt_run session: sends a UserPromptSubmit payload for this project.
  local payload
  payload="$(tl_payload_plain UserPromptSubmit "$1" "$CLAUDE_PROJECT_DIR" "")"
  tl_run "$TL_HOOK_PROMPT" "$payload"
}

test_no_handoff_file_is_silent() {
  prompt_run "s1"
  assert_exit 0 "$TL_RC"
  assert_eq "" "$TL_OUT" "no HANDOFF.md means no output"
}

test_always_mode_reminds_every_prompt() {
  export LIMIT_HANDOFF_REMIND=always
  printf '%s\n' '# H' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  prompt_run "a1"
  assert_contains "$TL_OUT" "HANDOFF.md exists here. Read it if you have not yet."
  prompt_run "a1"
  assert_contains "$TL_OUT" "HANDOFF.md exists here." "always mode repeats"
}

test_off_mode_is_silent() {
  export LIMIT_HANDOFF_REMIND=off
  printf '%s\n' '# H' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  prompt_run "o1"
  assert_eq "" "$TL_OUT"
}

test_stale_mode_first_prompt_reminds_second_does_not() {
  printf '%s\n' '# H' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  prompt_run "same-session"
  assert_contains "$TL_OUT" "HANDOFF.md was last updated 0 minutes ago." "first prompt of a session reminds"
  prompt_run "same-session"
  assert_eq "" "$TL_OUT" "second prompt in the same session is silent for a fresh file"
  prompt_run "other-session"
  assert_contains "$TL_OUT" "last updated" "a new session reminds again"
}

test_stale_mode_old_file_reminds_with_age() {
  printf '%s\n' '# H' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  touch -t 202001010000 "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  prompt_run "old-a"
  prompt_run "old-a"
  assert_contains "$TL_OUT" "HANDOFF.md was last updated" "old file reminds even in a seen session"
  local mins; mins="$(printf '%s' "$TL_OUT" | sed -n 's/.*updated \([0-9]*\) minutes ago.*/\1/p')"
  [ "${mins:-0}" -gt 100000 ] || fail "age should be large for a 2020 file, got '$mins'"
}

test_stale_minutes_setting_is_used() {
  printf '%s\n' '# H' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  touch -t "$(date -v-30M '+%Y%m%d%H%M' 2>/dev/null || date -d '-30 min' '+%Y%m%d%H%M')" "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  export LIMIT_HANDOFF_STALE_MIN=60
  prompt_run "min-a"
  prompt_run "min-a"
  assert_eq "" "$TL_OUT" "a 30 minute old file is fresh when the limit is 60"
  export LIMIT_HANDOFF_STALE_MIN=10
  prompt_run "min-a"
  assert_contains "$TL_OUT" "last updated" "a 30 minute old file is stale when the limit is 10"
}

test_unresolved_cutoff_gives_recovery_instruction() {
  local p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# H' '' "$(hk_block_for_test)" > "$p/HANDOFF.md"
  export LIMIT_HANDOFF_REMIND=off
  prompt_run "cut-a"
  assert_contains "$TL_OUT" "HANDOFF.md has an unresolved cut-off from a previous session" "recovery message"
  assert_contains "$TL_OUT" "usage limit reached" "reason is named"
  assert_contains "$TL_OUT" ".handoff/recovered-20261029-100000-cut.md" "recovered file is named"
  assert_contains "$TL_OUT" "limit-handoff resolve" "resolve command is named"
}

test_unresolved_cutoff_wins_even_when_stale_mode_is_quiet() {
  local p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# H' "$(hk_block_for_test)" > "$p/HANDOFF.md"
  touch -t 202001010000 "$p/HANDOFF.md"
  prompt_run "cut-b"
  assert_contains "$TL_OUT" "unresolved cut-off" "cut-off message shown regardless of age"
  assert_not_contains "$TL_OUT" "last updated" "no separate age reminder when cut-off is shown"
}

test_resolved_cutoff_is_not_reported() {
  local p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# H' "$(hk_block_for_test | sed 's/status="unresolved"/status="resolved"/')" > "$p/HANDOFF.md"
  export LIMIT_HANDOFF_REMIND=off
  prompt_run "res-a"
  assert_eq "" "$TL_OUT"
}

test_prompt_hook_exits_zero_on_garbage() {
  printf '%s\n' '# H' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  tl_run "$TL_HOOK_PROMPT" "not json"
  assert_exit 0 "$TL_RC"
}

# hk_block_for_test: one unresolved cut-off block as the stop hook writes it.
hk_block_for_test() {
  printf '%s\n' '<!-- limit-handoff:cutoff session="cut" at="2026-10-29T10:00:00Z" error="rate_limit" status="unresolved" -->' \
    '> ⚠️ **Session cut off** (usage limit reached) at 2026-10-29 10:00. The steps above may be slightly behind.' \
    '> Check the files for a half-finished step before continuing. Recovered context: `.handoff/recovered-20261029-100000-cut.md`' \
    '<!-- /limit-handoff:cutoff -->'
}

run_tests
