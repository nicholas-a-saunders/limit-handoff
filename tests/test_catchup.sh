#!/bin/bash
# Tests for the catch-up at session start (hk_catchup in lib/common.sh, run by hooks/session-start.sh),
# the "prompt_too_long" code, and the de-duplication of StopFailure (hk_claim_stop).
# All transcripts are made up here, in the test's own temp folder.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# cu_dir: the transcript folder of this test. Claude Code keeps one such folder per project.
cu_dir() { printf '%s\n' "$TL_TMP/claude-projects/proj"; }

# cu_add file line: appends one transcript line (creates the folder when needed).
cu_add() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >> "$1"
}

# cu_user text: a real user prompt line.
cu_user() {
  jq -n -c --arg t "$1" '{type: "user", message: {role: "user", content: $t}, sessionId: "cu"}'
}

# cu_reply text: a normal assistant reply line.
cu_reply() {
  jq -n -c --arg t "$1" '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $t}]}}'
}

# cu_limit error text cwd sidechain: a synthetic limit line, the way Claude Code writes it.
cu_limit() {
  jq -n -c --arg e "$1" --arg t "$2" --arg c "$3" --argjson s "$4" '{
    type: "assistant", isApiErrorMessage: true, error: $e, apiErrorStatus: 429, isSidechain: $s,
    cwd: $c, sessionId: "cu", timestamp: "2026-10-30T16:01:02.000Z",
    quotaLimits: {status: "rejected", resetsAt: 1791823800, rateLimitType: "five_hour",
                  overageStatus: "rejected", isUsingOverage: false},
    message: {model: "<synthetic>", role: "assistant", content: [{type: "text", text: $t}]}}'
}

# cu_toolong cwd: a "Prompt is too long" line (no quota fields).
cu_toolong() {
  jq -n -c --arg c "$1" '{type: "assistant", isApiErrorMessage: true, error: "invalid_request",
    apiErrorStatus: 400, isSidechain: false, cwd: $c, sessionId: "cu",
    message: {model: "<synthetic>", role: "assistant", content: [{type: "text", text: "Prompt is too long"}]}}'
}

# cu_payload source transcript: the SessionStart payload for this project.
cu_payload() {
  jq -n --arg c "$CLAUDE_PROJECT_DIR" --arg t "$2" --arg s "$1" \
    '{session_id: "cur-sess", cwd: $c, hook_event_name: "SessionStart", source: $s, transcript_path: $t}'
}

# cu_start source transcript: runs the SessionStart hook. Sets TL_RC, TL_OUT and TL_ERR.
cu_start() {
  tl_run "$TL_HOOK_SESSION" "$(cu_payload "$1" "$2")"
}

# run_stop sid transcript cwd error: sends a StopFailure payload to the hook.
run_stop() {
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "$1" "$2" "$3" "$4")"
}

# recovered_for session8: the newest recovered file of this project for that session.
recovered_for() {
  ls -t "$CLAUDE_PROJECT_DIR/.handoff"/recovered-*"$1"*.md 2>/dev/null | head -n 1
}

# shim_calls name: how many times a test shim was called (0 when it was never called).
shim_calls() {
  if [ -f "$TEST_OUT/$1" ]; then
    wc -l < "$TEST_OUT/$1" | tr -d ' '
  else
    echo 0
  fi
}

# ---------------------------------------------------------------------------
# Catch-up: what is found and written at session start
# ---------------------------------------------------------------------------

