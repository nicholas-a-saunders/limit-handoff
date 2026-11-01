#!/bin/bash
# attack_spec_install.sh - adversarial SPEC conformance tests for bin/limit-handoff install,
# uninstall, status and the exit codes.
# Each test names the SPEC section it checks. Severity is in the comment above each test.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

settings_file() { printf '%s\n' "$TL_TMP/home/.claude/settings.json"; }

# SPEC (bin/limit-handoff, install/uninstall): kit entries are detected by a command containing the
# "limit-handoff" path marker. Other hooks, even ones with the word "handoff" in their path, must stay.
# Severity: major (the uninstall deletes a user's own hook without asking).
test_attack_spec_uninstall_keeps_unrelated_hook_with_handoff_in_path() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  cat > "$s" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/Users/me/work/handoff/hooks/session-start.sh"}]}]}}
JSON
  tl_kit uninstall --settings "$s"
  assert_exit 0 "$TL_RC"
  assert_eq "1" "$(jq '[.. | objects | select(has("command")) | .command] | map(select(. == "/Users/me/work/handoff/hooks/session-start.sh")) | length' "$s")" \
    "a user hook that is not a limit-handoff hook must survive uninstall"
}

# SPEC (bin/limit-handoff, install): same rule for install. The user's hook must survive a re-install.
# Severity: major.
test_attack_spec_install_keeps_unrelated_hook_with_handoff_in_path() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  cat > "$s" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/Users/me/work/handoff/hooks/session-start.sh"}]}]}}
JSON
  tl_kit install --settings "$s" --events session-start
  assert_exit 0 "$TL_RC"
  assert_eq "1" "$(jq '[.. | objects | select(has("command")) | .command] | map(select(. == "/Users/me/work/handoff/hooks/session-start.sh")) | length' "$s")" \
    "a user hook that is not a limit-handoff hook must survive install"
}

# SPEC (bin/limit-handoff, install): "merges hook groups ... without touching other keys/hooks" and
# "Write files atomically". The spec is silent about symlinks. The safe reading: a settings.json that
# is a symlink (for example into a dotfiles repo) stays a symlink, and the linked file gets the hooks.
# Severity: minor (spec silent).
test_attack_spec_install_writes_through_a_symlinked_settings_file() {
  local s dot; s="$(settings_file)"; dot="$TL_TMP/dotfiles/settings.json"
  mkdir -p "$(dirname "$s")" "$(dirname "$dot")"
  printf '%s\n' '{"model":"opus"}' > "$dot"
  ln -s "$dot" "$s"
  tl_kit install --settings "$s"
  assert_exit 0 "$TL_RC"
  [ -L "$s" ] || fail "settings.json was replaced by a regular file; the symlink into the dotfiles folder is gone"
  assert_eq "true" "$(jq 'has("hooks")' "$dot")" "the linked file must receive the hooks"
}

# SPEC (bin/limit-handoff, install): the settings file must keep its other content. The spec is silent
# on permissions. Settings files often hold env values, so the safe reading keeps mode 600.
# Severity: minor (spec silent).
test_attack_spec_install_keeps_file_mode_600() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  printf '%s\n' '{"env":{"EXAMPLE_NAME":"x"}}' > "$s"
  chmod 600 "$s"
  tl_kit install --settings "$s"
  assert_exit 0 "$TL_RC"
  assert_eq "600" "$(tl_file_mode "$s")" "file permissions must not be widened by the install"
}

# SPEC (bin/limit-handoff, install --dry-run): "writes nothing". A dry run must leave no files behind
# in the state folder either. (Passing regression guard.)
test_attack_spec_dry_run_leaves_no_files_behind() {
  local s; s="$(settings_file)"
  tl_kit install --settings "$s" --dry-run
  assert_exit 0 "$TL_RC"
  assert_file_missing "$s" "dry run must not create the settings file"
  local n
  n="$(find "$TL_TMP/state" -type f 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "0" "$n" "dry run must not leave files in the state folder"
}

