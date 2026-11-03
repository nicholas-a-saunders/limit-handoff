#!/bin/bash
# Tests for the fixes from the first-time-user test (2026-11-03): the rate-limit wording, the
# visible "(resolved)" mark, CLAUDE_CONFIG_DIR, other open cut-offs in the paste prompt, and the
# log line for user-only keys in a project file. See docs/DECISIONS.md 184-188.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_common() {
  . "$TL_ROOT/lib/common.sh"
  HK_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
}

run_stop() {
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "$1" "$2" "$3" "$4")"
}

# --- U1: rate-limit wording -------------------------------------------------

test_u1_base_reason_needs_details_to_say_usage_limit() {
  load_common
  assert_eq "rate or usage limit reached" "$(hk_base_reason rate_limit "")" "no details: both are named"
  assert_eq "usage limit reached" "$(hk_base_reason rate_limit "5-hour limit")" "details: an account usage limit"
  assert_eq "billing/credit limit" "$(hk_base_reason billing_error "5-hour limit")" "other codes keep their text"
}

test_u1_stop_with_limit_line_says_usage_limit_everywhere() {
  local p="$CLAUDE_PROJECT_DIR"
  export TZ=UTC
  tl_use_notify
  run_stop "u1-five" "$(tl_fixture limit_five_hour.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "(usage limit reached — 5-hour limit" "the block names the usage limit"
  assert_file_not_contains "$p/HANDOFF.md" "rate or usage" "no vague wording when the limit is known"
  assert_eq "Claude Code stopped: usage limit reached" "$(sed -n 1p "$TEST_OUT/notify.txt")" "the title too"
}

test_u1_stop_without_details_does_not_claim_a_usage_limit() {
  local p="$CLAUDE_PROJECT_DIR"
  run_stop "u1-plain" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/PASTE-PROMPT.txt" "My last chat stopped (rate or usage limit reached)." "the prompt names both"
  tl_run "$TL_HOOK_SESSION" "$(tl_payload_plain SessionStart "u1-next" "$p" "startup")"
  assert_contains "$TL_OUT" ", rate or usage limit reached)" "the new chat gets the same wording"
}

# --- U2: visible "(resolved)" mark --------------------------------------------

test_u2_resolve_marks_only_the_chosen_block_visibly() {
  local p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# H' '> ⚠️ **Session cut off** (a line the user wrote) stays as it is.' > "$p/HANDOFF.md"
  run_stop "u2-one" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  run_stop "u2-two" "$(tl_fixture basic.jsonl)" "$p" "billing_error"
  tl_kit resolve --dir "$p" --session u2-one
  assert_exit 0 "$TL_RC"
  assert_count "$p/HANDOFF.md" '✅ **Session cut off (resolved)**' 1 "one visible mark"
  assert_eq "> ✅ **Session cut off (resolved)** (rate or usage limit reached)" \
    "$(grep -A1 'session="u2-one"' "$p/HANDOFF.md" | sed -n 2p | sed 's/ at .*//')" "the mark is on the chosen block"
  assert_file_contains "$p/HANDOFF.md" "> ⚠️ **Session cut off** (billing/credit limit)" "the other block keeps its warning"
  assert_file_contains "$p/HANDOFF.md" "> ⚠️ **Session cut off** (a line the user wrote) stays as it is." "text outside blocks is not changed"
  tl_kit resolve --dir "$p"
  tl_kit resolve --dir "$p"
  assert_count "$p/HANDOFF.md" '(resolved)** (resolved)' 0 "a second resolve does not add a second mark"
  assert_count "$p/HANDOFF.md" '✅ **Session cut off (resolved)**' 2 "both blocks are marked once"
  assert_file_not_contains "$p/HANDOFF.md" 'status="unresolved"'
}

test_u2_resolved_mark_stops_the_reminder() {
  local p="$CLAUDE_PROJECT_DIR"
  run_stop "u2-rem" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  tl_kit resolve --dir "$p"
  tl_run "$TL_HOOK_PROMPT" "$(tl_payload_plain UserPromptSubmit "u2-new" "$p" "")"
  assert_not_contains "$TL_OUT" "unresolved cut-off" "no cut-off reminder after resolve"
}

# --- U3: CLAUDE_CONFIG_DIR ----------------------------------------------------

test_u3_user_settings_file_follows_claude_config_dir() {
  load_common
  assert_eq "$HOME/.claude/settings.json" "$(hk_user_settings_file)" "default"
  assert_eq "/x/acct-b/settings.json" "$(CLAUDE_CONFIG_DIR=/x/acct-b/ hk_user_settings_file)" "absolute folder, trailing slash"
  assert_eq "$HOME/.claude/settings.json" "$(CLAUDE_CONFIG_DIR=rel/dir hk_user_settings_file)" "a relative folder is not used"
}

test_u3_doctor_checks_the_config_dir_settings_by_default() {
  local d="$TL_TMP/acct-b" f
  f="$d/settings.json"
  mkdir -p "$d"
  tl_kit install --settings "$f"
  jq '.enabledPlugins = {"limit-handoff@acme": true}' "$f" > "$TL_TMP/s.json" && mv "$TL_TMP/s.json" "$f"
  CLAUDE_CONFIG_DIR="$d" tl_kit doctor
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "[warn] limit-handoff hooks are registered twice" "the account's settings file is checked"
  assert_contains "$TL_OUT" "$f" "and named"
}

# --- U4: other open cut-offs in the paste prompt --------------------------------

test_u4_stop_prompt_names_other_open_cutoffs() {
  local p="$CLAUDE_PROJECT_DIR"
  run_stop "u4-one" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_file_not_contains "$p/PASTE-PROMPT.txt" "unresolved cut-off" "one cut-off: no extra sentence"
  run_stop "u4-two" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_file_contains "$p/PASTE-PROMPT.txt" "It also has unresolved cut-offs from earlier chats (1): read the recovered file each one names." \
    "two cut-offs: the earlier one is pointed to"
  # A later stop of the same chat (after the repeat window) must not count its own old block.
  export LIMIT_HANDOFF_DEBOUNCE_SEC=0
  run_stop "u4-two" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_count "$TL_TMP/state/limit-handoff.log" "cut-off block written" 2 "the repeat stop was handled, not skipped"
  assert_count "$p/PASTE-PROMPT.txt" "earlier chats (1)" 1 "the chat does not count its own block"
}

test_u4_manual_prompt_names_an_open_cutoff() {
  local p="$CLAUDE_PROJECT_DIR"
  run_stop "u4-man" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  tl_kit prompt --dir "$p" --no-copy
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "It also has unresolved cut-offs from earlier chats (1): read the recovered file each one names." \
    "the manual prompt points to the open cut-off"
  tl_kit resolve --dir "$p"
  tl_kit prompt --dir "$p" --no-copy
  assert_not_contains "$TL_OUT" "unresolved cut-offs" "nothing to point to after resolve"
}

# --- U5: log line for user-only keys in the project file ------------------------

test_u5_project_file_user_only_keys_are_logged_by_name() {
  local p="$CLAUDE_PROJECT_DIR"
  mkdir -p "$p/.claude"
  printf '%s\n' 'LIMIT_HANDOFF_FILE=../escape.md' 'LIMIT_HANDOFF_CLIPBOARD=evilcmd' 'LIMIT_HANDOFF_PROMPTS=2' > "$p/.claude/limit-handoff.conf"
  run_stop "u5-keys" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" \
    "the project file .claude/limit-handoff.conf sets LIMIT_HANDOFF_FILE LIMIT_HANDOFF_CLIPBOARD." "both keys are named"
  assert_file_not_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "evilcmd" "values are never logged"
  assert_file_not_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "sets LIMIT_HANDOFF_PROMPTS" "allowed keys are not named"
  assert_file_missing "$TL_TMP/escape.md"
}

test_u5_no_log_line_without_user_only_keys() {
  local p="$CLAUDE_PROJECT_DIR"
  mkdir -p "$p/.claude"
  printf '%s\n' 'LIMIT_HANDOFF_PROMPTS=2' > "$p/.claude/limit-handoff.conf"
  run_stop "u5-none" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_file_not_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "the project file .claude/limit-handoff.conf sets"
}

run_tests
