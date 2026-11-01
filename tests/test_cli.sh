#!/bin/bash
# Tests for bin/limit-handoff (install, uninstall, status, prompt, recover, resolve, simulate, doctor).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

settings_file() { printf '%s\n' "$TL_TMP/home/.claude/settings.json"; }

# hooks_of file jq_path: prints a jq value from a settings file.
hooks_of() { jq -r "$2" "$1"; }

test_help_version_and_usage_codes() {
  tl_kit --help
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "limit-handoff install"
  assert_contains "$TL_OUT" "Exit codes: 0 ok, 1 operational failure, 2 usage error."
  tl_kit --version
  assert_exit 0 "$TL_RC"
  assert_eq "limit-handoff $(tl_hk_version)" "$TL_OUT" "--version prints HK_VERSION"
  tl_kit
  assert_exit 2 "$TL_RC" "no arguments is a usage error"
}

test_unknown_command_is_usage_error() {
  tl_kit bogus-command
  assert_exit 2 "$TL_RC"
  assert_contains "$TL_ERR" "unknown command: bogus-command"
}

test_install_requires_settings_flag() {
  tl_kit install
  assert_exit 2 "$TL_RC"
  assert_contains "$TL_ERR" "--settings is required"
}

test_install_creates_new_settings_file() {
  local s; s="$(settings_file)"
  tl_kit install --settings "$s"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$s" "settings file should be created"
  assert_eq "PreCompact,SessionStart,StopFailure,UserPromptSubmit" "$(jq -r '.hooks | keys | sort | join(",")' "$s")" "all four events present"
  assert_eq "rate_limit|billing_error|unknown" "$(jq -r '.hooks.StopFailure[0].matcher' "$s")"
  assert_eq "30" "$(jq -r '.hooks.StopFailure[0].hooks[0].timeout' "$s")"
  assert_eq "5" "$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].timeout' "$s")"
  assert_eq "20" "$(jq -r '.hooks.SessionStart[0].hooks[0].timeout' "$s")"
  assert_eq "30" "$(jq -r '.hooks.PreCompact[0].hooks[0].timeout' "$s")"
  assert_eq "command" "$(jq -r '.hooks.PreCompact[0].hooks[0].type' "$s")"
  assert_contains "$(jq -r '.hooks.PreCompact[0].hooks[0].command' "$s")" "/hooks/pre-compact.sh' # limit-handoff"
}

test_install_keeps_other_hooks_and_keys() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  cat > "$s" <<'JSON'
{
  "model": "opus",
  "env": {"KEEP": "1"},
  "hooks": {
    "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "/usr/local/bin/fmt.sh"}]}],
    "StopFailure": [{"matcher": "overloaded", "hooks": [{"type": "command", "command": "/opt/mine/hooks/stop-failure.sh"}]}]
  }
}
JSON
  local before_rest before_post
  before_rest="$(jq -S 'del(.hooks)' "$s")"
  before_post="$(jq -S '.hooks.PostToolUse' "$s")"
  tl_kit install --settings "$s"
  assert_exit 0 "$TL_RC"
  assert_eq "$before_rest" "$(jq -S 'del(.hooks)' "$s")" "non-hook keys must be unchanged"
  assert_eq "$before_post" "$(jq -S '.hooks.PostToolUse' "$s")" "other events must be unchanged"
  assert_eq "2" "$(jq -r '.hooks.StopFailure | length' "$s")" "the user's own StopFailure hook stays and the kit's is added"
  assert_contains "$(jq -r '.hooks.StopFailure[0].hooks[0].command' "$s")" "/opt/mine/hooks/stop-failure.sh"
}

test_install_is_idempotent() {
  local s; s="$(settings_file)"
  tl_kit install --settings "$s"
  cp "$s" "$TL_TMP/first.json"
  tl_kit install --settings "$s"
  assert_exit 0 "$TL_RC"
  assert_same_file "$TL_TMP/first.json" "$s" "second install must not change the file"
  assert_contains "$TL_OUT" "Already installed"
  assert_count "$s" "# limit-handoff" 4 "exactly four kit hooks"
}

