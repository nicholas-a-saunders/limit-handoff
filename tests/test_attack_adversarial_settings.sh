#!/bin/bash
# Adversarial tests: inputs chosen to break the kit.
# Area: bin/limit-handoff install / uninstall / status on odd settings.json files.
# Rules come from docs/SPEC.md (CLI section).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"


# adv_user_entry_kept_or_refused file before needle: passes when the user's entry is still
# in the file, or when the command refused (non-zero) and left the file exactly as it was.
adv_user_entry_kept_or_refused() {
  local file="$1" before="$2" needle="$3"
  if grep -q -- "$needle" "$file" 2>/dev/null; then
    return 0
  fi
  if [ "$TL_RC" != 0 ] && cmp -s "$before" "$file"; then
    return 0
  fi
  fail "the user's entry '$needle' was silently deleted (exit $TL_RC). SPEC: merge without touching other keys or hooks"
}

# ---------------------------------------------------------------------------
# Odd shapes that other tools may have written. SPEC CLI: merge, never touch other keys/hooks.
# ---------------------------------------------------------------------------

test_install_keeps_user_hooks_when_hooks_is_an_array() {
  local s="$TL_TMP/arr.json" before="$TL_TMP/arr.before"
  printf '%s\n' '{"hooks":[{"matcher":"x","hooks":[{"type":"command","command":"echo mine-array"}]}],"keep":1}' > "$s"
  cp "$s" "$before"
  tl_kit install --settings "$s"
  adv_user_entry_kept_or_refused "$s" "$before" "echo mine-array"
}

test_install_keeps_user_entry_when_an_event_is_an_object() {
  local s="$TL_TMP/obj.json" before="$TL_TMP/obj.before"
  printf '%s\n' '{"hooks":{"StopFailure":{"note":"user-object-note"}},"keep":1}' > "$s"
  cp "$s" "$before"
  tl_kit install --settings "$s"
  adv_user_entry_kept_or_refused "$s" "$before" "user-object-note"
}

test_install_keeps_user_entry_when_an_event_is_a_string() {
  local s="$TL_TMP/str.json" before="$TL_TMP/str.before"
  printf '%s\n' '{"hooks":{"PreCompact":"user-string-value"},"keep":2}' > "$s"
  cp "$s" "$before"
  tl_kit install --settings "$s"
  adv_user_entry_kept_or_refused "$s" "$before" "user-string-value"
}

test_uninstall_keeps_a_user_hook_that_only_looks_like_the_kit() {
  local s="$TL_TMP/own.json"
  printf '%s\n' '{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":"/Users/me/handoff-notes/hooks/pre-compact.sh"}]}]}}' > "$s"
  tl_kit uninstall --settings "$s"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$s" "/Users/me/handoff-notes/hooks/pre-compact.sh" "a user's own hook was removed because its folder name contains 'handoff' (minor: the spec's rule is ambiguous)"
}

test_install_with_a_non_text_hook_command_gives_a_readable_result() {
  local s="$TL_TMP/num.json"
  printf '%s\n' '{"hooks":{"StopFailure":[{"hooks":[{"type":"command","command":5}]}]},"keep":1}' > "$s"
  tl_kit install --settings "$s"
  assert_not_contains "$TL_ERR" "jq: error" "raw jq errors must not leak to the user (minor)"
}

test_status_does_not_claim_no_kit_hooks_when_settings_cannot_be_read() {
  local s="$TL_TMP/arr2.json"
  printf '%s\n' '{"hooks":{"PreCompact":[{"hooks":[{"type":"command","command":["a"]}]}]}}' > "$s"
  tl_kit status --settings "$s" --dir "$CLAUDE_PROJECT_DIR"
  assert_not_contains "$(printf '%s\n' "$TL_OUT" | grep 'Kit hooks')" ": none" "status said 'none' when it could not read the hooks (minor)"
}

# ---------------------------------------------------------------------------
# File safety. SPEC CLI: backups and atomic writes. Mode and links are not in the spec (minor).
# ---------------------------------------------------------------------------

