#!/bin/bash
# Tests for hooks/stop-failure.sh (the StopFailure hook).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# run_stop sid transcript cwd error: sends a StopFailure payload to the hook.
run_stop() {
  local payload
  payload="$(tl_payload_stop "$1" "$2" "$3" "$4")"
  tl_run "$TL_HOOK_STOP" "$payload"
}

project() {
  [ -n "$CLAUDE_PROJECT_DIR" ] || fail "CLAUDE_PROJECT_DIR is empty; refusing to continue"
  printf "%s\n" "$CLAUDE_PROJECT_DIR"
}

recovered_for() {
  # recovered_for project session8: prints the newest recovered file for that session.
  ls -t "$1/.handoff"/recovered-*"$2"*.md 2>/dev/null | head -n 1
}

test_appends_block_to_existing_handoff() {
  local p; p="$(project)"
  printf '%s\n' '# My handoff' '' '## Next steps' '1. Keep going' > "$p/HANDOFF.md"
  run_stop "sess-one" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "# My handoff" "user content must stay"
  assert_count "$p/HANDOFF.md" 'session="sess-one"' 1 "one cut-off block"
  assert_file_contains "$p/HANDOFF.md" 'status="unresolved"'
  assert_file_contains "$p/HANDOFF.md" "(rate or usage limit reached)"
  assert_file_contains "$p/HANDOFF.md" "Recovered context: \`.handoff/recovered-"
  assert_file_exists "$(recovered_for "$p" "sess-one")"
}

test_same_session_twice_gives_one_block_with_new_time() {
  local p; p="$(project)"
  # The repeat must be handled to refresh the time, so the de-duplication window is turned off here.
  # The window itself is tested in tests/test_catchup.sh.
  export LIMIT_HANDOFF_DEBOUNCE_SEC=0
  printf '%s\n' '# H' > "$p/HANDOFF.md"
  run_stop "dup-session" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  # Plant an old time in the block (sed -i differs between BSD and GNU, so write a temp file and move it).
  sed 's/at="[^"]*"/at="OLD-TIME"/' "$p/HANDOFF.md" > "$p/HANDOFF.md.tmp" && mv "$p/HANDOFF.md.tmp" "$p/HANDOFF.md"
  assert_file_contains "$p/HANDOFF.md" 'at="OLD-TIME"' "the test must plant OLD-TIME before the second run"
  run_stop "dup-session" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_count "$p/HANDOFF.md" 'session="dup-session"' 1 "still one block"
  assert_file_not_contains "$p/HANDOFF.md" 'at="OLD-TIME"' "timestamp must be refreshed"
}

test_different_session_gets_its_own_block() {
  local p; p="$(project)"
  printf '%s\n' '# H' > "$p/HANDOFF.md"
  run_stop "first-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  run_stop "second-sess" "$(tl_fixture basic.jsonl)" "$p" "billing_error"
  assert_count "$p/HANDOFF.md" 'session="first-sess"' 1
  assert_count "$p/HANDOFF.md" 'session="second-sess"' 1
  assert_file_contains "$p/HANDOFF.md" "(billing/credit limit)"
}

test_missing_handoff_is_created_from_transcript() {
  local p; p="$(project)"
  run_stop "make-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$p/HANDOFF.md"
  assert_file_contains "$p/HANDOFF.md" "Build the login page for the demo app" "goal comes from the first prompt"
  assert_file_contains "$p/HANDOFF.md" "cut off (rate or usage limit reached)"
  assert_file_contains "$p/HANDOFF.md" "verify before trusting"
  assert_file_contains "$p/HANDOFF.md" "- Done: Make login form"
  assert_file_contains "$p/HANDOFF.md" "- Changed file: \`/work/demo/src/login.html\`"
  assert_file_contains "$p/HANDOFF.md" 'session="make-sess"'
  assert_file_contains "$p/HANDOFF.md" "## Paste prompt (for a new chat)"
  assert_file_contains "$p/HANDOFF.md" "Continue my task in"
}

