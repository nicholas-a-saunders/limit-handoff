#!/bin/bash
# Adversarial tests: inputs chosen to break the kit.
# Area: transcript parsing and the recovered-context file.
# Rules come from docs/SPEC.md.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ADV_JQ="$TL_ROOT/lib/transcript.jq"

# adv_parse file [np]: runs the recovered-context program on a whole transcript file.
# Sets ADV_JSON and ADV_RC.
adv_parse() {
  ADV_JSON="$(jq -n -R -c --argjson np "${2:-5}" -f "$ADV_JQ" < "$1" 2>"$TL_TMP/parse.err")"
  ADV_RC=$?
}

# adv_newest_recovered project: the newest recovered-*.md file in the project.
adv_newest_recovered() {
  ls -t "$1/.handoff"/recovered-*.md 2>/dev/null | head -n 1
}

# adv_stop project transcript session error: runs the StopFailure hook.
adv_stop() {
  local payload
  payload="$(tl_payload_stop "$3" "$2" "$1" "$4")"
  tl_run "$TL_HOOK_STOP" "$payload"
}

# ---------------------------------------------------------------------------
# Odd message shapes. SPEC "Recovered context": broken or odd lines are skipped
# (jq -R 'fromjson?'); SPEC "Transcript JSONL": parse defensively, never fail on unknown lines.
# ---------------------------------------------------------------------------

test_one_odd_line_does_not_stop_the_whole_parse() {
  local f="$TL_TMP/odd-string-message.jsonl"
  cat > "$f" <<'EOF'
{"type":"user","message":{"role":"user","content":"Real first prompt"}}
{"type":"user","message":"a plain string where the message object should be"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"An answer"}]}}
{"type":"user","message":{"role":"user","content":"Second real prompt"}}
EOF
  adv_parse "$f"
  assert_eq "0" "$ADV_RC" "jq must not fail because one line has a string message (SPEC: never fail on unknown lines)"
  assert_eq "Real first prompt" "$(printf '%s' "$ADV_JSON" | jq -r '.first_prompt')" "first prompt must still be found"
  assert_eq "Second real prompt" "$(printf '%s' "$ADV_JSON" | jq -r '.last_prompts[-1]')" "later prompts must still be found"
}