# SPEC (bin/limit-handoff, install): "Validate JSON before and after; on invalid input JSON -> error,
# exit 2, write nothing." Uninstall shares that path. (Passing regression guard.)
test_attack_spec_uninstall_invalid_json_exits_2_and_changes_nothing() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  printf '%s\n' '{"hooks": ' > "$s"
  cp "$s" "$TL_TMP/before.json"
  tl_kit uninstall --settings "$s"
  assert_exit 2 "$TL_RC"
  assert_same_file "$s" "$TL_TMP/before.json" "invalid JSON must not be changed"
}

# SPEC (bin/limit-handoff, status): read-only. Status must never change a settings file.
# (Passing regression guard.)
test_attack_spec_status_never_writes_settings() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  printf '%s\n' '{"hooks":{}}' > "$s"
  cp "$s" "$TL_TMP/before.json"
  tl_kit status --settings "$s" --dir "$CLAUDE_PROJECT_DIR"
  assert_exit 0 "$TL_RC"
  assert_same_file "$s" "$TL_TMP/before.json" "status must not change the settings file"
}

# SPEC (bin/limit-handoff, install): "uses absolute path of the kit's hooks". Install must write an
# absolute path even when the CLI is started with a relative path. (Passing regression guard.)
test_attack_spec_install_from_relative_invocation_writes_absolute_hook_path() {
  local s; s="$(settings_file)"
  mkdir -p "$(dirname "$s")"
  ( cd "$TL_ROOT" && /bin/bash bin/limit-handoff install --settings "$s" >/dev/null 2>&1 )
  local cmd
  cmd="$(jq -r '.hooks.StopFailure[0].hooks[0].command' "$s")"
  case "$cmd" in
    "'/"*) ;;
    *) fail "hook command must start with an absolute path, got: $cmd" ;;
  esac
}

# SPEC (bin/limit-handoff, exit codes): 0 ok, 1 operational failure, 2 usage error.
# (Passing regression guard.)
test_attack_spec_exit_codes_for_usage_and_operational_errors() {
  local s; s="$(settings_file)"
  tl_kit install --settings "$s" --events bogus-event
  assert_exit 2 "$TL_RC" "unknown event is a usage error"
  tl_kit install --settings "$s" --errors "rate_limit|not_a_code"
  assert_exit 2 "$TL_RC" "unknown error code is a usage error"
  tl_kit install --settings "$s" --errors ""
  assert_exit 2 "$TL_RC" "empty error list is a usage error"
  tl_kit resolve --dir "$CLAUDE_PROJECT_DIR"
  assert_exit 1 "$TL_RC" "resolve without a HANDOFF.md is an operational failure"
  tl_kit recover --transcript "$TL_TMP/no-such.jsonl" --dir "$CLAUDE_PROJECT_DIR" --stdout
  assert_exit 1 "$TL_RC" "recover on a missing transcript is an operational failure"
  tl_kit --version
  assert_exit 0 "$TL_RC"
}

# SPEC (bin/limit-handoff uninstall): "removes only kit entries; backup first". A real change must leave
# a timestamped backup that still holds the original hooks. (Passing regression guard.)
test_attack_spec_uninstall_makes_a_backup_that_keeps_the_original() {
  local s; s="$(settings_file)"
  tl_kit install --settings "$s"
  assert_exit 0 "$TL_RC"
  cp "$s" "$TL_TMP/installed.json"
  tl_kit uninstall --settings "$s"
  assert_exit 0 "$TL_RC"
  local bak
  bak="$(ls "$s".bak-* 2>/dev/null | tail -n 1)"
  [ -n "$bak" ] || fail "uninstall must leave a timestamped backup next to the settings file"
  assert_same_file "$bak" "$TL_TMP/installed.json" "the backup must hold the file as it was before uninstall"
  assert_eq "0" "$(jq '[.. | objects | select(has("command")) | select((.command // "") | test("limit-handoff"))] | length' "$s")" \
    "no kit hooks may remain after uninstall"
}

run_tests