test_created_handoff_next_steps_are_tasks() {
  local p steps; p="$(project)"
  run_stop "steps-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  steps="$(sed -n '/^## Next steps/,/^## /p' "$p/HANDOFF.md")"
  assert_contains "$steps" "1. Add password check" "in-progress task comes first"
  assert_contains "$steps" "2. Write tests" "pending tasks follow"
  assert_not_contains "$steps" "Make login form" "completed tasks are not next steps"
}

test_create_if_missing_zero_still_writes_prompt() {
  local p; p="$(project)"
  export LIMIT_HANDOFF_CREATE_IF_MISSING=0
  run_stop "nocreate" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_missing "$p/HANDOFF.md" "HANDOFF.md must not be created"
  assert_file_exists "$p/PASTE-PROMPT.txt"
  assert_file_exists "$(recovered_for "$p" "nocreate")"
}

test_error_not_in_list_writes_nothing() {
  local p; p="$(project)"
  run_stop "other-err" "$(tl_fixture basic.jsonl)" "$p" "invalid_request"
  assert_exit 0 "$TL_RC"
  assert_file_missing "$p/HANDOFF.md"
  assert_file_missing "$p/PASTE-PROMPT.txt"
  assert_file_missing "$p/.handoff"
}

test_error_list_can_be_changed() {
  local p; p="$(project)"
  export LIMIT_HANDOFF_ERRORS="overloaded"
  run_stop "list-a" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_file_missing "$p/PASTE-PROMPT.txt" "rate_limit is not in the custom list"
  run_stop "list-b" "$(tl_fixture basic.jsonl)" "$p" "overloaded"
  assert_file_exists "$p/PASTE-PROMPT.txt" "overloaded is in the custom list"
  assert_file_contains "$p/HANDOFF.md" "API overloaded"
}

test_clipboard_shim_receives_the_prompt() {
  local p; p="$(project)"
  tl_use_clipboard
  run_stop "clip-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$TEST_OUT/clipboard.txt" "clipboard shim was not called"
  assert_file_contains "$TEST_OUT/clipboard.txt" "Continue my task in"
  assert_file_contains "$TEST_OUT/clipboard.txt" "Add password check"
}

test_notifier_shim_is_called() {
  local p; p="$(project)"
  tl_use_notify
  export LIMIT_HANDOFF_CLIPBOARD=off
  run_stop "notify-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$TEST_OUT/notify.txt" "notifier shim was not called"
  assert_file_contains "$TEST_OUT/notify.txt" "Claude Code stopped: rate or usage limit reached"
  assert_file_contains "$TEST_OUT/notify.txt" "saved to project/PASTE-PROMPT.txt" "the body names the project folder and the file (batch F #9/#18)"
}

test_clipboard_off_still_saves_prompt_file() {
  local p; p="$(project)"
  tl_use_clipboard
  export LIMIT_HANDOFF_CLIPBOARD=off
  run_stop "noclip" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_file_missing "$TEST_OUT/clipboard.txt" "clipboard must not be used when off"
  assert_file_exists "$p/PASTE-PROMPT.txt"
}

test_paste_prompt_has_path_next_step_and_recovered_file() {
  local p rec; p="$(project)"
  printf '%s\n' '# H' '## Next steps' '1. Finish the password check' > "$p/HANDOFF.md"
  run_stop "paste-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  rec="$(recovered_for "$p" "paste-se")"
  assert_file_exists "$rec"
  assert_file_contains "$p/PASTE-PROMPT.txt" "Continue my task in $p." "project path"
  assert_file_contains "$p/PASTE-PROMPT.txt" "First read $p/HANDOFF.md fully" "absolute handoff path"
  assert_file_contains "$p/PASTE-PROMPT.txt" "Then read $rec" "absolute recovered path"
  assert_file_contains "$p/PASTE-PROMPT.txt" "start with: Finish the password check" "next step"
  assert_file_contains "$p/PASTE-PROMPT.txt" "My last chat stopped (rate or usage limit reached)."
  assert_file_not_contains "$p/PASTE-PROMPT.txt" "{{" "no placeholders left"
}

