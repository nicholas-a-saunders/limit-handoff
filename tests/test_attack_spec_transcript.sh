#!/bin/bash
# test_attack_spec_transcript.sh - adversarial SPEC conformance tests for the transcript parser
# (lib/transcript.jq, run through hk_recover_json).
# Each test names the docs/SPEC.md section it checks.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# recover file [np]: prints the recovered JSON for a transcript file, using the tail rule.
recover() {
  /bin/bash -c '. "$1/lib/common.sh"; HK_PROJECT_DIR="$CLAUDE_PROJECT_DIR"; hk_recover_json "$2" "${3:-5}"' \
    _ "$TL_ROOT" "$1" "${2:-5}"
}

# line_user text: one real user prompt line, as a JSON string (safe quoting through jq).
line_user() { jq -c -n --arg t "$1" '{type:"user", message:{role:"user", content:$t}}'; }
line_asst_text() { jq -c -n --arg t "$1" '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:$t}]}}'; }
line_asst_tool() { # name json-input
  jq -c -n --arg n "$1" --argjson i "$2" \
    '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", id:"x", name:$n, input:$i}]}}'
}

# SPEC (transcript rules): each prompt is cut to 600 characters, then "…" is appended.
# Passing regression guard.
test_attack_spec_prompt_truncation_is_600_chars_plus_ellipsis() {
  local tr="$TL_TMP/t1.jsonl" long
  long="$(printf 'a %.0s' $(seq 1 350))"
  line_user "$long" > "$tr"
  local out
  out="$(recover "$tr")"
  assert_eq "601" "$(printf '%s' "$out" | jq -r '.first_prompt | length')" "600 kept plus one ellipsis character"
  assert_eq "…" "$(printf '%s' "$out" | jq -r '.first_prompt[-1:]')" "the ellipsis must be the last character"
}

# SPEC (transcript rules): last assistant text cut to 800 characters. Passing regression guard.
test_attack_spec_last_assistant_text_is_cut_to_800() {
  local tr="$TL_TMP/t2.jsonl" long
  long="$(printf 'b %.0s' $(seq 1 450))"
  { line_user "Start"; line_asst_text "$long"; } > "$tr"
  local out
  out="$(recover "$tr")"
  assert_eq "801" "$(printf '%s' "$out" | jq -r '.last_assistant_text | length')" "800 kept plus ellipsis"
}

# SPEC (transcript rules): commands and descriptions are cut to 200 characters. Passing guard.
test_attack_spec_command_and_description_are_cut_to_200() {
  local tr="$TL_TMP/t3.jsonl" long
  long="$(printf 'c %.0s' $(seq 1 150))"
  line_asst_tool "Bash" "$(jq -c -n --arg c "echo $long" --arg d "$long" '{command:$c, description:$d}')" > "$tr"
  local out
  out="$(recover "$tr")"
  assert_eq "201" "$(printf '%s' "$out" | jq -r '.last_commands[0].command | length')" "command: 200 plus ellipsis"
  assert_eq "201" "$(printf '%s' "$out" | jq -r '.last_commands[0].description | length')" "description: 200 plus ellipsis"
}

# SPEC (transcript JSON): exactly these top-level keys. Passing regression guard.
test_attack_spec_output_has_exactly_the_specified_keys() {
  local out
  out="$(recover "$(tl_fixture basic.jsonl)")"
  assert_eq "files_touched,first_prompt,last_assistant_text,last_commands,last_prompts,limit,line_count,tasks" \
    "$(printf '%s' "$out" | jq -r 'keys | join(",")')" "key set must match the spec"
}

# SPEC (transcript rules): last_prompts holds the last N real prompts, oldest first.
# Passing regression guard.
test_attack_spec_last_prompts_are_last_n_in_order() {
  local tr="$TL_TMP/t4.jsonl"
  { line_user "one"; line_user "two"; line_user "three"; line_user "four"; } > "$tr"
  local out
  out="$(recover "$tr" 2)"
  assert_eq "three|four" "$(printf '%s' "$out" | jq -r '.last_prompts | join("|")')" "two most recent, oldest first"
  assert_eq "one" "$(printf '%s' "$out" | jq -r '.first_prompt')" "first_prompt is the first real prompt"
}

