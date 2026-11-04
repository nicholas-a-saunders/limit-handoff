#!/bin/bash
# Tests for lib/common.sh helpers.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_common() {
  . "$TL_ROOT/lib/common.sh"
  HK_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
}

test_render_template_single_pass_and_literal_values() {
  load_common
  local t="$TL_TMP/t.md" out
  printf '%s\n' 'A={{ONE}} B={{TWO}} C={{MISSING}} D={{ONE}}' > "$t"
  # The value of ONE contains another placeholder and printf/shell text. It must stay literal.
  out="$(hk_render_template "$t" 'ONE={{TWO}} %s $(touch nope) `x`' 'TWO=two')"
  assert_eq 'A={{TWO}} %s $(touch nope) `x` B=two C={{MISSING}} D={{TWO}} %s $(touch nope) `x`' "$out"
  assert_file_missing "$TL_TMP/nope" "shell text in a value must never run"
}

test_render_template_multiline_value() {
  load_common
  local t="$TL_TMP/t.md" out
  printf '%s\n' 'Start' '{{BODY}}' 'End' > "$t"
  out="$(hk_render_template "$t" "BODY=$(printf 'line one\nline two')")"
  assert_eq "$(printf 'Start\nline one\nline two\nEnd')" "$out"
}

test_render_template_ignores_bad_keys() {
  load_common
  local t="$TL_TMP/t.md" out
  printf '%s\n' '{{lower}} {{OK}}' > "$t"
  out="$(hk_render_template "$t" 'lower=bad' 'OK=good')"
  assert_eq "{{lower}} good" "$out"
}

test_first_next_step_formats() {
  load_common
  local f="$TL_TMP/h.md"
  printf '%s\n' '## Next steps (in order)' '1. Numbered step' '2. Second' > "$f"
  assert_eq "Numbered step" "$(hk_first_next_step "$f")"
  printf '%s\n' '## Next steps' '- Dash bullet' > "$f"
  assert_eq "Dash bullet" "$(hk_first_next_step "$f")"
  printf '%s\n' '## Next steps' '* Star bullet' > "$f"
  assert_eq "Star bullet" "$(hk_first_next_step "$f")"
  printf '%s\n' '## Next steps' '3) Paren number' > "$f"
  assert_eq "Paren number" "$(hk_first_next_step "$f")"
  printf '%s\n' '## Next steps' '- [ ] Open checkbox' > "$f"
  assert_eq "Open checkbox" "$(hk_first_next_step "$f")"
  printf '%s\n' '## Next steps' '- [x] Done box' '- [~] Half box' > "$f"
  assert_eq "Half box" "$(hk_first_next_step "$f")" "a finished item is always skipped (DECISIONS #192)"
}

test_first_next_step_stops_at_next_heading_and_handles_no_section() {
  load_common
  local f="$TL_TMP/h2.md"
  printf '%s\n' '## Goal' '1. Not this one' '## Next steps' 'Plain text first' '## Later' '1. Not this either' > "$f"
  assert_eq "" "$(hk_first_next_step "$f")" "plain text is not a list item, and the next heading ends the section"
  printf '%s\n' '## Other' '1. Nope' > "$f"
  assert_eq "" "$(hk_first_next_step "$f")" "no Next steps section gives nothing"
  assert_eq "" "$(hk_first_next_step "$TL_TMP/does-not-exist.md")"
}

test_reason_text() {
  load_common
  assert_eq "rate or usage limit reached" "$(hk_reason_for rate_limit)"
  assert_eq "billing/credit limit" "$(hk_reason_for billing_error)"
  assert_eq "API overloaded" "$(hk_reason_for overloaded)"
  assert_eq "API server error" "$(hk_reason_for server_error)"
  assert_eq "unknown API error" "$(hk_reason_for unknown)"
  assert_eq "unknown API error" "$(hk_reason_for "")"
  assert_eq "model_not_found" "$(hk_reason_for model_not_found)"
}

test_clean_token_removes_unsafe_characters() {
  load_common
  assert_eq "abc-123_X" "$(hk_clean_token 'abc-123_X')"
  assert_eq "touchrm" "$(hk_clean_token '$(touch)rm')"
  local bad
  bad='";`|'
  assert_eq "" "$(hk_clean_token "$bad")"
  local long; long="$(hk_clean_token "$(printf 'a%.0s' $(seq 1 60))")"
  assert_eq "40" "${#long}"
}

