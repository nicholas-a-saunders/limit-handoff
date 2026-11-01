#!/bin/bash
# test_attack_spec_cli.sh - adversarial SPEC conformance tests for the day-to-day CLI commands
# (status, prompt, recover, resolve, simulate, doctor).
# Each test names the docs/SPEC.md section it checks.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# SPEC (bin/limit-handoff status): shows the handoff age, the unresolved cut-off count and the last log
# lines. Passing regression guard.
test_attack_spec_status_counts_unresolved_cutoffs() {
  local p; p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# H' > "$p/HANDOFF.md"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "st-one" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "st-two" "$(tl_fixture basic.jsonl)" "$p" "billing_error")"
  tl_kit status --dir "$p"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "Unresolved cut-offs: 2" "two sessions, two unresolved blocks"
  assert_contains "$TL_OUT" "last updated 0 min ago" "age is shown"
  assert_contains "$TL_OUT" "limit-handoff.log" "last log lines are shown"
}

# SPEC (bin/limit-handoff resolve): marks the blocks resolved and keeps the history (the block stays in
# the file). Passing regression guard.
test_attack_spec_resolve_keeps_block_history() {
  local p; p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# H' > "$p/HANDOFF.md"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "rs-one" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  tl_kit resolve --dir "$p"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" 'session="rs-one" at="' "the block must still be there"
  assert_file_contains "$p/HANDOFF.md" 'status="resolved"' "its status must now be resolved"
  assert_file_not_contains "$p/HANDOFF.md" 'status="unresolved"' "no unresolved status may remain"
  assert_file_contains "$p/HANDOFF.md" "(usage limit reached)" "the block text is kept"
}

# SPEC (bin/limit-handoff prompt): builds the paste prompt now, prints it, copies it unless --no-copy,
# and writes PASTE-PROMPT.txt. Passing regression guard.
test_attack_spec_prompt_no_copy_prints_and_saves_without_clipboard() {
  local p; p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# H' '' '## Next steps' '1. Finish the parser' > "$p/HANDOFF.md"
  tl_use_clipboard
  tl_kit prompt --dir "$p" --no-copy
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "start with: Finish the parser." "the next step is in the printed prompt"
  assert_file_exists "$p/PASTE-PROMPT.txt"
  assert_file_missing "$TEST_OUT/clipboard.txt" "--no-copy must not call the clipboard"
}

# SPEC (bin/limit-handoff recover --stdout): prints the recovered markdown and writes nothing.
# Passing regression guard.
test_attack_spec_recover_stdout_writes_nothing() {
  local p; p="$CLAUDE_PROJECT_DIR"
  tl_kit recover --transcript "$(tl_fixture basic.jsonl)" --dir "$p" --stdout
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "# Recovered context" "markdown is printed"
  assert_file_missing "$p/.handoff" "--stdout must not create the recovered folder"
}

# SPEC (bin/limit-handoff simulate): produces the HANDOFF.md block, PASTE-PROMPT.txt and the recovered
# file in the given folder (Definition of done). Passing regression guard.
test_attack_spec_simulate_produces_all_three_outputs() {
  local p; p="$TL_TMP/sim project"
  mkdir -p "$p"
  tl_kit simulate --dir "$p"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "limit-handoff:cutoff session=\"simulated-" "cut-off block"
  assert_file_exists "$p/PASTE-PROMPT.txt"
  local n
  n="$(ls "$p/.handoff" 2>/dev/null | grep -c '^recovered-.*\.md$')"
  assert_eq "1" "$n" "one recovered file"
}

# SPEC (bin/limit-handoff doctor): exit 0 on a normal setup. Passing regression guard.
test_attack_spec_doctor_exits_zero_on_normal_setup() {
  tl_kit doctor
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "jq " "jq version line"
}

run_tests