test_paths_with_spaces_work() {
  local p; tl_make_project; p="$TL_PROJ"
  run_stop "space-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$p/HANDOFF.md"
  assert_file_exists "$p/PASTE-PROMPT.txt"
  assert_file_contains "$p/PASTE-PROMPT.txt" "$p"
}

test_no_transcript_path_still_works() {
  local p rec; p="$(project)"
  local payload
  payload="$(jq -n --arg c "$p" '{session_id: "nt-sess", cwd: $c, hook_event_name: "StopFailure", error: "rate_limit"}')"
  tl_run "$TL_HOOK_STOP" "$payload"
  assert_exit 0 "$TL_RC"
  rec="$(recovered_for "$p" "nt-sess")"
  assert_file_contains "$rec" "could not be read"
  assert_file_contains "$p/HANDOFF.md" "The first request was not found"
  assert_file_exists "$p/PASTE-PROMPT.txt"
}

test_unreadable_transcript_still_works() {
  local p; p="$(project)"
  run_stop "missing-tr" "$TL_TMP/does-not-exist.jsonl" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$p/PASTE-PROMPT.txt"
  assert_file_exists "$p/HANDOFF.md"
}

test_malformed_transcript_lines_are_skipped() {
  local p; p="$(project)"
  run_stop "broken-sess" "$(tl_fixture noise.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "Real prompt written as a text block" "good lines still used"
  assert_file_not_contains "$p/HANDOFF.md" "META text that must be skipped"
}

test_jq_missing_still_marks_the_cutoff() {
  local p rec; p="$(project)"
  tl_use_clipboard
  local payload
  payload="$(tl_payload_stop "nojq-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  tl_use_nojq
  command -v jq >/dev/null 2>&1 && fail "test setup: jq should not be on this PATH"
  tl_run "$TL_HOOK_STOP" "$payload"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$p/HANDOFF.md"
  assert_file_contains "$p/HANDOFF.md" 'session="nojq-sess"'
  assert_file_exists "$p/PASTE-PROMPT.txt"
  rec="$(recovered_for "$p" "nojq-se")"
  assert_file_contains "$rec" "jq is not installed"
  assert_file_contains "$TEST_OUT/clipboard.txt" "Continue my task in" "clipboard still works without jq"
}

test_jq_missing_updates_existing_handoff_too() {
  local p; p="$(project)"
  printf '%s\n' '# Mine' '## Next steps' '1. Manual step' > "$p/HANDOFF.md"
  local payload
  payload="$(tl_payload_stop "nojq-2" "" "$p" "rate_limit")"
  tl_use_nojq
  tl_run "$TL_HOOK_STOP" "$payload"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" 'session="nojq-2"'
  assert_file_contains "$p/PASTE-PROMPT.txt" "start with: Manual step"
}

test_read_only_project_still_exits_zero() {
  local p; p="$(project)"
  chmod 555 "$p"
  run_stop "ro-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  local rc=$TL_RC
  chmod 755 "$p"
  assert_exit 0 "$rc"
  assert_file_missing "$p/HANDOFF.md"
  grep -q "could not" "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" || fail "failed writes should be logged"
}

test_error_text_is_optional_and_treated_as_unknown() {
  local p; p="$(project)"
  run_stop "noerr-sess" "$(tl_fixture basic.jsonl)" "$p" ""
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" 'error="unknown"'
  assert_file_contains "$p/HANDOFF.md" "unknown API error"
}

test_garbage_stdin_still_exits_zero() {
  tl_run "$TL_HOOK_STOP" "this is not json"
  assert_exit 0 "$TL_RC"
  tl_run "$TL_HOOK_STOP" ""
  assert_exit 0 "$TL_RC"
}

