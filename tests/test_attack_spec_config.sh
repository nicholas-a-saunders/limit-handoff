#!/bin/bash
# test_attack_spec_config.sh - adversarial SPEC conformance tests for configuration and file paths.
#
# Each test names the SPEC section it checks. Where the spec is silent, the test uses the safe reading
# and the severity is minor.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

run_stop() {
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "$1" "$2" "$3" "$4")"
}

# SPEC (Config): resolution order env > project file > user file > default. End to end: the project
# file must beat the user file for an ordinary key. (Passing regression guard.)
test_attack_spec_project_config_beats_user_config_end_to_end() {
  local p; p="$CLAUDE_PROJECT_DIR"
  mkdir -p "$XDG_CONFIG_HOME/limit-handoff" "$p/.claude"
  printf 'LIMIT_HANDOFF_PROMPTS=3\n' > "$XDG_CONFIG_HOME/limit-handoff/config"
  printf 'LIMIT_HANDOFF_PROMPTS=1\n' > "$p/.claude/limit-handoff.conf"
  unset LIMIT_HANDOFF_PROMPTS
  run_stop "cfg-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  local rec
  rec="$(ls -t "$p/.handoff"/recovered-*.md 2>/dev/null | head -n 1)"
  assert_file_exists "$rec"
  assert_count "$rec" "**Message " 1 "project file says 1 prompt; the user file says 3"
}

# SPEC (Config table): LIMIT_HANDOFF_STATE_DIR is a path. The kit's own example config shows it as
# "~/.local/state/limit-handoff". The safe reading: "~" means the home folder. Today a literal "~" folder
# is created inside the project, and the log is written there.
# Severity: minor (spec is silent on "~" in config values; the kit's example file uses it).
test_attack_spec_tilde_in_state_dir_config_expands_to_home() {
  local p; p="$CLAUDE_PROJECT_DIR"
  unset LIMIT_HANDOFF_STATE_DIR
  mkdir -p "$XDG_CONFIG_HOME/limit-handoff"
  printf 'LIMIT_HANDOFF_STATE_DIR=~/tilde-state\n' > "$XDG_CONFIG_HOME/limit-handoff/config"
  # Claude Code runs hooks from the project folder, so the hook's working folder is the project.
  cd "$p" || fail "cannot enter the project folder"
  run_stop "tilde-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  cd "$TL_TMP" || true
  assert_exit 0 "$TL_RC"
  [ ! -e "$p/~" ] || fail "a literal '~' folder was created inside the project folder"
  assert_file_exists "$HOME/tilde-state/limit-handoff.log" "the log belongs in the state folder under HOME"
}

# SPEC (Config table): the default state folder is "${CLAUDE_PLUGIN_DATA:-$HOME/.local/state/limit-handoff}".
# The build used to honour XDG_STATE_HOME first. It now follows the spec (fixer pass, DECISIONS #36).
# Severity: minor (docs/DECISIONS.md #36 records this, so the spec owner may want to amend the spec).
test_attack_spec_default_state_dir_is_home_local_state() {
  unset LIMIT_HANDOFF_STATE_DIR CLAUDE_PLUGIN_DATA
  run_stop "state-sess" "$(tl_fixture basic.jsonl)" "$CLAUDE_PROJECT_DIR" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$HOME/.local/state/limit-handoff/limit-handoff.log" \
    "with no CLAUDE_PLUGIN_DATA and no env override, the spec default is \$HOME/.local/state/limit-handoff"
}

# SPEC (Config table + "Hard constraints": never write outside the project dir except the state dir):
# LIMIT_HANDOFF_PROMPT_FILE is set to HANDOFF.md. The spec is silent about clashes. The safe reading:
# the paste prompt must never overwrite the handoff file. Today the handoff content is replaced.
# Severity: minor (spec silent).
test_attack_spec_prompt_file_setting_cannot_overwrite_handoff() {
  local p; p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# HANDOFF - keep me' '' '## Next steps' '1. Keep going' > "$p/HANDOFF.md"
  export LIMIT_HANDOFF_PROMPT_FILE=HANDOFF.md
  run_stop "clash-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "keep me" "the handoff file must keep its own text"
}

# SPEC (Config): "Config file ... keys ... Order: env var > project .claude/limit-handoff.conf >
# user ~/.config/limit-handoff/config > default." That literal order would let a cloned repository
# name any program that receives the paste prompt. The build keeps a security rule instead
# (docs/DECISIONS.md #37): LIMIT_HANDOFF_CLIPBOARD and LIMIT_HANDOFF_NOTIFY are read from the environment
# and the user file only. test_common.sh (test_trusted_keys_ignore_project_file) enforces that rule.
# This test was changed to match it. It was originally written to the literal spec order.
# Severity: minor (spec conflict, recorded in docs/DECISIONS.md #37 for the spec owner to decide).
test_attack_spec_project_config_can_choose_clipboard_command() {
  local p; p="$CLAUDE_PROJECT_DIR"
  mkdir -p "$TL_TMP/bin" "$p/.claude"
  cat > "$TL_TMP/bin/custom-copy" <<'SH'
#!/bin/bash
cat > "$TEST_OUT/custom-copy.txt"
SH
  chmod +x "$TL_TMP/bin/custom-copy"
  export PATH="$TL_TMP/bin:$PATH"
  unset LIMIT_HANDOFF_CLIPBOARD
  printf 'LIMIT_HANDOFF_CLIPBOARD=custom-copy\n' > "$p/.claude/limit-handoff.conf"
  run_stop "clip-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_missing "$TEST_OUT/custom-copy.txt" "a project config must not choose the program that receives the paste prompt (docs/DECISIONS.md #37)"
  assert_file_exists "$p/PASTE-PROMPT.txt" "the paste prompt must still be saved to the project"
}

# SPEC (Config table): LIMIT_HANDOFF_FILE is a name inside the project. Absolute paths, "~", and ".."
# must fall back to the default name, and nothing may be written outside the project.
# (Passing regression guard.)
test_attack_spec_unsafe_handoff_names_fall_back_inside_project() {
  local p; p="$CLAUDE_PROJECT_DIR"
  export LIMIT_HANDOFF_FILE="$TL_TMP/outside-abs.md"
  run_stop "abs-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_file_missing "$TL_TMP/outside-abs.md" "an absolute LIMIT_HANDOFF_FILE must not be used"
  assert_file_exists "$p/HANDOFF.md" "fallback name is HANDOFF.md inside the project"
  rm -f "$p/HANDOFF.md"

  export LIMIT_HANDOFF_FILE="~/tilde-outside.md"
  run_stop "tilde-name-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_file_missing "$HOME/tilde-outside.md" "a tilde name must not expand to the home folder"
  assert_file_exists "$p/HANDOFF.md"
  rm -f "$p/HANDOFF.md"

  export LIMIT_HANDOFF_FILE="a/../../escape.md"
  run_stop "dotdot-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_file_missing "$TL_TMP/escape.md" "a parent-folder name must not escape the project"
  assert_file_exists "$p/HANDOFF.md"
}

run_tests