test_safe_relative_paths() {
  load_common
  hk_safe_rel "HANDOFF.md" || fail "plain name should be allowed"
  hk_safe_rel "docs/STATUS.md" || fail "sub folder should be allowed"
  hk_safe_rel "my notes.md" || fail "spaces should be allowed"
  if hk_safe_rel "/etc/passwd"; then fail "absolute path accepted"; fi
  if hk_safe_rel "../../etc/passwd"; then fail "parent traversal accepted"; fi
  if hk_safe_rel "a/../../b"; then fail "embedded traversal accepted"; fi
  if hk_safe_rel "./x"; then fail "dot segment accepted"; fi
  if hk_safe_rel 'x;rm -rf y'; then fail "shell characters accepted"; fi
  if hk_safe_rel '$(touch x)'; then fail "command substitution accepted"; fi
  if hk_safe_rel ""; then fail "empty name accepted"; fi
}

test_config_precedence_env_project_user_default() {
  load_common
  local proj="$TL_TMP/proj" userconf="$XDG_CONFIG_HOME/limit-handoff/config"
  mkdir -p "$proj/.claude" "$(dirname "$userconf")"
  HK_PROJECT_DIR="$proj"
  assert_eq "default-val" "$(hk_conf LIMIT_HANDOFF_TAIL_LINES default-val)"
  printf 'LIMIT_HANDOFF_TAIL_LINES=111\n' > "$userconf"
  assert_eq "111" "$(hk_conf LIMIT_HANDOFF_TAIL_LINES 9)" "user file beats default"
  printf 'LIMIT_HANDOFF_TAIL_LINES=222\n' > "$proj/.claude/limit-handoff.conf"
  assert_eq "222" "$(hk_conf LIMIT_HANDOFF_TAIL_LINES 9)" "project file beats user file"
  assert_eq "333" "$(LIMIT_HANDOFF_TAIL_LINES=333 hk_conf LIMIT_HANDOFF_TAIL_LINES 9)" "environment beats project file"
}

test_config_parsing_is_safe_and_line_based() {
  load_common
  local proj="$TL_TMP/proj2"
  mkdir -p "$proj/.claude"
  HK_PROJECT_DIR="$proj"
  cat > "$proj/.claude/limit-handoff.conf" <<'CONF'
# a comment
LIMIT_HANDOFF_PROMPTS="7"
LIMIT_HANDOFF_TAIL_LINES = 55
LIMIT_HANDOFF_FILE=$(touch pwned-by-config)
evil=1
LIMIT_HANDOFF_STALE_MIN=3
CONF
  assert_eq "7" "$(hk_conf LIMIT_HANDOFF_PROMPTS 5)" "quotes around the value are removed"
  assert_eq "55" "$(hk_conf LIMIT_HANDOFF_TAIL_LINES 1)" "spaces around = are not part of the key, value is trimmed"
  assert_eq '$(touch pwned-by-config)' "$(hk_conf LIMIT_HANDOFF_FILE HANDOFF.md)" "config values are text, never run"
  assert_file_missing "$HK_PROJECT_DIR/pwned-by-config" "config must never execute"
  assert_eq "3" "$(hk_int_conf LIMIT_HANDOFF_STALE_MIN 20)"
  assert_eq "default-x" "$(hk_conf evil default-x)" "lowercase keys are not read"
  assert_eq "bad-default" "$(hk_conf 'LIMIT_HANDOFF_X;y' bad-default)" "invalid key names fall back to the default"
}

test_trusted_keys_ignore_project_file() {
  load_common
  unset LIMIT_HANDOFF_CLIPBOARD LIMIT_HANDOFF_NOTIFY
  local proj="$TL_TMP/proj3"
  mkdir -p "$proj/.claude"
  HK_PROJECT_DIR="$proj"
  printf 'LIMIT_HANDOFF_CLIPBOARD=curl\nLIMIT_HANDOFF_NOTIFY=on\n' > "$proj/.claude/limit-handoff.conf"
  assert_eq "auto" "$(hk_conf_trusted LIMIT_HANDOFF_CLIPBOARD auto)" "a cloned repo must not pick the clipboard command"
  assert_eq "auto" "$(hk_conf_trusted LIMIT_HANDOFF_NOTIFY auto)"
  assert_eq "off" "$(LIMIT_HANDOFF_CLIPBOARD=off hk_conf_trusted LIMIT_HANDOFF_CLIPBOARD auto)"
}