test_limit_at_end_of_chat_gets_a_handoff_on_next_start() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/catch-01.jsonl"
  cu_add "$f" "$(cu_user "Build the invoice page")"
  cu_add "$f" "$(cu_reply "Starting on it.")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit · resets 5:40pm (Europe/London)" "$p" false)"
  tl_use_clipboard
  tl_use_notify
  cu_start startup "$(cu_dir)/curnt-01.jsonl"
  assert_exit 0 "$TL_RC"
  assert_contains "$(printf '%s\n' "$TL_OUT" | head -n 1)" \
    "limit-handoff wrote a handoff for the previous chat (catch-01). It hit a rate or usage limit and had no handoff." \
    "the extra line must come first"
  assert_contains "$TL_OUT" "unresolved cut-off from a previous session" "the normal text follows"
  assert_file_exists "$p/HANDOFF.md"
  assert_count "$p/HANDOFF.md" 'session="catch-01"' 1 "one block for the chat"
  assert_file_contains "$p/HANDOFF.md" 'status="unresolved"'
  assert_file_contains "$p/HANDOFF.md" "usage limit reached — 5-hour limit"
  assert_file_exists "$(recovered_for catch-01)" "recovered file written"
  assert_file_exists "$p/PASTE-PROMPT.txt" "paste prompt file written"
  assert_eq 0 "$(shim_calls clipboard.calls)" "the catch-up must not copy to the clipboard"
  assert_file_missing "$TEST_OUT/notify.txt" "the catch-up must not notify"
  assert_file_exists "$LIMIT_HANDOFF_STATE_DIR/handled/catch-01" "the chat is marked as handled"
}

test_catchup_writes_one_block_when_session_starts_twice() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/twice-01.jsonl"
  cu_add "$f" "$(cu_user "Fix the footer")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  cu_start startup "$(cu_dir)/curnt-02.jsonl"
  assert_contains "$TL_OUT" "wrote a handoff for the previous chat (twice-01)" "first start writes it"
  cu_start startup "$(cu_dir)/curnt-02.jsonl"
  assert_exit 0 "$TL_RC"
  assert_not_contains "$TL_OUT" "limit-handoff found" "second start writes nothing new"
  assert_count "$p/HANDOFF.md" 'session="twice-01"' 1 "still one block"
}

test_sidechain_only_limit_is_ignored() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/side-001.jsonl"
  cu_add "$f" "$(cu_user "Run the checks")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" true)"
  cu_start startup "$(cu_dir)/curnt-03.jsonl"
  assert_exit 0 "$TL_RC"
  assert_eq "" "$TL_OUT" "a subagent copy must not start a handoff"
  assert_file_missing "$p/HANDOFF.md"
  assert_file_missing "$LIMIT_HANDOFF_STATE_DIR/handled/side-001"
}

test_other_error_on_main_chain_is_ignored() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/inval-01.jsonl"
  cu_add "$f" "$(cu_user "Check the schema")"
  cu_add "$f" "$(cu_limit invalid_request "Some other API problem" "$p" false)"
  cu_start startup "$(cu_dir)/curnt-03.jsonl"
  assert_eq "" "$TL_OUT" "invalid_request is not in the default error list"
  assert_file_missing "$p/HANDOFF.md"
}

test_real_reply_after_limit_means_nothing() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/reply-01.jsonl"
  cu_add "$f" "$(cu_user "Write the tests")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  cu_add "$f" "$(cu_reply "Tests are written and passing.")"
  cu_start startup "$(cu_dir)/curnt-04.jsonl"
  assert_eq "" "$TL_OUT" "the chat moved on after the limit"
  assert_file_missing "$p/HANDOFF.md"
}

test_user_prompt_after_limit_means_nothing() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/reply-02.jsonl"
  cu_add "$f" "$(cu_user "Write the tests")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  cu_add "$f" "$(cu_user "Try again please")"
  cu_start startup "$(cu_dir)/curnt-04.jsonl"
  assert_eq "" "$TL_OUT" "the user wrote again, so the chat moved on"
  assert_file_missing "$p/HANDOFF.md"
}