test_security_transcript_text_is_never_executed_or_expanded() {
  local p; p="$(project)"
  run_stop "evil-sess" "$(tl_fixture security.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_missing "$p/pwned-by-transcript" "command substitution in a prompt must not run"
  assert_file_missing "$p/pwned-by-backtick"
  assert_file_missing "$p/pwned-by-reply"
  assert_file_missing "$p/pwned-by-command"
  assert_file_missing "$p/pwned-by-tick"
  assert_file_missing "$p/pwned-by-todo"
  assert_file_contains "$p/HANDOFF.md" '$(touch pwned-by-todo)' "text stays literal"
  assert_file_contains "$p/HANDOFF.md" '{{PROJECT_DIR}}' "placeholder text stays literal"
  local rec; rec="$(recovered_for "$p" "evil-ses")"
  assert_file_contains "$rec" '100%s done and %d and %n' "printf-style text stays literal"
  assert_file_contains "$rec" 'evil $(rm -rf /) description'
  assert_file_contains "$p/PASTE-PROMPT.txt" 'Step with $(touch pwned-by-todo) and {{PROJECT_DIR}}' "next step is copied as text"
}

test_handoff_name_outside_project_is_rejected() {
  local p; p="$(project)"
  printf '%s\n' 'OUTSIDE ORIGINAL' > "$TL_TMP/outside.md"
  export LIMIT_HANDOFF_FILE="../outside.md"
  run_stop "trav-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$TL_TMP/outside.md" "OUTSIDE ORIGINAL" "file outside the project must not change"
  assert_file_not_contains "$TL_TMP/outside.md" "limit-handoff:cutoff"
  assert_file_exists "$p/HANDOFF.md" "default name is used instead"
}

test_handoff_name_in_sub_folder_is_created() {
  local p; p="$(project)"
  export LIMIT_HANDOFF_FILE="docs/STATUS.md"
  run_stop "sub-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_file_exists "$p/docs/STATUS.md"
  assert_file_contains "$p/docs/STATUS.md" 'session="sub-sess"'
}

test_recover_dir_config_is_used() {
  local p; p="$(project)"
  export LIMIT_HANDOFF_RECOVER_DIR="notes/recovered-here"
  run_stop "rdir-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_file_exists "$p/notes/recovered-here/LATEST.md"
  assert_file_contains "$p/HANDOFF.md" "Recovered context: \`notes/recovered-here/recovered-"
}

test_latest_copy_matches_new_recovered_file() {
  local p rec; p="$(project)"
  run_stop "latest-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  rec="$(recovered_for "$p" "latest-s")"
  assert_same_file "$rec" "$p/.handoff/LATEST.md"
}

test_billing_error_wording_in_status_and_block() {
  local p; p="$(project)"
  run_stop "bill-sess" "$(tl_fixture basic.jsonl)" "$p" "billing_error"
  assert_file_contains "$p/HANDOFF.md" "cut off (billing/credit limit)"
  assert_file_contains "$p/HANDOFF.md" 'error="billing_error"'
}

test_hook_writes_log_lines() {
  local p; p="$(project)"
  run_stop "log-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_file_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "StopFailure error=rate_limit"
  assert_file_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "paste prompt written"
}

test_large_transcript_finishes_fast() {
  local p big start end elapsed
  p="$(project)"
  big="$TL_TMP/big.jsonl"
  awk 'BEGIN {
    pad = ""; for (i = 0; i < 900; i++) pad = pad "x";
    for (i = 1; i <= 30000; i++) {
      if (i % 3 == 0) printf "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Prompt number %d\"}}\n", i;
      else printf "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"%s\"}]}}\n", pad;
    }
  }' > "$big"
  [ -s "$big" ] || fail "test transcript was not written"
  start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  run_stop "big-sess" "$big" "$p" "rate_limit"
  end="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  elapsed="$(perl -e "printf '%.3f', $end - $start")"
  assert_exit 0 "$TL_RC"
  echo "    (large transcript run took ${elapsed}s)"
  perl -e "exit(($elapsed < $(tl_time_limit 2.0)) ? 0 : 1)" || fail "hook took ${elapsed}s on a large transcript; limit is $(tl_time_limit 2.0)s"
  assert_file_contains "$p/HANDOFF.md" "Prompt number"
}

run_tests