test_bad_file_name_in_config_falls_back() {
  load_common
  local proj="$TL_TMP/proj4"
  mkdir -p "$proj/.claude"
  HK_PROJECT_DIR="$proj"
  # The project file is not read for file names (batch C #29), so the bad values come from the
  # environment, which is the user's own setting.
  export LIMIT_HANDOFF_FILE='../../etc/passwd' LIMIT_HANDOFF_RECOVER_DIR='/tmp/elsewhere'
  assert_eq "HANDOFF.md" "$(hk_handoff_name)" "traversal is rejected, default is used"
  assert_eq ".handoff" "$(hk_recover_dir_name)" "absolute path is rejected, default is used"
  assert_file_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "not a safe path" "rejection is logged"
}

test_file_age_minutes() {
  load_common
  local f="$TL_TMP/age.md"
  : > "$f"
  assert_eq "0" "$(hk_file_age_min "$f")" "fresh file is 0 minutes old"
  touch -t 202001010000 "$f"
  local age; age="$(hk_file_age_min "$f")"
  [ "$age" -gt 100000 ] || fail "old file should be many minutes old, got $age"
  assert_eq "-1" "$(hk_file_age_min "$TL_TMP/missing.md")" "missing file gives -1"
}

test_atomic_write_keeps_old_content_on_failure() {
  load_common
  local f="$TL_TMP/keep/file.md"
  mkdir -p "$TL_TMP/keep"
  printf 'old\n' > "$f"
  chmod 555 "$TL_TMP/keep"
  if printf 'new\n' | hk_atomic_write "$f"; then
    chmod 755 "$TL_TMP/keep"
    fail "write into a read-only folder should fail"
  fi
  chmod 755 "$TL_TMP/keep"
  assert_eq "old" "$(cat "$f")" "old file must be intact"
  printf 'fresh\n' | hk_atomic_write "$TL_TMP/keep/new.md" || fail "normal atomic write failed"
  assert_eq "fresh" "$(cat "$TL_TMP/keep/new.md")"
  assert_file_missing "$TL_TMP/keep/new.md.tmp.$$" "no temp file left behind"
}

test_cutoff_block_shape() {
  load_common
  local b; b="$(hk_cutoff_block "sess1" "2026-10-29T10:00:00Z" "rate_limit" "usage limit reached" "2026-10-29 10:00" ".handoff/r.md")"
  assert_contains "$b" '<!-- limit-handoff:cutoff session="sess1" at="2026-10-29T10:00:00Z" error="rate_limit" status="unresolved" -->'
  assert_contains "$b" "(usage limit reached) at 2026-10-29 10:00."
  assert_contains "$b" 'Recovered context: `.handoff/r.md`'
  assert_contains "$b" '<!-- /limit-handoff:cutoff -->'
}

test_upsert_replaces_same_session_in_place() {
  load_common
  local f="$TL_TMP/H.md"
  printf '%s\n' '# Title' '' '## Next steps' '1. Do it' '' '<!-- limit-handoff:cutoff session="A" at="OLD" error="rate_limit" status="unresolved" -->' 'old text' '<!-- /limit-handoff:cutoff -->' '' 'Trailing user note' > "$f"
  hk_upsert_cutoff "$f" "A" "$(hk_cutoff_block A NEW rate_limit "usage limit reached" "now" "r.md")" || fail "upsert failed"
  assert_file_not_contains "$f" 'at="OLD"' "old timestamp must be gone"
  assert_count "$f" 'session="A"' 1 "still one block for session A"
  assert_file_contains "$f" 'at="NEW"'
  assert_file_contains "$f" "Trailing user note" "user text after the block must stay"
  assert_file_contains "$f" "# Title" "user text before the block must stay"
}