test_prompt_too_long_gets_its_own_code_and_reason() {
  local p f rec; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/toolong1.jsonl"
  cu_add "$f" "$(cu_user "Summarise the whole repository")"
  cu_add "$f" "$(cu_toolong "$p")"
  cu_start startup "$(cu_dir)/curnt-05.jsonl"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "context limit (prompt too long)" "the reason text"
  assert_file_contains "$p/HANDOFF.md" 'error="prompt_too_long"' "the block keeps the code"
  assert_file_contains "$p/HANDOFF.md" "(context limit (prompt too long))" "the cut-off line shows the reason"
  rec="$(recovered_for toolong1)"
  assert_file_exists "$rec"
  assert_file_contains "$rec" "- Why this was made: context limit (prompt too long) (code \`prompt_too_long\`)"
}

test_handled_marker_stops_catchup() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/marked01.jsonl"
  mkdir -p "$LIMIT_HANDOFF_STATE_DIR/handled"
  printf '%s\n' 1000 > "$LIMIT_HANDOFF_STATE_DIR/handled/marked01"
  cu_add "$f" "$(cu_user "Add the theme switch")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  cu_start startup "$(cu_dir)/curnt-06.jsonl"
  assert_eq "" "$TL_OUT" "a handled chat is skipped, even when the marker is old"
  assert_file_missing "$p/HANDOFF.md"
}

test_stop_failure_marks_chat_so_catchup_skips_it() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/stopfst1.jsonl"
  run_stop "stopfst1" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$LIMIT_HANDOFF_STATE_DIR/handled/stopfst1" "the StopFailure run writes the marker"
  cu_add "$f" "$(cu_user "Build the login page")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  cu_start startup "$(cu_dir)/curnt-07.jsonl"
  assert_not_contains "$TL_OUT" "limit-handoff found" "no second handoff"
  assert_count "$p/HANDOFF.md" 'session="stopfst1"' 1 "still one block"
}

test_chat_older_than_the_window_is_ignored() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/oldfile1.jsonl"
  cu_add "$f" "$(cu_user "Old work")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  touch -t 202001010000 "$f"
  cu_start startup "$(cu_dir)/curnt-08.jsonl"
  assert_eq "" "$TL_OUT" "a chat from 2020 is outside 48 hours"
  assert_file_missing "$p/HANDOFF.md"
}

test_catchup_window_can_be_changed() {
  local p f old; p="$CLAUDE_PROJECT_DIR"
  # BSD date (macOS) takes -v; GNU date (Ubuntu) takes -d. Both must give a time three hours back.
  old="$(date -v-3H '+%Y%m%d%H%M' 2>/dev/null || date -d '-3 hours' '+%Y%m%d%H%M')"
  [ -n "$old" ] || fail "could not work out a time three hours ago on this system"
  f="$(cu_dir)/win-old1.jsonl"
  cu_add "$f" "$(cu_user "Three hours ago")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  touch -t "$old" "$f"
  export LIMIT_HANDOFF_CATCHUP_HOURS=1
  cu_start startup "$(cu_dir)/curnt-09.jsonl"
  assert_eq "" "$TL_OUT" "outside a 1 hour window"
  assert_file_missing "$p/HANDOFF.md"
  unset LIMIT_HANDOFF_CATCHUP_HOURS
  f="$(cu_dir)/win-old2.jsonl"
  cu_add "$f" "$(cu_user "Three hours ago too")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  touch -t "$old" "$f"
  cu_start startup "$(cu_dir)/curnt-09.jsonl"
  assert_contains "$TL_OUT" "wrote a handoff for the previous chat (win-old2)" "inside the default 48 hour window"
}

test_chat_of_another_project_is_ignored() {
  local f; f="$(cu_dir)/otherpr1.jsonl"
  cu_add "$f" "$(cu_user "Work on the other project")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$TL_TMP/other-project" false)"
  cu_start startup "$(cu_dir)/curnt-10.jsonl"
  assert_eq "" "$TL_OUT" "the chat was made in another folder"
  assert_file_missing "$CLAUDE_PROJECT_DIR/HANDOFF.md"
}

