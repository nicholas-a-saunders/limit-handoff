#!/bin/bash
# Tests for lib/transcript.jq (through hk_recover_json). Uses synthetic fixtures only.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

recover() {
  # recover file [nprompts]: prints the recovered JSON, fails the test on error.
  . "$TL_ROOT/lib/common.sh"
  local out
  out="$(hk_recover_json "$1" "${2:-5}")" || fail "hk_recover_json failed for $1"
  printf '%s\n' "$out"
}

test_basic_fields() {
  local j
  j="$(recover "$(tl_fixture basic.jsonl)")"
  assert_eq "Build the login page for the demo app" "$(printf '%s' "$j" | jq -r '.first_prompt')"
  assert_eq "2" "$(printf '%s' "$j" | jq -r '.last_prompts | length')"
  assert_eq "Also add a remember-me box" "$(printf '%s' "$j" | jq -r '.last_prompts[1]')"
  assert_eq "Form is done. Next I will add the password check." "$(printf '%s' "$j" | jq -r '.last_assistant_text')"
  assert_eq "9" "$(printf '%s' "$j" | jq -r '.line_count')"
  assert_eq "/work/demo/src/login.html" "$(printf '%s' "$j" | jq -r '.files_touched[0]')"
  assert_eq "npm test" "$(printf '%s' "$j" | jq -r '.last_commands[0].command')"
  assert_eq "Run the tests" "$(printf '%s' "$j" | jq -r '.last_commands[0].description')"
}

test_task_list_statuses_from_todowrite() {
  local j
  j="$(recover "$(tl_fixture basic.jsonl)")"
  assert_eq "3" "$(printf '%s' "$j" | jq -r '.tasks | length')"
  assert_eq "completed" "$(printf '%s' "$j" | jq -r '.tasks[0].status')"
  assert_eq "in_progress" "$(printf '%s' "$j" | jq -r '.tasks[1].status')"
  assert_eq "pending" "$(printf '%s' "$j" | jq -r '.tasks[2].status')"
  assert_eq "Add password check" "$(printf '%s' "$j" | jq -r '.tasks[1].content')"
}

test_noise_is_excluded() {
  local j
  j="$(recover "$(tl_fixture noise.jsonl)")"
  # Only the text-block prompt is real. META, system-reminder, task-notification,
  # Caveat, command-name and tool_result lines are not prompts.
  assert_eq "Real prompt written as a text block" "$(printf '%s' "$j" | jq -r '.first_prompt')"
  assert_eq "1" "$(printf '%s' "$j" | jq -r '.last_prompts | length')"
  assert_eq "Visible final answer" "$(printf '%s' "$j" | jq -r '.last_assistant_text')"
  assert_not_contains "$(printf '%s' "$j")" "private reasoning" "thinking blocks must not be used"
  assert_eq "14" "$(printf '%s' "$j" | jq -r '.line_count')" "every raw line should be counted"
}

test_broken_lines_are_skipped_without_failing() {
  local j rc
  j="$(recover "$(tl_fixture noise.jsonl)")" || fail "broken lines made recovery fail"
  rc=$?
  assert_eq "0" "$rc"
  assert_contains "$j" "first_prompt"
}

test_meta_only_last_prompt_fallback() {
  local f="$TL_TMP/meta.jsonl" j
  printf '%s\n' '{"type":"last-prompt","lastPrompt":"Only the metadata prompt"}' > "$f"
  j="$(recover "$f")"
  assert_eq "Only the metadata prompt" "$(printf '%s' "$j" | jq -r '.first_prompt')"
}

test_consecutive_prompts_are_deduplicated() {
  local f="$TL_TMP/dup.jsonl" j
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"Same ask"}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"Same ask"}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"Different ask"}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"Same ask"}}'
  } > "$f"
  j="$(recover "$f")"
  assert_eq "3" "$(printf '%s' "$j" | jq -r '.last_prompts | length')" "only consecutive repeats are merged"
}