test_install_backup_for_existing_file() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  printf '{"model":"x"}\n' > "$s"
  tl_kit install --settings "$s"
  assert_exit 0 "$TL_RC"
  local bak; bak="$(ls "$s".bak-* 2>/dev/null | head -n 1)"
  assert_file_exists "$bak" "backup file missing"
  assert_eq '{"model":"x"}' "$(jq -c . "$bak")" "backup holds the old content"
  assert_contains "$TL_OUT" "Backup saved:"
}

test_install_dry_run_writes_nothing() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  printf '{"model":"x"}\n' > "$s"
  cp "$s" "$TL_TMP/before.json"
  tl_kit install --settings "$s" --dry-run
  assert_exit 0 "$TL_RC"
  assert_same_file "$TL_TMP/before.json" "$s" "dry run must not change the file"
  assert_eq "" "$(ls "$s".bak-* 2>/dev/null)" "dry run must not make a backup"
  assert_contains "$TL_OUT" "Dry run"
  assert_contains "$TL_OUT" "+"
  assert_contains "$TL_OUT" "StopFailure"
}

test_install_invalid_json_changes_nothing() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  printf '{ this is not json\n' > "$s"
  cp "$s" "$TL_TMP/before.txt"
  tl_kit install --settings "$s"
  assert_exit 2 "$TL_RC"
  assert_same_file "$TL_TMP/before.txt" "$s"
  assert_contains "$TL_ERR" "Nothing was changed"
  assert_eq "" "$(ls "$s".bak-* 2>/dev/null)" "no backup when nothing is changed"
}

test_install_array_json_is_refused() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  printf '[1,2,3]\n' > "$s"
  tl_kit install --settings "$s"
  assert_exit 2 "$TL_RC"
  assert_eq "[1,2,3]" "$(jq -c . "$s")"
}

test_install_events_subset_only_adds_selected() {
  local s; s="$(settings_file)"
  tl_kit install --settings "$s" --events stop-failure
  assert_exit 0 "$TL_RC"
  assert_eq "StopFailure" "$(jq -r '.hooks | keys | join(",")' "$s")"
}

test_install_custom_errors_matcher() {
  local s; s="$(settings_file)"
  tl_kit install --settings "$s" --errors "overloaded|server_error"
  assert_exit 0 "$TL_RC"
  assert_eq "overloaded|server_error" "$(jq -r '.hooks.StopFailure[0].matcher' "$s")"
}

test_install_rejects_bad_options() {
  local s; s="$(settings_file)"
  tl_kit install --settings "$s" --errors "not_a_real_error"
  assert_exit 2 "$TL_RC"
  tl_kit install --settings "$s" --events "nope"
  assert_exit 2 "$TL_RC"
  tl_kit install --settings "$s" --bogus-flag
  assert_exit 2 "$TL_RC"
  assert_file_missing "$s" "bad options must not create the file"
}

test_install_expands_tilde_in_settings_path() {
  tl_kit install --settings "~/.claude/tilde-settings.json"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$TL_TMP/home/.claude/tilde-settings.json"
}

test_installed_command_runs_from_a_folder_with_spaces() {
  local copy="$TL_TMP/kit copy" s payload cmd
  mkdir -p "$copy"
  cp -R "$TL_ROOT/bin" "$TL_ROOT/lib" "$TL_ROOT/hooks" "$TL_ROOT/templates" "$copy/"
  s="$(settings_file)"
  /bin/bash "$copy/bin/limit-handoff" install --settings "$s" >/dev/null || fail "install from copied kit failed"
  cmd="$(jq -r '.hooks.StopFailure[0].hooks[0].command' "$s")"
  payload="$(tl_payload_stop "spaced-sess" "$(tl_fixture basic.jsonl)" "$CLAUDE_PROJECT_DIR" "rate_limit")"
  printf '%s' "$payload" | sh -c "$cmd" >/dev/null 2>&1
  assert_exit 0 "$?" "the installed command must run through a shell"
  assert_file_exists "$CLAUDE_PROJECT_DIR/HANDOFF.md" "hook from the installed command should have written HANDOFF.md"
  assert_file_contains "$CLAUDE_PROJECT_DIR/HANDOFF.md" 'session="spaced-sess"'
}