test_chat_from_a_sub_folder_of_the_project_counts() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/subdir01.jsonl"
  cu_add "$f" "$(cu_user "Work in the src folder")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p/src" false)"
  cu_start startup "$(cu_dir)/curnt-11.jsonl"
  assert_contains "$TL_OUT" "wrote a handoff for the previous chat (subdir01)" "a folder inside the project counts"
}

test_current_chat_is_skipped_on_startup_and_included_on_resume() {
  local p cur; p="$CLAUDE_PROJECT_DIR"; cur="$(cu_dir)/curnt-02b.jsonl"
  cu_add "$cur" "$(cu_user "Keep going")"
  cu_add "$cur" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  cu_start startup "$cur"
  assert_eq "" "$TL_OUT" "a new chat is not the chat that stopped"
  assert_file_missing "$p/HANDOFF.md"
  cu_start resume "$cur"
  assert_contains "$TL_OUT" "wrote a handoff for the previous chat (curnt-02)" "a resumed chat is the one that stopped"
  assert_count "$p/HANDOFF.md" 'session="curnt-02b"' 1
}

test_compact_does_not_catch_up() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/compact1.jsonl"
  cu_add "$f" "$(cu_user "Compact me")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  cu_start compact "$(cu_dir)/curnt-12.jsonl"
  assert_exit 0 "$TL_RC"
  assert_file_missing "$p/HANDOFF.md" "compact is not a new chat"
}

test_catchup_off_does_nothing() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/off-0001.jsonl"
  cu_add "$f" "$(cu_user "Switch it off")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  export LIMIT_HANDOFF_CATCHUP=0
  cu_start startup "$(cu_dir)/curnt-13.jsonl"
  assert_eq "" "$TL_OUT"
  assert_file_missing "$p/HANDOFF.md"
  assert_file_missing "$LIMIT_HANDOFF_STATE_DIR/handled/off-0001"
}

test_catchup_uses_the_error_list() {
  local p f; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/list-001.jsonl"
  cu_add "$f" "$(cu_user "Only overloaded counts")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  export LIMIT_HANDOFF_ERRORS="overloaded"
  cu_start startup "$(cu_dir)/curnt-14.jsonl"
  assert_eq "" "$TL_OUT" "rate_limit is not in the changed list"
  assert_file_missing "$p/HANDOFF.md"
}

test_catchup_needs_jq_and_stays_silent() {
  local p f payload; p="$CLAUDE_PROJECT_DIR"; f="$(cu_dir)/nojq-001.jsonl"
  cu_add "$f" "$(cu_user "No jq here")"
  cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  payload="$(cu_payload startup "$(cu_dir)/curnt-15.jsonl")"
  tl_use_nojq
  tl_run "$TL_HOOK_SESSION" "$payload"
  assert_exit 0 "$TL_RC"
  assert_eq "" "$TL_OUT" "no jq, so no catch-up"
  assert_file_missing "$p/HANDOFF.md"
}

test_at_most_three_chats_are_handed_off() {
  local p f n; p="$CLAUDE_PROJECT_DIR"
  for n in 1 2 3 4; do
    f="$(cu_dir)/cap-000$n.jsonl"
    cu_add "$f" "$(cu_user "Chat number $n")"
    cu_add "$f" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  done
  cu_start startup "$(cu_dir)/curnt-16.jsonl"
  assert_exit 0 "$TL_RC"
  assert_count "$p/HANDOFF.md" 'limit-handoff:cutoff session="cap-' 3 "three blocks, not four"
  # Each handled chat has a started marker and a done marker (batch D #46/#61), so 3 chats make 6 files.
  assert_eq 3 "$(ls "$LIMIT_HANDOFF_STATE_DIR/handled" | grep -c '\.done$')" "three chats marked done"
}

