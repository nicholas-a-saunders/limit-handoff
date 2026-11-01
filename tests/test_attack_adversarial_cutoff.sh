#!/bin/bash
# Adversarial tests: inputs chosen to break the kit.
# Area: editing HANDOFF.md, simultaneous sessions, and where files may be written.
# Rules come from docs/SPEC.md.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# adv_stop project transcript session error: runs the StopFailure hook.
adv_stop() {
  local payload
  payload="$(tl_payload_stop "$3" "$2" "$1" "$4")"
  tl_run "$TL_HOOK_STOP" "$payload"
}

# adv_two_hooks project sessionA sessionB: starts two StopFailure hooks at the same moment.
adv_two_hooks() {
  local pa pb
  printf '%s' "$(tl_payload_stop "$2" "$TL_FIX/basic.jsonl" "$1" rate_limit)" | /bin/bash "$TL_HOOK_STOP" >/dev/null 2>&1 &
  pa=$!
  printf '%s' "$(tl_payload_stop "$3" "$TL_FIX/basic.jsonl" "$1" billing_error)" | /bin/bash "$TL_HOOK_STOP" >/dev/null 2>&1 &
  pb=$!
  wait "$pa"
  wait "$pb"
}

# ---------------------------------------------------------------------------
# Editing HANDOFF.md. SPEC "stop-failure step 3": only this session's block is replaced;
# blocks from other sessions stay. The user's own text must never be lost.
# ---------------------------------------------------------------------------

test_unclosed_block_for_same_session_keeps_user_notes_and_other_blocks() {
  local p hf
  p="$CLAUDE_PROJECT_DIR"
  hf="$p/HANDOFF.md"
  cat > "$hf" <<'EOF'
# Project handoff

## Goal
Keep the user's own notes safe.

<!-- limit-handoff:cutoff session="sessA" at="2026-10-28T10:00:00Z" error="rate_limit" status="unresolved" -->
> ⚠️ **Session cut off** (usage limit reached) at 2026-10-28 10:00. Old text.

## My own notes
Important line that must survive.

<!-- limit-handoff:cutoff session="sessB" at="2026-10-28T11:00:00Z" error="billing_error" status="unresolved" -->
> ⚠️ **Session cut off** (billing/credit limit) at 2026-10-28 11:00. Other session text.
<!-- /limit-handoff:cutoff -->
EOF
  adv_stop "$p" "$TL_FIX/basic.jsonl" "sessA" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$hf" "My own notes" "the user's section heading was deleted"
  assert_file_contains "$hf" "Important line that must survive" "the user's text was deleted"
  assert_file_contains "$hf" 'session="sessB"' "another session's block header was deleted"
  assert_file_contains "$hf" "Other session text." "another session's block text was deleted"
  assert_file_contains "$hf" 'Recovered context: `.handoff/recovered-' "the new cut-off block for sessA was not written"
}

test_same_session_block_with_end_marker_is_replaced_not_duplicated() {
  local p hf
  p="$CLAUDE_PROJECT_DIR"
  hf="$p/HANDOFF.md"
  printf '%s\n' '# Handoff' '' '## Next steps' '1. Keep going' > "$hf"
  adv_stop "$p" "$TL_FIX/basic.jsonl" "sess-replace" "rate_limit"
  adv_stop "$p" "$TL_FIX/basic.jsonl" "sess-replace" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_eq "1" "$(grep -c 'session="sess-replace"' "$hf")" "same session must keep exactly one block"
  assert_file_contains "$hf" "1. Keep going" "user content must survive a second run"
}

# ---------------------------------------------------------------------------
# Simultaneous sessions. A usage limit hits every open chat at once, so two hooks
# can edit HANDOFF.md at the same moment. SPEC "Tests": different session -> two blocks.
# ---------------------------------------------------------------------------

test_two_sessions_cut_off_at_the_same_moment_keep_both_blocks() {
  local p i a b lost=0
  p="$CLAUDE_PROJECT_DIR"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    printf '%s\n' '# Shared handoff' > "$p/HANDOFF.md"
    adv_two_hooks "$p" "race-a-$i" "race-b-$i"
    a="$(grep -c "session=\"race-a-$i\"" "$p/HANDOFF.md")"
    b="$(grep -c "session=\"race-b-$i\"" "$p/HANDOFF.md")"
    if [ "$a" != 1 ] || [ "$b" != 1 ]; then
      lost=$((lost + 1))
      echo "    round $i: block counts a=$a b=$b" >&2
    fi
  done
  assert_eq "0" "$lost" "simultaneous cut-offs lost a session block in $lost of 10 rounds (two read-modify-write runs on one file)"
}

test_two_new_sessions_creating_handoff_keep_both_blocks() {
  local p i n lost=0
  p="$CLAUDE_PROJECT_DIR"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    rm -f "$p/HANDOFF.md"
    adv_two_hooks "$p" "create-a-$i" "create-b-$i"
    n="$(grep -c 'limit-handoff:cutoff session=' "$p/HANDOFF.md" 2>/dev/null)"
    if [ "${n:-0}" != 2 ]; then
      lost=$((lost + 1))
      echo "    round $i: found ${n:-0} block(s)" >&2
    fi
  done
  assert_eq "0" "$lost" "two sessions creating HANDOFF.md at once left only one block in $lost of 10 rounds"
}