test_last_full_todo_list_wins() {
  local f="$TL_TMP/todo2.jsonl" j
  {
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"a","name":"TodoWrite","input":{"todos":[{"content":"Old one","status":"pending"}]}}]}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"b","name":"TodoWrite","input":{"todos":[{"content":"New one","status":"in_progress"},{"content":"New two","status":"pending"}]}}]}}'
  } > "$f"
  j="$(recover "$f")"
  assert_eq "2" "$(printf '%s' "$j" | jq -r '.tasks | length')"
  assert_eq "New one" "$(printf '%s' "$j" | jq -r '.tasks[0].content')"
}

test_update_plan_full_list_then_advance() {
  local j
  j="$(recover "$(tl_fixture plan.jsonl)")"
  assert_eq "completed" "$(printf '%s' "$j" | jq -r '.tasks[0].status')"
  assert_eq "in_progress" "$(printf '%s' "$j" | jq -r '.tasks[1].status')"
  assert_eq "pending" "$(printf '%s' "$j" | jq -r '.tasks[2].status')"
  assert_eq "Step two" "$(printf '%s' "$j" | jq -r '.tasks[1].content')"
}

test_update_plan_done_and_start_form() {
  local f="$TL_TMP/donestart.jsonl" j
  {
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"p","name":"update_plan","input":{"items":[{"content":"A","status":"pending"},{"content":"B","status":"pending"},{"content":"C","status":"pending"}]}}]}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"q","name":"mcp__t__update_plan","input":{"done":[2],"start":3}}]}}'
  } > "$f"
  j="$(recover "$f")"
  assert_eq "pending" "$(printf '%s' "$j" | jq -r '.tasks[0].status')"
  assert_eq "completed" "$(printf '%s' "$j" | jq -r '.tasks[1].status')"
  assert_eq "in_progress" "$(printf '%s' "$j" | jq -r '.tasks[2].status')"
}

test_task_create_and_update_by_id() {
  local j
  j="$(recover "$(tl_fixture tasks.jsonl)")"
  assert_eq "2" "$(printf '%s' "$j" | jq -r '.tasks | length')"
  assert_eq "Write changelog" "$(printf '%s' "$j" | jq -r '.tasks[0].content')"
  assert_eq "completed" "$(printf '%s' "$j" | jq -r '.tasks[0].status')"
  assert_eq "in_progress" "$(printf '%s' "$j" | jq -r '.tasks[1].status')"
}

test_file_tools_and_order() {
  local j
  j="$(recover "$(tl_fixture files.jsonl)")"
  # Write f01, MultiEdit f02, NotebookEdit nb, Read is not an edit, then Edit f01 again.
  # Most recent first: f01 moves to the front, nb next, f02 last.
  assert_eq "/w/f01.txt" "$(printf '%s' "$j" | jq -r '.files_touched[0]')"
  assert_eq "/w/nb.ipynb" "$(printf '%s' "$j" | jq -r '.files_touched[1]')"
  assert_eq "/w/f02.txt" "$(printf '%s' "$j" | jq -r '.files_touched[2]')"
  assert_eq "3" "$(printf '%s' "$j" | jq -r '.files_touched | length')"
  assert_not_contains "$(printf '%s' "$j")" "not-an-edit" "Read must not count as an edit"
}

test_files_capped_at_twenty_most_recent() {
  local j
  j="$(recover "$(tl_fixture many_files.jsonl)")"
  assert_eq "20" "$(printf '%s' "$j" | jq -r '.files_touched | length')"
  assert_eq "/many/file05.py" "$(printf '%s' "$j" | jq -r '.files_touched[0]')" "re-edited file moves to the front"
  assert_eq "/many/file07.py" "$(printf '%s' "$j" | jq -r '.files_touched[19]')"
}

test_last_five_commands_in_order() {
  local f="$TL_TMP/cmds.jsonl" j i
  {
    for i in 1 2 3 4 5 6 7; do
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"c%s","name":"Bash","input":{"command":"echo %s"}}]}}\n' "$i" "$i"
    done
  } > "$f"
  j="$(recover "$f")"
  assert_eq "5" "$(printf '%s' "$j" | jq -r '.last_commands | length')"
  assert_eq "echo 3" "$(printf '%s' "$j" | jq -r '.last_commands[0].command')"
  assert_eq "echo 7" "$(printf '%s' "$j" | jq -r '.last_commands[4].command')"
}