test_install_keeps_the_file_mode_of_a_settings_file_with_secrets() {
  local s="$TL_TMP/secret.json"
  printf '%s\n' '{"env":{"API_TOKEN":"not-a-real-value"},"theme":"dark"}' > "$s"
  chmod 600 "$s"
  tl_kit install --settings "$s"
  assert_exit 0 "$TL_RC"
  assert_eq "600" "$(tl_file_mode "$s")" "install made a 600 settings file (it can hold tokens) readable by others (minor)"
}

test_install_keeps_a_symlinked_settings_file_as_a_link() {
  local real="$TL_TMP/dotfiles/settings.json" link="$TL_TMP/claude-settings.json"
  mkdir -p "$TL_TMP/dotfiles"
  printf '%s\n' '{"theme":"light"}' > "$real"
  ln -s "$real" "$link"
  tl_kit install --settings "$link"
  assert_exit 0 "$TL_RC"
  if [ ! -L "$link" ]; then
    fail "the symlink was replaced by a plain copy; the real dotfiles file no longer changes (minor)"
  fi
  assert_file_contains "$real" "limit-handoff" "the file the link points to must get the hooks (minor)"
}

test_install_refuses_comments_and_leaves_the_file_alone() {
  local s="$TL_TMP/jsonc.json"
  printf '%s\n' '{' '  // a comment' '  "theme": "dark",' '  "hooks": {}' '}' > "$s"
  cp "$s" "$TL_TMP/jsonc.before"
  tl_kit install --settings "$s"
  assert_exit 2 "$TL_RC" "settings with comments must be refused with exit 2"
  assert_same_file "$TL_TMP/jsonc.before" "$s" "the file changed after a refusal"
}

test_dry_run_writes_no_files_at_all() {
  local dir="$TL_TMP/dryset" s
  mkdir -p "$dir"
  s="$dir/settings.json"
  printf '%s\n' '{"theme":"dark"}' > "$s"
  cp "$s" "$TL_TMP/dry.before"
  tl_kit install --settings "$s" --dry-run
  assert_exit 0 "$TL_RC"
  assert_same_file "$TL_TMP/dry.before" "$s" "dry run changed the settings file"
  assert_eq "1" "$(ls -A "$dir" | wc -l | tr -d ' ')" "dry run created files next to the settings file"
  if [ -n "$(ls -A "$LIMIT_HANDOFF_STATE_DIR" 2>/dev/null | grep '^dry-')" ]; then
    fail "dry run left temporary dry-old/dry-new files in the state folder"
  fi
}

test_install_then_uninstall_round_trip_restores_user_content() {
  local s="$TL_TMP/round.json" before_norm after_norm
  printf '%s\n' '{"theme":"dark","model":"x","hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo keep-me"}]}]},"env":{"A":"1"}}' > "$s"
  before_norm="$(jq -S . "$s")"
  tl_kit install --settings "$s"
  assert_exit 0 "$TL_RC"
  tl_kit uninstall --settings "$s"
  assert_exit 0 "$TL_RC"
  after_norm="$(jq -S . "$s")"
  assert_eq "$before_norm" "$after_norm" "install then uninstall must give back the same user content"
}

test_install_with_a_quote_in_the_settings_path_works() {
  local s="$TL_TMP/settings with 'quote' and \$dollar.json"
  printf '%s\n' '{"theme":"dark"}' > "$s"
  tl_kit install --settings "$s"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$s" "limit-handoff" "hooks must be written into a file whose name has quotes and \$"
}

test_install_rejects_bad_option_values_with_exit_two() {
  local s="$TL_TMP/opts.json"
  printf '%s\n' '{}' > "$s"
  cp "$s" "$TL_TMP/opts.before"
  tl_kit install --settings "$s" --errors "rate_limit,made_up_code"
  assert_exit 2 "$TL_RC" "an unknown error code must be a usage error"
  tl_kit install --settings "$s" --events "stop-failure,nonsense"
  assert_exit 2 "$TL_RC" "an unknown event must be a usage error"
  assert_same_file "$TL_TMP/opts.before" "$s" "a usage error changed the file"
}

run_tests
