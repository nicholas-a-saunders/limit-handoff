#!/bin/bash
# Tests for the command name in hook messages (hk_cli_hint), the doctor checks (hooks
# registered twice, Claude Code version) and the install warning for an enabled plugin.
#
# The real claude command is never run here. tests/shims/claude is a guard that stays first
# on the test PATH. A test that needs a version makes its own fake claude in a temp folder,
# and a test that needs "claude not found" builds a folder of links with no claude in it.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# unresolved_handoff: writes a HANDOFF.md with one unresolved cut-off block in the project folder.
unresolved_handoff() {
  printf '%s\n' '# H' '' \
    '<!-- limit-handoff:cutoff session="cut" at="2026-10-29T10:00:00Z" error="rate_limit" status="unresolved" -->' \
    '> ⚠️ **Session cut off** (usage limit reached) at 2026-10-29 10:00. The steps above may be slightly behind.' \
    '> Check the files for a half-finished step before continuing. Recovered context: `.handoff/recovered-20261029-100000-cut.md`' \
    '<!-- /limit-handoff:cutoff -->' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
}

# copy_kit dir: copies the parts of the kit that the hooks and the CLI need into dir.
copy_kit() {
  mkdir -p "$1"
  cp -pR "$TL_ROOT/bin" "$TL_ROOT/lib" "$TL_ROOT/hooks" "$TL_ROOT/templates" "$TL_ROOT/config" "$1/"
}

# fake_claude name text: makes a folder with a claude command that prints text for any
# arguments. Prints the folder path. The text is kept in a data file, so quotes in it are safe.
fake_claude() {
  local d="$TL_TMP/fake-$1"
  mkdir -p "$d"
  printf '%s\n' "$2" > "$d/version.txt"
  printf '#!/bin/bash\ncat "%s"\n' "$d/version.txt" > "$d/claude"
  chmod +x "$d/claude"
  printf '%s\n' "$d"
}

# no_claude_dir: prints a folder of links to the system tools, with no claude command in it.
# jq is linked too, so the doctor still works.
no_claude_dir() {
  local d="$TL_TMP/no-claude-bin" f n
  mkdir -p "$d"
  for f in /bin/* /usr/bin/*; do
    n="${f##*/}"
    [ "$n" = "claude" ] && continue
    [ -e "$d/$n" ] || ln -s "$f" "$d/$n" 2>/dev/null
  done
  [ -e "$d/jq" ] || ln -s "$(command -v jq)" "$d/jq"
  printf '%s\n' "$d"
}

# ---------------------------------------------------------------------------
# The command name in hook messages
# ---------------------------------------------------------------------------

test_hint_is_the_plain_name_in_plugin_mode() {
  unresolved_handoff
  tl_run "$TL_HOOK_PROMPT" "$(tl_payload_plain UserPromptSubmit "h1" "$CLAUDE_PROJECT_DIR" "")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" 'run `limit-handoff resolve`' "plugin mode names the command"
  assert_not_contains "$TL_OUT" "$TL_ROOT/bin/limit-handoff" "no full path in plugin mode"
}

test_session_start_hint_is_the_plain_name_in_plugin_mode() {
  unresolved_handoff
  tl_run "$TL_HOOK_SESSION" "$(tl_payload_plain SessionStart "s1" "$CLAUDE_PROJECT_DIR" "startup")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" 'run `limit-handoff resolve`' "session start names the command the same way"
}