# SPEC (transcript rules): a user line whose text starts with a Claude Code wrapper is not a prompt,
# but the same tag in the middle of a prompt is kept. Passing regression guard.
test_attack_spec_wrapper_only_at_the_start_marks_noise() {
  local tr="$TL_TMP/t5.jsonl"
  { line_user "<system-reminder>hidden</system-reminder>"; \
    line_user "Please check the <system-reminder> tag handling"; \
    line_user "   <command-name>/clear</command-name>"; \
    line_user "Caveat: the user interrupted"; } > "$tr"
  local out
  out="$(recover "$tr" 5)"
  assert_eq "Please check the <system-reminder> tag handling" "$(printf '%s' "$out" | jq -r '.last_prompts | join("|")')" \
    "only the real prompt is kept"
}

# SPEC (transcript rules): a user line with isMeta true is never a prompt. Passing regression guard.
test_attack_spec_meta_lines_are_not_prompts() {
  local tr="$TL_TMP/t6.jsonl"
  jq -c -n '{type:"user", isMeta:true, message:{role:"user", content:"sneaky meta text"}}' > "$tr"
  line_user "real text" >> "$tr"
  local out
  out="$(recover "$tr")"
  assert_eq "real text" "$(printf '%s' "$out" | jq -r '.last_prompts | join("|")')"
}

# SPEC (transcript rules): content arrays made of tool_result blocks are not prompts, but a content
# array with a text block is. Passing regression guard.
test_attack_spec_text_block_arrays_are_prompts_tool_results_are_not() {
  local tr="$TL_TMP/t7.jsonl"
  jq -c -n '{type:"user", message:{role:"user", content:[{type:"tool_result", tool_use_id:"a", content:"ok"}]}}' > "$tr"
  jq -c -n '{type:"user", message:{role:"user", content:[{type:"text", text:"A block prompt"}]}}' >> "$tr"
  local out
  out="$(recover "$tr")"
  assert_eq "A block prompt" "$(printf '%s' "$out" | jq -r '.last_prompts | join("|")')"
}

# SPEC (transcript rules): "Use the LAST full list seen" for TodoWrite. Also statuses are copied as
# completed, in_progress or pending. Passing regression guard.
test_attack_spec_todowrite_last_list_wins_with_three_statuses() {
  local tr="$TL_TMP/t8.jsonl"
  line_asst_tool "TodoWrite" '{"todos":[{"content":"old","status":"pending","activeForm":"old"}]}' > "$tr"
  line_asst_tool "TodoWrite" '{"todos":[{"content":"Alpha","status":"completed","activeForm":"a"},{"content":"Beta","status":"in_progress","activeForm":"b"},{"content":"Gamma","status":"pending","activeForm":"g"}]}' >> "$tr"
  local out
  out="$(recover "$tr")"
  assert_eq "Alpha:completed|Beta:in_progress|Gamma:pending" \
    "$(printf '%s' "$out" | jq -r '[.tasks[] | "\(.content):\(.status)"] | join("|")')"
}

# SPEC (transcript rules): update_plan with {advance:true} moves the in-progress step to completed and
# starts the next pending one. Passing regression guard.
test_attack_spec_update_plan_advance_moves_to_next_step() {
  local tr="$TL_TMP/t9.jsonl"
  line_asst_tool "mcp__x__update_plan" '{"items":[{"content":"One","status":"in_progress"},{"content":"Two","status":"pending"},{"content":"Three","status":"pending"}]}' > "$tr"
  line_asst_tool "mcp__x__update_plan" '{"items":[{"advance":true}]}' >> "$tr"
  local out
  out="$(recover "$tr")"
  assert_eq "One:completed|Two:in_progress|Three:pending" \
    "$(printf '%s' "$out" | jq -r '[.tasks[] | "\(.content):\(.status)"] | join("|")')"
}