test_uninstall_removes_only_kit_entries() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  cat > "$s" <<'JSON'
{"hooks": {"StopFailure": [{"matcher": "overloaded", "hooks": [{"type": "command", "command": "/opt/mine/hooks/stop-failure.sh"}]}],
           "PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "/usr/local/bin/fmt.sh"}]}]}}
JSON
  tl_kit install --settings "$s"
  tl_kit uninstall --settings "$s"
  assert_exit 0 "$TL_RC"
  assert_eq "PostToolUse,StopFailure" "$(jq -r '.hooks | keys | join(",")' "$s")" "kit events removed, user events kept"
  assert_eq "1" "$(jq -r '.hooks.StopFailure | length' "$s")" "only the user's StopFailure group is left"
  assert_eq "/opt/mine/hooks/stop-failure.sh" "$(jq -r '.hooks.StopFailure[0].hooks[0].command' "$s")"
  assert_count "$s" "# limit-handoff" 0 "no kit entries left"
}

test_uninstall_round_trip_gives_original_file() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  printf '{}\n' > "$s"
  tl_kit install --settings "$s"
  tl_kit uninstall --settings "$s"
  assert_exit 0 "$TL_RC"
  assert_eq "{}" "$(jq -c . "$s")" "install then uninstall leaves an empty object"
}

test_uninstall_without_file_writes_nothing() {
  local s; s="$(settings_file)"
  tl_kit uninstall --settings "$s"
  assert_exit 0 "$TL_RC"
  assert_file_missing "$s"
  assert_contains "$TL_OUT" "No settings file"
}

test_uninstall_dry_run_keeps_hooks() {
  local s; s="$(settings_file)"
  tl_kit install --settings "$s"
  cp "$s" "$TL_TMP/installed.json"
  tl_kit uninstall --settings "$s" --dry-run
  assert_exit 0 "$TL_RC"
  assert_same_file "$TL_TMP/installed.json" "$s"
  assert_contains "$TL_OUT" "-"
}

test_status_reports_handoff_and_hooks() {
  local s p; s="$(settings_file)"; p="$CLAUDE_PROJECT_DIR"
  tl_kit install --settings "$s"
  printf '%s\n' '# H' '<!-- limit-handoff:cutoff session="q" at="x" error="rate_limit" status="unresolved" -->' '<!-- /limit-handoff:cutoff -->' > "$p/HANDOFF.md"
  tl_kit status --settings "$s" --dir "$p"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "Unresolved cut-offs: 1"
  assert_contains "$TL_OUT" "StopFailure"
  assert_contains "$TL_OUT" "PreCompact"
}

test_status_without_handoff_and_bad_settings() {
  local s="$TL_TMP/bad.json"
  printf 'nope\n' > "$s"
  tl_kit status --settings "$s" --dir "$CLAUDE_PROJECT_DIR"
  # Changed by the review fixes (F3): a settings file that is not valid JSON exits 2.
  assert_exit 2 "$TL_RC"
  assert_contains "$TL_OUT" "not found"
  assert_contains "$TL_OUT" "is not valid JSON"
}