test_upsert_keeps_other_sessions_and_appends_new_ones() {
  load_common
  local f="$TL_TMP/H2.md"
  printf '%s\n' '# T' '<!-- limit-handoff:cutoff session="A" at="t1" error="rate_limit" status="unresolved" -->' 'a' '<!-- /limit-handoff:cutoff -->' > "$f"
  hk_upsert_cutoff "$f" "B" "$(hk_cutoff_block B t2 rate_limit "usage limit reached" "now" "r.md")" || fail "append failed"
  assert_count "$f" 'session="A"' 1
  assert_count "$f" 'session="B"' 1
  hk_upsert_cutoff "$f" "B" "$(hk_cutoff_block B t3 rate_limit "usage limit reached" "now" "r.md")" || fail "second upsert failed"
  assert_count "$f" 'session="B"' 1 "same session must not add a second block"
  assert_file_contains "$f" 'at="t3"'
}

test_upsert_does_not_drop_unclosed_block() {
  load_common
  local f="$TL_TMP/H3.md"
  printf '%s\n' '# T' '<!-- limit-handoff:cutoff session="A" at="t1" error="rate_limit" status="unresolved" -->' 'user text inside an unclosed block' > "$f"
  hk_upsert_cutoff "$f" "A" "$(hk_cutoff_block A t2 rate_limit "usage limit reached" "now" "r.md")" || fail "upsert failed"
  assert_file_contains "$f" "user text inside an unclosed block" "nothing may be dropped"
}

test_unresolved_detection_and_newest_block() {
  load_common
  local f="$TL_TMP/H4.md"
  printf '%s\n' '# T' \
    "$(hk_cutoff_block old1 t1 rate_limit "usage limit reached" "2026-01-01 10:00" "r1.md")" \
    "$(hk_cutoff_block new2 t2 billing_error "billing/credit limit" "2026-02-02 11:00" "r2.md")" > "$f"
  hk_has_unresolved_cutoff "$f" || fail "unresolved block not detected"
  local b; b="$(hk_last_unresolved_block "$f")"
  assert_contains "$b" 'session="new2"'
  assert_eq "2026-02-02 11:00" "$(hk_block_at_human "$b")"
  assert_eq "r2.md" "$(hk_block_recovered "$b")"
  assert_eq "billing_error" "$(hk_block_error "$b")"
  sed 's/status="unresolved"/status="resolved"/' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  if hk_has_unresolved_cutoff "$f"; then fail "resolved blocks must not count"; fi
}

test_render_recovered_markdown_sections() {
  load_common
  local j md
  j="$(hk_recover_json "$(tl_fixture basic.jsonl)" 5)"
  md="$(hk_render_recovered "$j" "sess" "rate_limit" "usage limit reached" "/t.jsonl" "")"
  for h in "# Recovered context" "## Last things you asked" "## Task list at cut-off" "## Files touched (most recent first)" "## Last commands" "## Last assistant message"; do
    assert_contains "$md" "$h"
  done
  assert_contains "$md" "- [x] Make login form"
  assert_contains "$md" "- [~] Add password check"
  assert_contains "$md" "- [ ] Write tests"
  md="$(hk_render_recovered "" "sess" "x" "y" "" "No transcript here")"
  assert_contains "$md" "No transcript here"
  assert_contains "$md" "No user messages were found"
}

test_render_recovered_keeps_hostile_text_literal() {
  load_common
  local j md
  j="$(hk_recover_json "$(tl_fixture security.jsonl)" 5)"
  md="$(hk_render_recovered "$j" "sess" "rate_limit" "usage limit reached" "/t.jsonl" "")"
  assert_contains "$md" '$(touch pwned-by-transcript)'
  assert_contains "$md" '{{PROJECT_DIR}}'
  assert_contains "$md" '100%s done'
  assert_file_missing "$TL_TMP/pwned-by-transcript"
}

test_derive_next_step_order() {
  load_common
  local j
  j="$(hk_recover_json "$(tl_fixture basic.jsonl)" 5)"
  assert_eq "Add password check" "$(hk_derive_next_step "$j")" "in progress comes before pending"
  assert_eq "" "$(hk_derive_next_step '{}')"
  assert_eq "" "$(hk_derive_next_step '')"
}

run_tests