test_hostile_file_names_are_skipped() {
  local p d hostile; p="$CLAUDE_PROJECT_DIR"; d="$(cu_dir)"
  cu_add "$d/good-001.jsonl" "$(cu_user "A normal chat")"
  cu_add "$d/good-001.jsonl" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  cu_add "$d/my session.jsonl" "$(cu_user "Spaces in the name")"
  cu_add "$d/my session.jsonl" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  cu_add "$d/semi;touch pwned-cu.jsonl" "$(cu_user "Semicolon in the name")"
  cu_add "$d/semi;touch pwned-cu.jsonl" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  hostile="$d/"'$(touch pwned-cu).jsonl'
  cu_add "$hostile" "$(cu_user "Command text in the name")"
  cu_add "$hostile" "$(cu_limit rate_limit "You've hit your session limit" "$p" false)"
  ln -s "$d/good-001.jsonl" "$d/linked-01.jsonl"
  cu_start startup "$(cu_dir)/curnt-17.jsonl"
  assert_exit 0 "$TL_RC"
  assert_file_missing "$TL_TMP/pwned-cu" "a name must never run a command"
  assert_file_missing "$d/pwned-cu" "a name must never run a command"
  assert_file_missing "$p/pwned-cu" "a name must never run a command"
  assert_count "$p/HANDOFF.md" 'limit-handoff:cutoff session="' 1 "only the normal chat gets a block"
  assert_file_contains "$p/HANDOFF.md" 'session="good-001"'
  assert_file_not_contains "$p/HANDOFF.md" "linked-01" "a link is never read"
  assert_file_not_contains "$p/HANDOFF.md" "pwned" "no hostile name in the handoff"
}

# ---------------------------------------------------------------------------
# De-duplication of StopFailure
# ---------------------------------------------------------------------------

test_two_stop_failures_within_the_window_make_one_handoff_and_one_copy() {
  local p; p="$CLAUDE_PROJECT_DIR"
  tl_use_clipboard
  run_stop "dbl-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  run_stop "dbl-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$TEST_OUT/clipboard.calls" "the first run copies"
  assert_eq 1 "$(shim_calls clipboard.calls)" "the repeat must not copy again"
  assert_eq 1 "$(ls "$p/.handoff"/recovered-*.md 2>/dev/null | wc -l | tr -d ' ')" "one recovered file"
  assert_count "$p/HANDOFF.md" 'session="dbl-sess"' 1 "one block"
  assert_file_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "duplicate StopFailure for dbl-sess ignored"
}

test_stop_failures_after_the_window_run_again() {
  local p; p="$CLAUDE_PROJECT_DIR"
  export LIMIT_HANDOFF_DEBOUNCE_SEC=0
  tl_use_clipboard
  run_stop "again-01" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  run_stop "again-01" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_eq 2 "$(shim_calls clipboard.calls)" "with the window at 0 each run is handled"
}

test_prompt_too_long_from_claude_code_is_never_matched() {
  local p; p="$CLAUDE_PROJECT_DIR"
  export LIMIT_HANDOFF_ERRORS="rate_limit prompt_too_long"
  run_stop "ptl-sess" "$(tl_fixture basic.jsonl)" "$p" "prompt_too_long"
  assert_exit 0 "$TL_RC"
  assert_file_missing "$p/PASTE-PROMPT.txt" "even in the list, a StopFailure cannot use this code"
  assert_file_missing "$p/HANDOFF.md"
  assert_file_missing "$p/.handoff"
  assert_file_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "only used by catch-up"
}

test_reason_text_and_known_code_for_prompt_too_long() {
  local out
  out="$( . "$TL_ROOT/lib/common.sh"; printf '%s|%s|%s\n' \
    "$(hk_reason_for prompt_too_long)" "$(hk_known_code prompt_too_long)" "$(hk_known_code prompt_TOO_long)" )"
  assert_eq "context limit (prompt too long)|prompt_too_long|unknown" "$out"
}

run_tests