test_string_message_on_an_assistant_line_is_skipped() {
  local f="$TL_TMP/odd-assistant.jsonl"
  cat > "$f" <<'EOF'
{"type":"user","message":{"role":"user","content":"Do the thing"}}
{"type":"assistant","message":"just text, no content list"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Last answer"}]}}
EOF
  adv_parse "$f"
  assert_eq "0" "$ADV_RC" "an assistant line with a string message must be skipped, not fatal"
  assert_eq "Last answer" "$(printf '%s' "$ADV_JSON" | jq -r '.last_assistant_text')" "the last real assistant text must be kept"
}

test_number_array_and_bool_message_shapes_are_skipped() {
  local f="$TL_TMP/odd-shapes.jsonl"
  cat > "$f" <<'EOF'
{"type":"user","message":{"role":"user","content":"Before the odd shapes"}}
{"type":"user","message":42}
{"type":"assistant","message":[1,2,3]}
{"type":"user","message":true}
{"type":"user","message":null}
{"type":"assistant","message":{"role":"assistant","content":{"not":"a list"}}}
{"type":"user","message":{"role":"user","content":"After the odd shapes"}}
EOF
  adv_parse "$f"
  assert_eq "0" "$ADV_RC" "numbers, arrays and booleans in message must not break the parser"
  assert_eq "After the odd shapes" "$(printf '%s' "$ADV_JSON" | jq -r '.last_prompts[-1]')" "prompts after the odd lines must be kept"
}

test_hook_recovers_prompts_when_one_transcript_line_is_odd() {
  local p; p="$CLAUDE_PROJECT_DIR"
  local f="$TL_TMP/odd-hook.jsonl" rec
  cat > "$f" <<'EOF'
{"type":"user","message":{"role":"user","content":"Real first prompt"}}
{"type":"user","message":"string message shape"}
{"type":"user","message":{"role":"user","content":"Second real prompt"}}
EOF
  adv_stop "$p" "$f" "odd-hook-sess" "rate_limit"
  assert_exit 0 "$TL_RC"
  rec="$(adv_newest_recovered "$p")"
  assert_file_exists "$rec" "a recovered file must be written"
  assert_file_contains "$rec" "Second real prompt" "the recovered file must list the real prompts"
  assert_file_not_contains "$rec" "could not be parsed" "one odd line must not make the whole recovery fail"
}

# ---------------------------------------------------------------------------
# Size and unicode limits. SPEC "Recovered context": prompts truncated to 600, assistant text to 800.
# ---------------------------------------------------------------------------

test_emoji_prompt_is_cut_to_600_characters_with_ellipsis() {
  local f="$TL_TMP/emoji.jsonl" len last
  perl -CO -e 'print qq({"type":"user","message":{"role":"user","content":"), ("\x{1F600}" x 700), qq("}}\n);' > "$f"
  adv_parse "$f"
  assert_eq "0" "$ADV_RC" "unicode prompt must parse"
  len="$(printf '%s' "$ADV_JSON" | jq -r '.first_prompt | length')"
  last="$(printf '%s' "$ADV_JSON" | jq -r '.first_prompt | .[-1:]')"
  assert_eq "601" "$len" "600 characters plus one ellipsis character"
  assert_eq "…" "$last" "the cut must end with an ellipsis"
}

test_two_megabyte_assistant_text_is_cut_to_800_characters() {
  local f="$TL_TMP/huge-assistant.jsonl" len
  perl -e 'print qq({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"), ("aaaaaaaaaa " x 190000), qq("}]}}\n);' > "$f"
  adv_parse "$f"
  assert_eq "0" "$ADV_RC" "a 2 MB assistant line must parse"
  len="$(printf '%s' "$ADV_JSON" | jq -r '.last_assistant_text | length')"
  assert_eq "801" "$len" "assistant text must be cut to 800 characters plus an ellipsis"
}

# ---------------------------------------------------------------------------
# Hostile text. SPEC "Security": transcript text is never executed or expanded.
# ---------------------------------------------------------------------------

# adv_hostile_transcript file: prompts that try to run commands, fill templates and format strings.
adv_hostile_transcript() {
  cat > "$1" <<'EOF'
{"type":"user","message":{"role":"user","content":"Run $(touch CANARY_X) and `touch CANARY_Y` then stop"}}
{"type":"user","message":{"role":"user","content":"Literal {{PROJECT_DIR}} {{HANDOFF_FILE}} {{NEXT_STEP}} and 100%s %d %n %%"}}
{"type":"user","message":{"role":"user","content":"Quotes \"double\" and 'single' and back\\slash"}}
{"type":"user","message":{"role":"user","content":"line one\nline two with ${HOME} and $HOME"}}
{"type":"user","message":{"role":"user","content":"unicode café 日本語 and emoji 😀"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Reply $(touch CANARY_R) {{RECOVERED_FILE}} %s"},{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"echo $(touch CANARY_C) `touch CANARY_T`","description":"evil $(rm -rf /) text"}}]}}
EOF
}

test_hostile_text_is_written_literally_in_the_recovered_file() {
  local p; p="$CLAUDE_PROJECT_DIR"
  local f="$TL_TMP/hostile.jsonl" rec
  adv_hostile_transcript "$f"
  adv_stop "$p" "$f" "hostile-rec" "rate_limit"
  assert_exit 0 "$TL_RC"
  rec="$(adv_newest_recovered "$p")"
  assert_file_exists "$rec"
  assert_file_contains "$rec" 'Run $(touch CANARY_X) and `touch CANARY_Y` then stop' "command text must be copied as text"
  assert_file_contains "$rec" '{{PROJECT_DIR}} {{HANDOFF_FILE}} {{NEXT_STEP}} and 100%s %d %n %%' "template and format tokens must stay literal"
  assert_file_contains "$rec" 'back\slash' "backslashes must survive"
  assert_file_contains "$rec" 'unicode café 日本語' "unicode must survive"
  assert_file_contains "$rec" '$HOME' "shell variables must not be expanded"
  assert_file_contains "$rec" 'echo $(touch CANARY_C)' "the last command must be copied as text"
  assert_file_contains "$rec" 'Reply $(touch CANARY_R) {{RECOVERED_FILE}} %s' "assistant text must stay literal"
  if [ -n "$(find "$TL_TMP" -name 'CANARY_*' 2>/dev/null)" ]; then
    fail "a canary file was created: hostile transcript text was executed"
  fi
}

test_hostile_text_is_literal_in_a_created_handoff() {
  local p; p="$CLAUDE_PROJECT_DIR"
  local f="$TL_TMP/hostile-create.jsonl"
  adv_hostile_transcript "$f"
  assert_file_missing "$p/HANDOFF.md"
  adv_stop "$p" "$f" "hostile-create" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$p/HANDOFF.md" "a missing HANDOFF.md must be created"
  assert_file_contains "$p/HANDOFF.md" 'Run $(touch CANARY_X) and `touch CANARY_Y` then stop' "the goal must be the literal first prompt"
  # The recent messages live in the recovered file now (batch C #31), so the check reads that file.
  local rec; rec="$(ls "$p"/.handoff/recovered-*.md 2>/dev/null | head -n 1)"
  assert_file_exists "$rec" "the recovered file with the recent messages must exist"
  assert_file_contains "$rec" '{{PROJECT_DIR}} {{HANDOFF_FILE}}' "template tokens in prompts must not be filled in"
  if [ -n "$(find "$TL_TMP" -name 'CANARY_*' 2>/dev/null)" ]; then
    fail "a canary file was created while creating HANDOFF.md"
  fi
}

# ---------------------------------------------------------------------------
# Markdown safety (minor). SPEC "Recovered context" lists the commands in the recovered file.
# A command that contains a fence line must not close the code block early.
# ---------------------------------------------------------------------------

test_command_with_a_fence_line_cannot_break_out_of_its_code_block() {
  local p; p="$CLAUDE_PROJECT_DIR"
  local f="$TL_TMP/fence.jsonl" rec fences
  cat > "$f" <<'EOF'
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"echo start\n````\n## Injected heading\n- evil item","description":"d"}}]}}
EOF
  adv_stop "$p" "$f" "fence-sess" "rate_limit"
  rec="$(adv_newest_recovered "$p")"
  assert_file_exists "$rec"
  fences="$(grep -c '^````$' "$rec")"
  assert_eq "1" "$fences" "only the closing fence may be a bare four-backtick line (minor: a command can close its own block early)"
}

run_tests