test_prompt_copies_and_prints() {
  tl_use_clipboard
  tl_kit prompt --dir "$CLAUDE_PROJECT_DIR"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$TEST_OUT/clipboard.txt" "clipboard should get the prompt"
  assert_file_contains "$TEST_OUT/clipboard.txt" "Continue my task in"
  assert_contains "$TL_OUT" "Paste prompt:"
  assert_contains "$TL_OUT" "Copied to the clipboard."
  assert_file_exists "$CLAUDE_PROJECT_DIR/PASTE-PROMPT.txt"
}

test_prompt_no_copy_and_uses_next_step() {
  printf '%s\n' '# H' '## Next steps' '1. Ship the fix' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  tl_use_clipboard
  tl_kit prompt --dir "$CLAUDE_PROJECT_DIR" --no-copy
  assert_exit 0 "$TL_RC"
  assert_file_missing "$TEST_OUT/clipboard.txt" "--no-copy must not use the clipboard"
  assert_file_contains "$CLAUDE_PROJECT_DIR/PASTE-PROMPT.txt" "start with: Ship the fix"
  assert_contains "$TL_OUT" "I am moving this work to a new chat on purpose." "a manual handoff says the move was on purpose (batch F #8)"
}

test_recover_stdout_prints_without_writing() {
  tl_kit recover --transcript "$(tl_fixture basic.jsonl)" --dir "$CLAUDE_PROJECT_DIR" --stdout
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "# Recovered context"
  assert_contains "$TL_OUT" "Build the login page for the demo app"
  assert_file_missing "$CLAUDE_PROJECT_DIR/.handoff" "--stdout must not write files"
}

test_recover_writes_file_and_latest() {
  tl_kit recover --transcript "$(tl_fixture basic.jsonl)" --dir "$CLAUDE_PROJECT_DIR"
  assert_exit 0 "$TL_RC"
  local rec; rec="$(ls "$CLAUDE_PROJECT_DIR/.handoff"/recovered-*.md | head -n 1)"
  assert_file_exists "$rec"
  assert_same_file "$rec" "$CLAUDE_PROJECT_DIR/.handoff/LATEST.md"
}

test_recover_argument_errors() {
  tl_kit recover --dir "$CLAUDE_PROJECT_DIR"
  assert_exit 2 "$TL_RC"
  tl_kit recover --transcript "$TL_TMP/nope.jsonl" --dir "$CLAUDE_PROJECT_DIR"
  assert_exit 1 "$TL_RC"
  assert_contains "$TL_ERR" "could not be read"
}

test_resolve_marks_one_session_then_all() {
  local p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# H' \
    '<!-- limit-handoff:cutoff session="A" at="1" error="rate_limit" status="unresolved" -->' 'a text' '<!-- /limit-handoff:cutoff -->' \
    '<!-- limit-handoff:cutoff session="B" at="2" error="rate_limit" status="unresolved" -->' 'b text' '<!-- /limit-handoff:cutoff -->' > "$p/HANDOFF.md"
  tl_kit resolve --dir "$p" --session A
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" 'session="A" at="1" error="rate_limit" status="resolved"'
  assert_file_contains "$p/HANDOFF.md" 'session="B" at="2" error="rate_limit" status="unresolved"'
  assert_file_contains "$p/HANDOFF.md" "a text" "history is kept"
  tl_kit resolve --dir "$p"
  assert_contains "$TL_OUT" "Marked 1 cut-off block(s)"
  assert_file_not_contains "$p/HANDOFF.md" 'status="unresolved"'
  tl_kit resolve --dir "$p"
  assert_contains "$TL_OUT" "No unresolved cut-off blocks"
}