test_hint_is_the_quoted_full_path_for_a_kit_copy_with_a_space() {
  # No plugin root: this is a settings.json install. The kit sits in a folder with a space.
  unset CLAUDE_PLUGIN_ROOT
  local copy="$TL_TMP/my kit"
  copy_kit "$copy"
  unresolved_handoff
  tl_run "$copy/hooks/prompt-submit.sh" "$(tl_payload_plain UserPromptSubmit "h3" "$CLAUDE_PROJECT_DIR" "")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "run \`'$copy/bin/limit-handoff' resolve\`" "full path, in single quotes because of the space"
  assert_not_contains "$TL_OUT" 'run `limit-handoff resolve`' "the plain name is not used outside plugin mode"
  tl_run "$copy/hooks/session-start.sh" "$(tl_payload_plain SessionStart "s3" "$CLAUDE_PROJECT_DIR" "startup")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "run \`'$copy/bin/limit-handoff' resolve\`" "session start quotes the path too"
}

test_hint_is_the_full_path_when_the_plugin_root_is_another_folder() {
  # CLAUDE_PLUGIN_ROOT points somewhere else, so the hook's own kit is not the plugin in use.
  local other="$TL_TMP/other-plugin"
  mkdir -p "$other"
  export CLAUDE_PLUGIN_ROOT="$other"
  unresolved_handoff
  tl_run "$TL_HOOK_PROMPT" "$(tl_payload_plain UserPromptSubmit "h4" "$CLAUDE_PROJECT_DIR" "")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "run \`$TL_ROOT/bin/limit-handoff resolve\`" "no quotes when there is no space"
}

test_hint_counts_a_symlinked_plugin_root_as_the_same_folder() {
  ln -s "$TL_ROOT" "$TL_TMP/plugin-link"
  export CLAUDE_PLUGIN_ROOT="$TL_TMP/plugin-link"
  unresolved_handoff
  tl_run "$TL_HOOK_PROMPT" "$(tl_payload_plain UserPromptSubmit "h5" "$CLAUDE_PROJECT_DIR" "")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" 'run `limit-handoff resolve`' "a link to this folder is the plugin in use"
}

test_cli_hint_function_direct_cases() {
  . "$TL_ROOT/lib/common.sh"
  CLAUDE_PLUGIN_ROOT="$TL_ROOT"
  assert_eq "limit-handoff" "$(hk_cli_hint)" "same folder as the plugin root"
  unset CLAUDE_PLUGIN_ROOT
  assert_eq "$TL_ROOT/bin/limit-handoff" "$(hk_cli_hint)" "no plugin root gives the full path"
}

test_cli_hint_escapes_a_single_quote_in_the_path() {
  # A folder name with an apostrophe. The hint must quote it the shell way: '...'\''...'
  unset CLAUDE_PLUGIN_ROOT
  local copy="$TL_TMP/it's a kit"
  copy_kit "$copy"
  . "$copy/lib/common.sh"
  assert_eq "'$TL_TMP/it'\\''s a kit/bin/limit-handoff'" "$(hk_cli_hint)" "apostrophe is escaped"
}

test_version_compare_rules() {
  . "$TL_ROOT/lib/common.sh"
  hk_version_at_least "2.1.312" "2.1.78" || fail "2.1.312 should count as at least 2.1.78"
  hk_version_at_least "2.1.78" "2.1.78" || fail "the same version should count as at least itself"
  if hk_version_at_least "2.1.50" "2.1.78"; then fail "2.1.50 is older than 2.1.78"; fi
  hk_version_at_least "2.10.0" "2.9.99" || fail "2.10.0 is newer than 2.9.99 (numbers, not text)"
  hk_version_at_least "3.0.0" "2.1.78" || fail "3.0.0 is newer than 2.1.78"
  if hk_version_at_least "claude" "2.1.78"; then fail "text that is not a version must fail"; fi
}

# ---------------------------------------------------------------------------
# doctor: Claude Code version
# ---------------------------------------------------------------------------

test_doctor_version_ok_for_a_new_claude() {
  export PATH="$(fake_claude new "2.1.312 (Claude Code)"):$PATH"
  tl_kit doctor
  assert_exit 0 "$TL_RC" "a version note never fails doctor"
  assert_contains "$TL_OUT" "[ok]   Claude Code 2.1.312" "a new version is ok"
}

test_doctor_version_warns_for_an_old_claude_and_still_exits_zero() {
  export PATH="$(fake_claude old "2.1.50 (Claude Code)"):$PATH"
  tl_kit doctor
  assert_exit 0 "$TL_RC" "an old version is only a warning"
  assert_contains "$TL_OUT" "[warn] Claude Code 2.1.50 is older than 2.1.78" "an old version warns"
}

test_doctor_version_info_when_claude_is_not_on_path() {
  export PATH="$(no_claude_dir)"
  tl_kit doctor
  assert_exit 0 "$TL_RC" "a missing claude is only a note"
  assert_contains "$TL_OUT" "[info] claude command not found on PATH" "missing claude gives an info line"
  assert_contains "$TL_OUT" "All required checks passed."
}

test_doctor_version_info_when_the_version_cannot_be_read() {
  export PATH="$(fake_claude odd "something else entirely"):$PATH"
  tl_kit doctor
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "[info] could not read a version" "text with no x.y.z gives an info line"
}

test_test_guard_keeps_the_real_claude_out_of_the_suite() {
  # With the default test PATH, the guard shim answers instead of the real claude.
  tl_kit doctor
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "[info] could not read a version" "the guard prints no version"
}

# ---------------------------------------------------------------------------
# doctor: hooks registered twice
# ---------------------------------------------------------------------------

test_doctor_warns_when_hooks_and_plugin_are_both_on() {
  local f="$TL_TMP/home/.claude/settings.json" before="$TL_TMP/before.json"
  mkdir -p "$(dirname "$f")"
  tl_kit install --settings "$f"
  assert_exit 0 "$TL_RC"
  jq '.enabledPlugins = {"limit-handoff@acme": true}' "$f" > "$TL_TMP/s.json" && mv "$TL_TMP/s.json" "$f"
  cp "$f" "$before"
  tl_kit doctor --settings "$f"
  assert_exit 0 "$TL_RC" "a double registration is only a warning"
  assert_contains "$TL_OUT" "[warn] limit-handoff hooks are registered twice" "double registration warns"
  assert_contains "$TL_OUT" "limit-handoff uninstall --settings $f" "the fix is named"
  assert_same_file "$f" "$before" "doctor only reads the settings file"
}

test_doctor_uses_the_default_settings_file_when_no_flag() {
  local f="$HOME/.claude/settings.json"
  mkdir -p "$(dirname "$f")"
  tl_kit install --settings "$f"
  jq '.enabledPlugins = {"limit-handoff@acme": true}' "$f" > "$TL_TMP/s.json" && mv "$TL_TMP/s.json" "$f"
  tl_kit doctor
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "[warn] limit-handoff hooks are registered twice" "the default ~/.claude/settings.json is checked"
  assert_contains "$TL_OUT" "$f" "the default file is named"
}

test_doctor_does_not_warn_with_only_one_registration() {
  local f="$TL_TMP/home/.claude/settings.json"
  mkdir -p "$(dirname "$f")"
  # Kit hooks in the settings file, plugin not turned on.
  tl_kit install --settings "$f"
  tl_kit doctor --settings "$f"
  assert_exit 0 "$TL_RC"
  assert_not_contains "$TL_OUT" "registered twice" "hooks only in settings is fine"
  # Plugin turned on, no kit hooks in the settings file.
  printf '%s\n' '{"enabledPlugins": {"limit-handoff@acme": true}}' > "$f"
  tl_kit doctor --settings "$f"
  assert_exit 0 "$TL_RC"
  assert_not_contains "$TL_OUT" "registered twice" "plugin only is fine"
  # Plugin switched off, kit hooks present.
  tl_kit install --settings "$f"
  jq '.enabledPlugins = {"limit-handoff@acme": false}' "$f" > "$TL_TMP/s.json" && mv "$TL_TMP/s.json" "$f"
  tl_kit doctor --settings "$f"
  assert_exit 0 "$TL_RC"
  assert_not_contains "$TL_OUT" "registered twice" "a plugin that is switched off does not count"
}

test_doctor_settings_file_missing_is_a_note() {
  tl_kit doctor --settings "$TL_TMP/no-such-settings.json"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "[info] settings file not found" "a missing file is a note"
  assert_not_contains "$TL_OUT" "registered twice"
}

test_doctor_help_and_usage_errors_for_settings_flag() {
  tl_kit doctor --help
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "doctor    [--settings FILE]" "usage names the flag"
  tl_kit doctor --settings
  assert_exit 2 "$TL_RC" "--settings needs a file"
  tl_kit doctor --bogus
  assert_exit 2 "$TL_RC" "unknown option is a usage error"
}

# ---------------------------------------------------------------------------
# install: warning when the plugin is already on
# ---------------------------------------------------------------------------

test_install_warns_when_the_plugin_is_already_on_and_still_installs() {
  local f="$TL_TMP/home/.claude/settings.json"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' '{"enabledPlugins": {"limit-handoff@acme": true}}' > "$f"
  tl_kit install --settings "$f"
  assert_exit 0 "$TL_RC" "the install still goes ahead"
  assert_contains "$TL_ERR" "already turned on" "the warning goes to stderr"
  assert_contains "$TL_ERR" "twice" "the warning says each hook would run twice"
  assert_contains "$TL_OUT" "Installed limit-handoff hooks" "the hooks were written"
  assert_json "$f" '.hooks.StopFailure | length' 1 "the StopFailure hook is in the file"
  assert_json "$f" '.enabledPlugins["limit-handoff@acme"]' true "the plugin setting is left alone"
}

test_install_is_quiet_when_no_limit_handoff_plugin_is_on() {
  local f="$TL_TMP/home/.claude/settings.json"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' '{"enabledPlugins": {"limit-handoff@acme": false, "other@acme": true}}' > "$f"
  tl_kit install --settings "$f"
  assert_exit 0 "$TL_RC"
  assert_not_contains "$TL_ERR" "already turned on" "no warning when the plugin is off"
}

run_tests