# ---------------------------------------------------------------------------
# Where files may be written. SPEC "Hard constraints": never write outside the project dir
# except the kit's state dir.
# ---------------------------------------------------------------------------

test_symlinked_recovery_folder_cannot_send_files_outside_the_project() {
  local p out n
  p="$CLAUDE_PROJECT_DIR"
  out="$TL_TMP/outside-target"
  mkdir -p "$out"
  ln -s "$out" "$p/.handoff"
  adv_stop "$p" "$TL_FIX/basic.jsonl" "link-sess" "rate_limit"
  assert_exit 0 "$TL_RC"
  n="$(ls -A "$out" | wc -l | tr -d ' ')"
  assert_eq "0" "$n" "a symlinked .handoff folder sent recovered files outside the project (SPEC: never write outside the project dir)"
}

test_handoff_file_name_escape_variants_are_refused() {
  local v i p
  i=0
  for v in '../escape.md' '..' '.' 'a/../../escape.md' "TL_ABS" '~/escape.md' 'x/./y.md' '/abs-escape.md'; do
    i=$((i + 1))
    p="$TL_TMP/case$i/project"
    mkdir -p "$p"
    if [ "$v" = "TL_ABS" ]; then v="$TL_TMP/abs-target.md"; fi
    export LIMIT_HANDOFF_FILE="$v"
    export CLAUDE_PROJECT_DIR="$p"
    adv_stop "$p" "$TL_FIX/basic.jsonl" "esc-$i" "rate_limit"
    unset LIMIT_HANDOFF_FILE
    export CLAUDE_PROJECT_DIR="$TL_TMP/project"
    assert_exit 0 "$TL_RC" "hook must exit 0 for LIMIT_HANDOFF_FILE=$v"
    assert_file_exists "$p/HANDOFF.md" "unsafe LIMIT_HANDOFF_FILE=$v must fall back to HANDOFF.md inside the project"
    assert_file_missing "$TL_TMP/abs-target.md" "LIMIT_HANDOFF_FILE=$v wrote an absolute path"
    assert_file_missing "$TL_TMP/case$i/escape.md" "LIMIT_HANDOFF_FILE=$v wrote outside the project"
    assert_file_missing "$TL_TMP/case$i/x/y.md" "LIMIT_HANDOFF_FILE=$v wrote a nested path"
    assert_file_missing "$HOME/escape.md" "LIMIT_HANDOFF_FILE=$v wrote into HOME"
    assert_file_missing "$TL_TMP/abs-escape.md" "LIMIT_HANDOFF_FILE=$v wrote to the root path"
  done
}

test_handoff_file_with_trailing_slash_is_refused_not_silently_dropped() {
  local p="$CLAUDE_PROJECT_DIR"
  export LIMIT_HANDOFF_FILE='docs/'
  adv_stop "$p" "$TL_FIX/basic.jsonl" "slash-sess" "rate_limit"
  unset LIMIT_HANDOFF_FILE
  assert_exit 0 "$TL_RC"
  assert_file_exists "$p/HANDOFF.md" "LIMIT_HANDOFF_FILE=docs/ (a folder name) must fall back to HANDOFF.md (minor: no handoff file was written)"
}

test_prompt_file_setting_cannot_point_at_claude_settings() {
  local p="$CLAUDE_PROJECT_DIR" before
  mkdir -p "$p/.claude"
  printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}' > "$p/.claude/settings.json"
  printf '%s\n' 'LIMIT_HANDOFF_PROMPT_FILE=.claude/settings.json' > "$p/.claude/limit-handoff.conf"
  before="$TL_TMP/settings.before"
  cp "$p/.claude/settings.json" "$before"
  adv_stop "$p" "$TL_FIX/basic.jsonl" "cfg-sess" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_same_file "$before" "$p/.claude/settings.json" "a project config overwrote .claude/settings.json with the paste prompt (minor: keep Claude's own files out of reach)"
}

test_symlinked_handoff_md_keeps_its_link_after_a_cut_off() {
  local p="$CLAUDE_PROJECT_DIR" target
  target="$TL_TMP/dotfiles/HANDOFF.md"
  mkdir -p "$TL_TMP/dotfiles"
  printf '%s\n' '# Shared notes' > "$target"
  ln -s "$target" "$p/HANDOFF.md"
  # A link to a file outside the project is only followed when the user's own settings allow it (batch C #27).
  export LIMIT_HANDOFF_FOLLOW_LINKS=1
  adv_stop "$p" "$TL_FIX/basic.jsonl" "symlink-hf" "rate_limit"
  assert_exit 0 "$TL_RC"
  if [ ! -L "$p/HANDOFF.md" ]; then
    fail "HANDOFF.md was a symlink and was replaced by a plain file, so the real notes file got no cut-off block (minor)"
  fi
  assert_file_contains "$target" 'session="symlink-hf"' "the file the link points to must get the cut-off block (minor)"
}

test_handoff_md_that_is_a_folder_still_exits_zero_and_writes_paste_prompt() {
  local p="$CLAUDE_PROJECT_DIR"
  mkdir -p "$p/HANDOFF.md"
  adv_stop "$p" "$TL_FIX/basic.jsonl" "dirhf" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$p/PASTE-PROMPT.txt" "the paste prompt must still be written"
}

run_tests