test_resolve_session_text_is_sanitized() {
  local p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '<!-- limit-handoff:cutoff session="A" at="1" error="rate_limit" status="unresolved" -->' '<!-- /limit-handoff:cutoff -->' > "$p/HANDOFF.md"
  cp "$p/HANDOFF.md" "$TL_TMP/before.md"
  tl_kit resolve --dir "$p" --session 'A$(touch pwned-by-resolve)'
  # No block matches the cleaned id, so the command says so and exits 1 (batch F #21).
  assert_exit 1 "$TL_RC" "a session with no match is an error (batch F #21)"
  assert_contains "$TL_ERR" "no unresolved cut-off for session Atouchpwned-by-resolve" "the message names the cleaned id (batch F #21)"
  assert_file_missing "$p/pwned-by-resolve" "session text must never run"
  assert_same_file "$TL_TMP/before.md" "$p/HANDOFF.md" "sanitized id 'Atouchpwnedbyresolve' matches nothing"
}

test_resolve_without_handoff_is_error() {
  tl_kit resolve --dir "$CLAUDE_PROJECT_DIR"
  assert_exit 1 "$TL_RC"
  assert_contains "$TL_ERR" "no HANDOFF.md"
}

test_simulate_end_to_end() {
  local p="$CLAUDE_PROJECT_DIR"
  tl_kit simulate --dir "$p"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$p/HANDOFF.md"
  assert_count "$p/HANDOFF.md" 'limit-handoff:cutoff session="simulated-' 1
  assert_file_exists "$p/PASTE-PROMPT.txt"
  assert_file_contains "$p/PASTE-PROMPT.txt" "Continue my task in $p."
  local rec; rec="$(ls "$p/.handoff"/recovered-*simulate*.md 2>/dev/null | head -n 1)"
  assert_file_exists "$rec" "recovered file missing"
  assert_contains "$TL_OUT" "Simulated a StopFailure (rate_limit)"
  assert_file_missing "$TEST_OUT/clipboard.txt" "simulate leaves the clipboard alone by default"
}

test_simulate_error_and_transcript_options() {
  local p="$CLAUDE_PROJECT_DIR"
  tl_kit simulate --dir "$p" --error billing_error --transcript "$(tl_fixture basic.jsonl)"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "cut off (billing/credit limit)"
  assert_file_contains "$p/.handoff/LATEST.md" "Build the login page for the demo app" "LATEST has the transcript text"
}

test_simulate_copy_flag_uses_clipboard() {
  unset LIMIT_HANDOFF_CLIPBOARD
  tl_use_clipboard
  tl_kit simulate --dir "$CLAUDE_PROJECT_DIR" --copy
  assert_exit 0 "$TL_RC"
  assert_file_exists "$TEST_OUT/clipboard.txt" "--copy should reach the clipboard shim"
}

test_doctor_passes_on_a_normal_setup() {
  tl_kit doctor
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "All required checks passed."
  assert_contains "$TL_OUT" "[ok]   jq"
}

test_doctor_without_jq_warns_and_exits_zero() {
  tl_use_nojq
  tl_kit doctor
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "[warn] jq not found"
  assert_contains "$TL_OUT" "clipboard tool:"
}

test_doctor_reports_unwritable_state_folder() {
  local st="$TL_TMP/locked-state"
  mkdir -p "$st"
  chmod 555 "$st"
  export LIMIT_HANDOFF_STATE_DIR="$st"
  tl_kit doctor
  local rc=$TL_RC
  chmod 755 "$st"
  assert_exit 1 "$rc"
  assert_contains "$TL_OUT" "[FAIL] state folder is not writable"
}

test_doctor_flags_missing_executable_hook() {
  local copy="$TL_TMP/kit-copy"
  mkdir -p "$copy"
  cp -R "$TL_ROOT/bin" "$TL_ROOT/lib" "$TL_ROOT/hooks" "$TL_ROOT/templates" "$copy/"
  chmod -x "$copy/hooks/pre-compact.sh"
  tl_kit_path="$copy/bin/limit-handoff"
  /bin/bash "$tl_kit_path" doctor > "$TL_TMP/doc.out" 2>&1
  local rc=$?
  assert_exit 1 "$rc"
  assert_file_contains "$TL_TMP/doc.out" "not executable: hooks/pre-compact.sh"
}

run_tests
