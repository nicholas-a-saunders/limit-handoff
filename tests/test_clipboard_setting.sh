#!/bin/bash
# Tests for how LIMIT_HANDOFF_CLIPBOARD is chosen and used.
#
# Regression tests for two bugs found in a first-time review:
#   1. simulate set its own environment value, which beat the user's config file.
#   2. A clipboard name that was not usable did nothing visible, so the user could
#      not tell why nothing was copied.
# The test PATH puts the pbcopy shim first, so "auto" would always find it. A test
# that expects nothing to be copied therefore proves the tool was not used.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

user_config_file() { printf '%s\n' "$XDG_CONFIG_HOME/limit-handoff/config"; }

write_user_config() {
  mkdir -p "$(dirname "$(user_config_file)")"
  printf '%s\n' "$1" > "$(user_config_file)"
}

test_copy_uses_clipboard_from_user_config_file() {
  # A custom tool name that only the config file can select. "auto" would pick the
  # pbcopy shim instead, so the test shows whether the config file really won.
  unset LIMIT_HANDOFF_CLIPBOARD   # tl_setup exports "off", and an environment value beats the config file
  mkdir -p "$TL_TMP/mybin"
  printf '#!/bin/bash\ncat > "%s/custom-clip.txt"\n' "$TEST_OUT" > "$TL_TMP/mybin/my-clip"
  chmod +x "$TL_TMP/mybin/my-clip"
  export PATH="$TL_TMP/mybin:$PATH"
  write_user_config "LIMIT_HANDOFF_CLIPBOARD=my-clip"
  tl_kit simulate --dir "$CLAUDE_PROJECT_DIR" --copy
  assert_exit 0 "$TL_RC"
  assert_file_exists "$TEST_OUT/custom-clip.txt" "the user config file should choose my-clip"
  assert_file_contains "$TEST_OUT/custom-clip.txt" "Continue my task"
  assert_file_missing "$TEST_OUT/clipboard.txt" "auto (pbcopy) must not be used when the config names another tool"
}

test_simulate_without_copy_never_uses_clipboard() {
  unset LIMIT_HANDOFF_CLIPBOARD
  write_user_config "LIMIT_HANDOFF_CLIPBOARD=pbcopy"
  tl_kit simulate --dir "$CLAUDE_PROJECT_DIR"
  assert_exit 0 "$TL_RC"
  assert_file_missing "$TEST_OUT/clipboard.txt" "simulate without --copy must not touch the clipboard"
}

test_project_file_cannot_choose_the_clipboard() {
  unset LIMIT_HANDOFF_CLIPBOARD
  write_user_config "LIMIT_HANDOFF_CLIPBOARD=pbcopy"
  mkdir -p "$CLAUDE_PROJECT_DIR/.claude"
  printf '%s\n' "LIMIT_HANDOFF_CLIPBOARD=off" > "$CLAUDE_PROJECT_DIR/.claude/limit-handoff.conf"
  tl_kit simulate --dir "$CLAUDE_PROJECT_DIR" --copy
  assert_exit 0 "$TL_RC"
  assert_file_exists "$TEST_OUT/clipboard.txt" "the project file's off must be ignored, so the user config's pbcopy is used"
}

test_path_value_is_refused_logged_and_nothing_is_copied() {
  export LIMIT_HANDOFF_CLIPBOARD="/bin/cat"
  tl_kit simulate --dir "$CLAUDE_PROJECT_DIR" --copy
  assert_exit 0 "$TL_RC"
  assert_file_missing "$TEST_OUT/clipboard.txt" "a path must never be run as a clipboard tool"
  assert_file_exists "$CLAUDE_PROJECT_DIR/PASTE-PROMPT.txt" "the paste prompt file is still written"
  assert_file_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "must be auto, off, or a bare command name"
}

test_missing_tool_name_never_falls_back_to_pbcopy() {
  # The pbcopy shim IS on PATH. A name that is not found must not run it instead.
  export LIMIT_HANDOFF_CLIPBOARD="no-such-clip-tool"
  tl_kit simulate --dir "$CLAUDE_PROJECT_DIR" --copy
  assert_exit 0 "$TL_RC"
  assert_file_missing "$TEST_OUT/clipboard.txt" "a missing tool name must not fall back to pbcopy"
  assert_file_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "is not found on your PATH"
}

test_doctor_reports_the_clipboard_setting() {
  export LIMIT_HANDOFF_CLIPBOARD="/bin/cat"
  tl_kit doctor
  assert_exit 0 "$TL_RC" "a bad clipboard setting is a warning, not a failure"
  assert_contains "$TL_OUT" "clipboard setting '/bin/cat' is not allowed"

  export LIMIT_HANDOFF_CLIPBOARD="pbcopy"
  tl_kit doctor
  assert_contains "$TL_OUT" "clipboard setting: pbcopy (found on PATH)"

  export LIMIT_HANDOFF_CLIPBOARD="off"
  tl_kit doctor
  assert_contains "$TL_OUT" "clipboard setting: off"
}

test_install_bad_event_lists_the_valid_names() {
  tl_kit install --settings "$TL_TMP/home/.claude/settings.json" --events bogus
  assert_exit 2 "$TL_RC"
  assert_contains "$TL_ERR" "Valid events: stop-failure, prompt-submit, session-start, pre-compact"
}

run_tests