test_truncation_lengths() {
  local j
  j="$(recover "$(tl_fixture long.jsonl)")"
  # Prompts are cut at 600 characters plus the "…" mark.
  assert_eq "601" "$(printf '%s' "$j" | jq -r '.first_prompt | length')"
  assert_eq "…" "$(printf '%s' "$j" | jq -r '.first_prompt[600:]')"
  # Assistant text is cut at 800.
  assert_eq "801" "$(printf '%s' "$j" | jq -r '.last_assistant_text | length')"
  # Command and description are cut at 200.
  assert_eq "201" "$(printf '%s' "$j" | jq -r '.last_commands[0].command | length')"
  assert_eq "201" "$(printf '%s' "$j" | jq -r '.last_commands[0].description | length')"
}

test_prompt_count_is_respected() {
  local j
  j="$(recover "$(tl_fixture basic.jsonl)" 1)"
  assert_eq "1" "$(printf '%s' "$j" | jq -r '.last_prompts | length')"
  assert_eq "Also add a remember-me box" "$(printf '%s' "$j" | jq -r '.last_prompts[0]')"
  j="$(recover "$(tl_fixture basic.jsonl)" 0)"
  assert_eq "0" "$(printf '%s' "$j" | jq -r '.last_prompts | length')"
}

test_empty_transcript_gives_empty_result() {
  local f="$TL_TMP/empty.jsonl" j
  : > "$f"
  j="$(recover "$f")"
  assert_eq "null" "$(printf '%s' "$j" | jq -r '.first_prompt')"
  assert_eq "0" "$(printf '%s' "$j" | jq -r '.line_count')"
  assert_eq "0" "$(printf '%s' "$j" | jq -r '.tasks | length')"
}

test_tail_window_drops_old_first_prompt() {
  # With only 3 lines read, the first prompt has scrolled out of the window.
  . "$TL_ROOT/lib/common.sh"
  LIMIT_HANDOFF_TAIL_LINES=3 hk_recover_json "$(tl_fixture basic.jsonl)" 5 > "$TL_TMP/tail.json" || fail "recovery failed"
  assert_not_contains "$(cat "$TL_TMP/tail.json")" "Build the login page" "old prompt should be outside the tail window"
  assert_eq "3" "$(jq -r '.line_count' "$TL_TMP/tail.json")"
}

test_odd_shapes_never_break_the_parser() {
  local f="$TL_TMP/odd.jsonl" j rc
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":42}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":"plain string content"}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"x","name":"Bash","input":"not an object"}]}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"y","name":"TodoWrite","input":{"todos":"nope"}}]}}'
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"z","name":"update_plan","input":{"items":7}}]}}'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":{"a":1},"content":null}]}}'
    printf '%s\n' '[1,2,3]'
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"Survivor prompt"}}'
  } > "$f"
  j="$(recover "$f")"; rc=$?
  assert_eq "0" "$rc"
  assert_eq "Survivor prompt" "$(printf '%s' "$j" | jq -r '.first_prompt')"
}

test_only_system_text_gives_no_prompt() {
  local f="$TL_TMP/sys.jsonl" j
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"   <system-reminder>only this</system-reminder>"}}' > "$f"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"   "}}' >> "$f"
  j="$(recover "$f")"
  assert_eq "null" "$(printf '%s' "$j" | jq -r '.first_prompt')"
}

# Found on a real Claude Code desktop transcript: the typed prompt and a system reminder
# arrive in one message (two text blocks, or one string). The typed part must survive.
test_reminder_next_to_typed_prompt_keeps_the_prompt() {
  local j
  j="$(recover "$(tl_fixture mixed_reminder.jsonl)")"
  assert_eq "Is there a tool that turns videos into notes?" "$(printf '%s' "$j" | jq -r '.first_prompt')"
  assert_eq "2" "$(printf '%s' "$j" | jq -r '.last_prompts | length')"
  assert_eq "Now build the prototype please" "$(printf '%s' "$j" | jq -r '.last_prompts[1]')"
  assert_not_contains "$j" "system-reminder"
  assert_not_contains "$j" "task-notification"
}

run_tests