# SPEC (transcript rules): file tools Edit, Write, MultiEdit and NotebookEdit are counted, using
# file_path or notebook_path. Read is not counted. Passing regression guard.
test_attack_spec_file_tools_counted_and_read_ignored() {
  local tr="$TL_TMP/t10.jsonl"
  line_asst_tool "Read" '{"file_path":"/w/read-only.txt"}' > "$tr"
  line_asst_tool "MultiEdit" '{"file_path":"/w/multi.txt","edits":[]}' >> "$tr"
  line_asst_tool "NotebookEdit" '{"notebook_path":"/w/nb.ipynb"}' >> "$tr"
  line_asst_tool "Write" '{"file_path":"/w/new.txt","content":"x"}' >> "$tr"
  local out
  out="$(recover "$tr")"
  assert_eq "/w/new.txt|/w/nb.ipynb|/w/multi.txt" "$(printf '%s' "$out" | jq -r '.files_touched | join("|")')" \
    "most recent first, Read excluded"
}

# SPEC (transcript rules): last 5 Bash commands, oldest first. Passing regression guard.
test_attack_spec_last_five_bash_commands_oldest_first() {
  local tr="$TL_TMP/t11.jsonl" i
  for i in 1 2 3 4 5 6 7; do
    line_asst_tool "Bash" "{\"command\":\"cmd$i\"}" >> "$tr"
  done
  local out
  out="$(recover "$tr")"
  assert_eq "cmd3|cmd4|cmd5|cmd6|cmd7" "$(printf '%s' "$out" | jq -r '[.last_commands[].command] | join("|")')"
}

# SPEC (transcript rules): last_assistant_text is the last TEXT block, thinking blocks never count.
# Passing regression guard.
test_attack_spec_thinking_blocks_never_become_the_assistant_text() {
  local tr="$TL_TMP/t12.jsonl"
  jq -c -n '{type:"assistant", message:{role:"assistant", content:[{type:"text", text:"Visible reply"}, {type:"thinking", thinking:"secret reasoning"}]}}' > "$tr"
  jq -c -n '{type:"assistant", message:{role:"assistant", content:[{type:"thinking", thinking:"more secret"}]}}' >> "$tr"
  local out
  out="$(recover "$tr")"
  assert_eq "Visible reply" "$(printf '%s' "$out" | jq -r '.last_assistant_text')"
}

# SPEC (transcript rules): "Other line types ... ignore" and "malformed lines skipped". A transcript
# with only broken and unknown lines gives empty results and does not fail. Passing regression guard.
test_attack_spec_unknown_and_broken_lines_never_fail_the_parse() {
  local tr="$TL_TMP/t13.jsonl"
  { echo '{"type":"attachment","x":1}'; echo '{"type":"file-history-snapshot"}'; echo '{not json'; echo '["array"]'; echo '42'; } > "$tr"
  local out rc
  out="$(recover "$tr")"; rc=$?
  assert_eq "0" "$rc" "recover must succeed"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.first_prompt')"
  assert_eq "[]" "$(printf '%s' "$out" | jq -c '.tasks')"
}

# SPEC (transcript rules): the tail rule. A session longer than the tail window must still give the
# last prompts. Passing regression guard.
test_attack_spec_tail_window_still_gives_the_latest_prompt() {
  local tr="$TL_TMP/t14.jsonl" i
  line_user "very first prompt" > "$tr"
  for i in $(seq 1 6000); do echo '{"type":"system","n":'"$i"'}' >> "$tr"; done
  line_user "latest prompt" >> "$tr"
  local out
  out="$(CLAUDE_PROJECT_DIR="$TL_TMP/project" LIMIT_HANDOFF_TAIL_LINES=50 /bin/bash -c '. "$1/lib/common.sh"; hk_recover_json "$2" 5' _ "$TL_ROOT" "$tr")"
  assert_eq "latest prompt" "$(printf '%s' "$out" | jq -r '.last_prompts | join("|")')" "latest prompt is always inside the tail"
}

run_tests
