#!/bin/bash
# Regression tests for the code review fixes, second set. Batch A is ShellCheck and dead code.
#
# Each fix has at least one test here that fails before the fix and passes after it.
# ShellCheck itself is not run by the suite (it is not installed here). These tests check the
# text that ShellCheck reads, so they catch a missing directive or a removed variable.
#   A1 Each dynamic "source lib/common.sh" line has its directive directly above it.
#   A2 The repo root .shellcheckrc turns on external sources and sets the source path.
#   A3 HK_EVENT is gone from the code and from docs/SPEC.md (nothing read it).
#   A4 hk_read_input still fills every field after the assignments were split (guard).
#   A5 The shared HK_* assignments are one per line, each unread one has a directive.
#   A6 HK_VERSION has a directive (bin/limit-handoff reads it).
#   A7 hk_catchup reads its list with a read loop, not an unquoted command substitution.
#   A8 simulate declares no unused clip or notify locals.
#   A9 CONTRIBUTING.md explains the .shellcheckrc settings.
#   B1 The tests avoid BSD-only sed -i and use a GNU date fallback (ubuntu CI).
#   E1-E8 Batch E: no value runs in the fallback text, a failed folder write falls back to the state
#     folder, no copy names no file, the reminders never name .handoff without a path, the atomic
#     write is silent, real paths resolve missing folders, int config, and the git Changes line.
#   C1-C52 Batch C: untrusted repository content. Links outside the project are not written or read
#     unless the user allows it; project config cannot choose file names, keep counts or read sizes;
#     no * rule in a folder of the user's own; control characters and backticks out of file paths
#     and tasks; next step is one clean short line; tokens are redacted; no recent prompts in the
#     created HANDOFF.md; catch-up needs a cwd; only the last bytes of a transcript are read; a long
#     run of spaces is fast; a value over 100 KB is cut and says so.
#   D1-D8 Batch D: started and done markers (a failed write is retried), catch-up retries an unfinished
#     start, skips a running one, leaves git out, runs the oldest chat last; the newest unresolved
#     block is the latest time; prune keeps named files; the block time is the limit line's time;
#     a typed prompt after a limit clears it.
#   F1-F12 Batch F: install and uninstall need jq; simulate checks its own files and codes; reminders
#     use the configured file name; install says what it removed and checks sibling settings; prompt
#     says when the clipboard is off; doctor and status handle bad and blank settings; resolve and the
#     error code list say what to do.
#   B2 tl_file_mode reads permission bits on both systems; no test calls BSD stat directly.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---------------------------------------------------------------------------
# A1. Every dynamic source line has the ShellCheck directive directly above it.
# ---------------------------------------------------------------------------

test_a1_shellcheck_source_line_has_directive_directly_above_it() {
  local f pat n above total=0
  for f in hooks/stop-failure.sh hooks/session-start.sh hooks/prompt-submit.sh hooks/pre-compact.sh bin/limit-handoff; do
    case "$f" in
      bin/*) pat='. "$HK_BIN_DIR/../lib/common.sh"' ;;
      *) pat='. "$HK_HOOK_LIB/common.sh"' ;;
    esac
    n="$(awk -v t="$pat" 'index($0, t) == 1 { n++ } END { print n + 0 }' "$TL_ROOT/$f")"
    assert_eq 1 "$n" "expected one dynamic source line in $f"
    above="$(awk -v t="$pat" 'index($0, t) == 1 { print prev; exit } { prev = $0 }' "$TL_ROOT/$f")"
    assert_eq "# shellcheck source=lib/common.sh" "$above" "no ShellCheck source directive directly above the source line in $f (batch A #2/#3/#38)"
    total=$((total + n))
  done
  assert_eq 5 "$total" "five dynamic source lines in all"
}

# ---------------------------------------------------------------------------
# A2. The repo root .shellcheckrc exists and sets the two options the directive needs.
# ---------------------------------------------------------------------------

test_a2_shellcheckrc_turns_on_external_sources_and_sets_source_path() {
  local rc="$TL_ROOT/.shellcheckrc"
  assert_file_exists "$rc" ".shellcheckrc is missing at the repo root (batch A #2/#3/#38)"
  assert_file_contains "$rc" "external-sources=true" "external-sources is not on in .shellcheckrc"
  assert_file_contains "$rc" "source-path=SCRIPTDIR/.." "source-path is not set in .shellcheckrc"
}

# ---------------------------------------------------------------------------
# A3. HK_EVENT is removed everywhere. Nothing read it, so it was dead code.
# ---------------------------------------------------------------------------

test_a3_hk_event_is_gone_from_code_and_spec() {
  local f
  for f in lib/common.sh hooks/stop-failure.sh hooks/session-start.sh hooks/prompt-submit.sh hooks/pre-compact.sh bin/limit-handoff docs/SPEC.md; do
    assert_file_not_contains "$TL_ROOT/$f" "HK_EVENT" "HK_EVENT is still in $f (batch A #4/#41)"
  done
}

# ---------------------------------------------------------------------------
# A4. Guard: hk_read_input still fills every field after the split.
# ---------------------------------------------------------------------------

test_a4_hk_read_input_still_fills_every_field() {
  local json out
  json='{"session_id":"sess-01","cwd":"/tmp/proj","transcript_path":"/tmp/t.jsonl","source":"resume","error":"rate_limit","last_assistant_message":"all done"}'
  out="$(printf '%s' "$json" | { . "$TL_ROOT/lib/common.sh"; hk_read_input
    printf '%s|%s|%s|%s|%s|%s' "$HK_CWD" "$HK_SESSION" "$HK_TRANSCRIPT" "$HK_ERROR" "$HK_SOURCE" "$HK_LAST_MSG"; })"
  assert_eq "/tmp/proj|sess-01|/tmp/t.jsonl|rate_limit|resume|all done" "$out" "hk_read_input must fill each field after the split (batch A #4/#41)"
}

# ---------------------------------------------------------------------------
# A5. The shared HK_* assignments: one per line, and each one that no line of
#     lib/common.sh reads has a directive directly above it.
# ---------------------------------------------------------------------------

test_a5_shared_variables_are_one_per_line_with_directives() {
  local f="$TL_ROOT/lib/common.sh" v packed above hits
  packed="$(grep -c -E '^[[:space:]]*HK_[A-Z_]+=.*; *HK_' "$f")"
  assert_eq 0 "${packed:-0}" "a line in lib/common.sh packs several HK_ assignments with ; (batch A #4/#41)"
  for v in HK_SESSION HK_ERROR HK_LAST_MSG; do
    hits="$(awk -v t="$v=\"\"" '$0 == t { n++ } END { print n + 0 }' "$f")"
    assert_eq 1 "$hits" "expected one top-level $v line in lib/common.sh"
    above="$(awk -v t="$v=\"\"" '$0 == t { print prev; exit } { prev = $0 }' "$f")"
    assert_eq "# shellcheck disable=SC2034" "$above" "$v has no SC2034 directive directly above it (batch A #4/#41)"
  done
  above="$(awk 'index($0, "hk_read_input() {") == 1 { print prev; exit } { prev = $0 }' "$f")"
  assert_eq "# shellcheck disable=SC2034" "$above" "hk_read_input has no SC2034 directive directly above it (batch A #4/#41)"
}

# ---------------------------------------------------------------------------
# A6. HK_VERSION has a directive, because bin/limit-handoff reads it.
# ---------------------------------------------------------------------------

test_a6_hk_version_has_a_shellcheck_directive() {
  local above
  above="$(awk 'index($0, "HK_VERSION=") == 1 { print prev; exit } { prev = $0 }' "$TL_ROOT/lib/common.sh")"
  assert_eq "# shellcheck disable=SC2034" "$above" "HK_VERSION has no SC2034 directive directly above it (batch A #5)"
}

# ---------------------------------------------------------------------------
# A7. hk_catchup reads its list with a read loop. No unquoted command substitution (SC2046).
# ---------------------------------------------------------------------------

test_a7_catchup_reads_the_listing_without_word_splitting() {
  assert_file_not_contains "$TL_ROOT/lib/common.sh" 'set -- $(' "hk_catchup still splits its list with an unquoted command substitution (batch A #6/#39)"
  assert_file_contains "$TL_ROOT/lib/common.sh" 'while read -r m sid; do' "hk_catchup does not read its list with a read loop (batch A #6/#39)"
  assert_file_contains "$TL_ROOT/lib/common.sh" 'done <<<"$listing"' "hk_catchup must feed the list in with a here-string, not a pipe (batch A #6/#39)"
}

# ---------------------------------------------------------------------------
# A8/A9. Batch A follow-up: the simulate locals no longer name unused clip/notify, and
#     CONTRIBUTING explains the .shellcheckrc settings the ShellCheck command relies on.
# ---------------------------------------------------------------------------

test_a8_simulate_has_no_unused_clip_or_notify_locals() {
  local line
  line="$(grep -n '^cmd_simulate()' "$TL_ROOT/bin/limit-handoff" | cut -d: -f1)"
  [ -n "$line" ] || fail "cmd_simulate not found in bin/limit-handoff"
  line="$(awk -v s="$line" 'NR > s && /local /{ print; exit }' "$TL_ROOT/bin/limit-handoff")"
  case "$line" in
    *" clip "*|*" notify "*) fail "simulate still declares unused clip or notify locals: $line" ;;
  esac
}

test_a9_contributing_explains_shellcheckrc() {
  assert_file_contains "$TL_ROOT/CONTRIBUTING.md" ".shellcheckrc" "CONTRIBUTING.md does not mention .shellcheckrc (batch A nit)"
}

# ---------------------------------------------------------------------------
# B1-B3. Batch B: the tests run on both macOS (BSD tools) and Ubuntu (GNU tools).
# ---------------------------------------------------------------------------

test_b1_no_test_uses_bsd_only_sed_in_place() {
  local f
  for f in "$TL_ROOT"/tests/test_*.sh; do
    # This file names the patterns it looks for, so it is not scanned.
    [ "$(basename "$f")" = "test_review_fixes2.sh" ] && continue
    assert_file_not_contains "$f" "sed -i ''" "$(basename "$f") uses BSD-only sed -i '' (batch B #36/#42)"
  done
}

test_b1_catchup_window_test_works_with_bsd_and_gnu_date() {
  # The fallback must be there, and the test must fail loudly when neither date form works.
  assert_file_contains "$TL_ROOT/tests/test_catchup.sh" "date -d '-3 hours'" "no GNU date fallback in the catch-up window test (batch B #35)"
  assert_file_contains "$TL_ROOT/tests/test_catchup.sh" '[ -n "$old" ] || fail' "the catch-up window test does not check its time value (batch B #35)"
}

test_b2_tl_file_mode_reads_permission_bits() {
  local f="$TL_TMP/mode-check.txt"
  printf 'x\n' > "$f"
  chmod 600 "$f"
  assert_eq "600" "$(tl_file_mode "$f")" "tl_file_mode must print 600 for a 600 file (batch B #37)"
  chmod 644 "$f"
  assert_eq "644" "$(tl_file_mode "$f")" "tl_file_mode must print 644 for a 644 file (batch B #37)"
}

test_b2_no_test_calls_stat_f_directly() {
  local f
  for f in "$TL_ROOT"/tests/test_*.sh; do
    [ "$(basename "$f")" = "test_review_fixes2.sh" ] && continue
    assert_file_not_contains "$f" "stat -f %Lp" "$(basename "$f") calls BSD stat directly; use tl_file_mode (batch B #37)"
  done
  assert_file_not_contains "$TL_ROOT/tests/test_attack_adversarial_hooks.sh" "adv_stat_mode" "the unused adv_stat_mode helper is still there (batch B #37)"
}

# ---------------------------------------------------------------------------
# E1-E8. Batch E: recovered-file fallbacks, paths and numbers.
# ---------------------------------------------------------------------------

# load_hk: loads lib/common.sh into the test shell, with the project folder set.
load_hk() {
  . "$TL_ROOT/lib/common.sh"
  HK_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
}

test_e1_recovered_fallback_text_never_runs_its_values() {
  # Without jq the recovered file uses the plain-text fallback. Its values must be shown as text.
  load_hk
  tl_use_nojq
  local rec
  rec="$(hk_write_recovered "" 'abc12345`touch CANARY_E1`' "rate_limit" "usage limit reached" 'x $(touch CANARY_E2) y' "" "")" \
    || fail "the fallback recovered file was not written"
  assert_file_missing "$TL_TMP/CANARY_E1" "a backtick value in the session id was run as a command (batch E #1)"
  assert_file_missing "$TL_TMP/CANARY_E2" "a \$( ) value in the transcript path was run as a command (batch E #1)"
  assert_file_contains "$CLAUDE_PROJECT_DIR/$rec" 'Session: abc12345`touch CANARY_E1`' "the session id must be kept as plain text"
  assert_file_contains "$CLAUDE_PROJECT_DIR/$rec" 'Transcript: x $(touch CANARY_E2) y' "the transcript text must be kept as plain text"
}

test_e2_recovered_file_falls_back_to_state_folder_when_project_write_fails() {
  load_hk
  printf 'not a folder\n' > "$CLAUDE_PROJECT_DIR/.handoff"
  local rec
  rec="$(hk_write_recovered "" "sess2222" "rate_limit" "usage limit reached" "" "" "")" \
    || fail "no recovered file was written at all (batch E #11/#60)"
  case "$rec" in
    /*) : ;;
    *) fail "the file should be in the state folder (absolute path), got: $rec" ;;
  esac
  assert_file_exists "$rec" "the state-folder copy is missing (batch E #11/#60)"
  assert_file_missing "$CLAUDE_PROJECT_DIR/.handoff/LATEST.md" "nothing may be written in the project after the folder failed"
}

test_e3_no_copy_at_all_names_no_file_and_no_placeholder() {
  # Both the project folder and the state folder fail. The block and the paste prompt must say so.
  load_hk
  printf 'not a folder\n' > "$CLAUDE_PROJECT_DIR/.handoff"
  mkdir -p "$TL_TMP/state"
  printf 'blocks the folder\n' > "$TL_TMP/state/recovered"
  if hk_write_recovered "" "sess3333" "rate_limit" "usage limit reached" "" "" "" >/dev/null 2>&1; then
    fail "hk_write_recovered must report failure when no copy can be written"
  fi
  mkdir -p "$CLAUDE_PROJECT_DIR"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "sess3333" "$(tl_fixture basic.jsonl)" "$CLAUDE_PROJECT_DIR" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$CLAUDE_PROJECT_DIR/HANDOFF.md" "Recovered context: not written (see the log)" "the block must say no recovered file was written (batch E #11/#60)"
  assert_file_not_contains "$CLAUDE_PROJECT_DIR/HANDOFF.md" "recovered-unavailable" "the placeholder file name must be gone (batch E #11/#60)"
  assert_file_contains "$CLAUDE_PROJECT_DIR/PASTE-PROMPT.txt" "There is no recovered file for this stop. Use HANDOFF.md." "the paste prompt must say there is no recovered file"
  assert_file_not_contains "$CLAUDE_PROJECT_DIR/PASTE-PROMPT.txt" "recovered-" "the paste prompt must not name a recovered file"
  assert_file_not_contains "$CLAUDE_PROJECT_DIR/PASTE-PROMPT.txt" "unavailable" "the paste prompt must not name the placeholder"
}

test_e4_reminder_without_known_path_never_names_the_handoff_folder() {
  # The cut-off block has no usable path (here: a path that fails the strict check).
  local p="$CLAUDE_PROJECT_DIR" sid="sess4444"
  printf '%s\n' '# H' '' '<!-- limit-handoff:cutoff session="sess4444" at="2026-10-29T10:00:00Z" error="rate_limit" status="unresolved" -->' \
    '> ⚠️ **Session cut off** (usage limit reached) at 2026-10-29 10:00. The steps above may be slightly behind.' \
    '> Check the files for a half-finished step before continuing. Recovered context: `../../evil run`' \
    '<!-- /limit-handoff:cutoff -->' > "$p/HANDOFF.md"
  tl_run "$TL_HOOK_SESSION" "$(tl_payload_plain SessionStart "$sid" "$p" startup)"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "the recovered context file named in the cut-off block" "the fallback wording must not name a folder (batch E #16)"
  assert_not_contains "$TL_OUT" ".handoff" "the reminder must never name .handoff when the path is unknown (batch E #16)"
}

test_e4_reminder_for_a_block_without_a_recovered_file_skips_the_file_part() {
  local p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# H' '' '<!-- limit-handoff:cutoff session="sess4445" at="2026-10-29T10:00:00Z" error="rate_limit" status="unresolved" -->' \
    '> ⚠️ **Session cut off** (usage limit reached) at 2026-10-29 10:00. The steps above may be slightly behind.' \
    '> Check the files for a half-finished step before continuing. Recovered context: not written (see the log)' \
    '<!-- /limit-handoff:cutoff -->' > "$p/HANDOFF.md"
  tl_run "$TL_HOOK_PROMPT" "$(tl_payload_plain UserPromptSubmit "sess4445" "$p" "")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "Read HANDOFF.md before anything else" "no recovered file means only HANDOFF.md is read (batch E #11)"
  assert_not_contains "$TL_OUT" "recovered context file" "no recovered-file part when none was written (batch E #11)"
}

test_e5_atomic_write_into_a_read_only_folder_prints_nothing() {
  # A folder that cannot take a new file. The failed open of the temp file must not reach stderr.
  load_hk
  local d="$TL_TMP/ro"
  mkdir -p "$d"
  chmod 555 "$d"
  printf 'x\n' | hk_atomic_write "$d/file.md" 2>"$TL_TMP/ro.err"
  local rc=$?
  chmod 755 "$d"
  if [ "$rc" -eq 0 ]; then fail "a write into a read-only folder must fail"; fi
  assert_eq "" "$(cat "$TL_TMP/ro.err")" "a failed temp-file open must not print an error (batch E #26)"
}

test_e6_real_path_resolves_folders_that_do_not_exist_yet() {
  # The project is reached through a link. The .handoff folder does not exist yet.
  load_hk
  mkdir -p "$TL_TMP/real/proj"
  ln -s "$TL_TMP/real" "$TL_TMP/alias"
  HK_PROJECT_DIR="$TL_TMP/alias/proj"
  hk_inside_project "$HK_PROJECT_DIR/.handoff/new.md" \
    || fail "a file in a folder that does not exist yet, under a linked project, must count as inside (batch E #65)"
  local real
  real="$(hk_real_path "$HK_PROJECT_DIR/.handoff/new.md")"
  case "$real" in
    "$(CDPATH='' cd -P "$TL_TMP/real/proj" && pwd -P)/.handoff/new.md") : ;;
    *) fail "the real path must be the physical one, got: $real (batch E #65)" ;;
  esac
}

test_e6_dangling_link_on_the_way_is_not_inside_the_project() {
  load_hk
  mkdir -p "$TL_TMP/proj2"
  ln -s "$TL_TMP/nowhere-at-all" "$TL_TMP/proj2/dangle"
  HK_PROJECT_DIR="$TL_TMP/proj2"
  if hk_inside_project "$TL_TMP/proj2/dangle/sub/x.md"; then
    fail "a dangling link on the way must not count as inside the project (batch E #65)"
  fi
  assert_eq "" "$(hk_real_path "$TL_TMP/proj2/dangle/sub/x.md")" "a dangling link prints no path (batch E #65)"
}

test_e7_int_config_strips_leading_zeros_and_rejects_long_numbers() {
  load_hk
  LIMIT_HANDOFF_ZTEST=08; export LIMIT_HANDOFF_ZTEST
  assert_eq "8" "$(hk_int_conf LIMIT_HANDOFF_ZTEST 30)" "08 must read as 8, not as an invalid octal number (batch E #49)"
  LIMIT_HANDOFF_ZTEST=000; export LIMIT_HANDOFF_ZTEST
  assert_eq "0" "$(hk_int_conf LIMIT_HANDOFF_ZTEST 30)" "000 must read as 0 (batch E #49)"
  LIMIT_HANDOFF_ZTEST=0000000012; export LIMIT_HANDOFF_ZTEST
  assert_eq "12" "$(hk_int_conf LIMIT_HANDOFF_ZTEST 30)" "leading zeros must go, then the number is kept (batch E #49)"
  LIMIT_HANDOFF_ZTEST=1234567890; export LIMIT_HANDOFF_ZTEST
  assert_eq "30" "$(hk_int_conf LIMIT_HANDOFF_ZTEST 30)" "more than 9 digits uses the default (batch E #49)"
  LIMIT_HANDOFF_ZTEST=00000000000000042; export LIMIT_HANDOFF_ZTEST
  assert_eq "42" "$(hk_int_conf LIMIT_HANDOFF_ZTEST 30)" "a long run of zeros in front of a short number is fine (batch E #49)"
  LIMIT_HANDOFF_ZTEST=12x; export LIMIT_HANDOFF_ZTEST
  assert_eq "30" "$(hk_int_conf LIMIT_HANDOFF_ZTEST 30)" "a value with letters uses the default"
  unset LIMIT_HANDOFF_ZTEST
}

test_e8_git_line_says_when_only_new_files_exist() {
  command -v git >/dev/null 2>&1 || return 0
  load_hk
  local d="$TL_TMP/gitrepo"
  mkdir -p "$d"
  git -C "$d" init -q </dev/null || fail "git init failed"
  git -C "$d" symbolic-ref HEAD refs/heads/main </dev/null
  printf 'one\n' > "$d/tracked.txt"
  git -C "$d" add -A </dev/null
  git -C "$d" -c commit.gpgsign=false -c user.name="Test User" -c user.email=test@example.invalid commit -q -m first </dev/null || fail "git commit failed"
  printf 'new\n' > "$d/only-new.txt"
  local out
  out="$(hk_git_state "$d")"
  assert_contains "$out" "no line changes against the last commit; see the file list below (new untracked files are not diffed)" "an untracked-only repo needs the new wording (batch E #63)"
  assert_not_contains "$out" "no changes against the last commit" "the old wording is wrong when files are listed (batch E #63)"
}

# ---------------------------------------------------------------------------
# C1-C8. Batch C: untrusted repository content (links, config, secrets, sizes, cwd, regex).
# ---------------------------------------------------------------------------

# c_outside_file name: a file outside the project that a committed link will point at.
c_outside_file() {
  mkdir -p "$TL_TMP/outside"
  printf '%s\n' "$2" > "$TL_TMP/outside/$1"
  printf '%s\n' "$TL_TMP/outside/$1"
}

test_c1_committed_handoff_link_outside_the_project_is_not_written() {
  local p="$CLAUDE_PROJECT_DIR" target
  target="$(c_outside_file notes.md '# Shared notes, must stay as they are')"
  cp "$target" "$TL_TMP/notes.before"
  ln -s "$target" "$p/HANDOFF.md"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "c1-hf-link" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_same_file "$TL_TMP/notes.before" "$target" "a committed HANDOFF.md link wrote outside the project (batch C #27/#28)"
  assert_file_exists "$p/PASTE-PROMPT.txt" "the paste prompt must still be written in the project"
  assert_file_contains "$p/PASTE-PROMPT.txt" "HANDOFF.md was not read or changed" "the paste prompt must say HANDOFF.md was skipped"
}

test_c1_committed_paste_prompt_link_is_not_followed() {
  local p="$CLAUDE_PROJECT_DIR" target
  target="$(c_outside_file CLAUDE.md 'Global rules that must not change')"
  cp "$target" "$TL_TMP/claude.before"
  ln -s "$target" "$p/PASTE-PROMPT.txt"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "c1-pp-link" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_same_file "$TL_TMP/claude.before" "$target" "a committed PASTE-PROMPT.txt link overwrote a file outside the project (batch C #27)"
  assert_eq "0" "$(ls "$TL_TMP/outside" | grep -c bak)" "no backup may be made outside the project"
  assert_file_exists "$LIMIT_HANDOFF_STATE_DIR/PASTE-PROMPT.txt" "the paste prompt goes to the state folder instead"
}

test_c1_committed_latest_link_outside_the_project_is_not_written() {
  local p="$CLAUDE_PROJECT_DIR" target
  target="$(c_outside_file latest-target.md 'keep me')"
  cp "$target" "$TL_TMP/latest.before"
  mkdir -p "$p/.handoff"
  ln -s "$target" "$p/.handoff/LATEST.md"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "c1-latest" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_same_file "$TL_TMP/latest.before" "$target" "a committed LATEST.md link wrote outside the project (batch C #27/#28)"
}

test_c1_follow_links_in_the_project_file_is_ignored() {
  local p="$CLAUDE_PROJECT_DIR" target
  target="$(c_outside_file notes2.md 'stay')"
  cp "$target" "$TL_TMP/notes2.before"
  mkdir -p "$p/.claude"
  printf '%s\n' 'LIMIT_HANDOFF_FOLLOW_LINKS=1' > "$p/.claude/limit-handoff.conf"
  ln -s "$target" "$p/HANDOFF.md"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "c1-conf" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_same_file "$TL_TMP/notes2.before" "$target" "a repository's own config must not switch on link following (batch C #27)"
}

test_c1_reading_a_committed_handoff_link_outside_is_refused() {
  local p="$CLAUDE_PROJECT_DIR" target
  target="$(c_outside_file secret-notes.md '## Next steps (in order)
1. SECRET-LINE-FROM-OUTSIDE')"
  ln -s "$target" "$p/HANDOFF.md"
  tl_run "$TL_HOOK_SESSION" "$(tl_payload_plain SessionStart "c1-read" "$p" startup)"
  assert_exit 0 "$TL_RC"
  assert_not_contains "$TL_OUT" "SECRET-LINE-FROM-OUTSIDE" "a link outside the project must not be read into the session start (batch C #27)"
}

test_c1_follow_links_env_allows_the_link() {
  local p="$CLAUDE_PROJECT_DIR" target
  target="$(c_outside_file dotfile-notes.md '# Dotfile notes')"
  ln -s "$target" "$p/HANDOFF.md"
  export LIMIT_HANDOFF_FOLLOW_LINKS=1
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "c1-env" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$target" 'session="c1-env"' "your own LIMIT_HANDOFF_FOLLOW_LINKS=1 must still allow a dotfiles link (batch C #27)"
}

test_c2_project_config_cannot_choose_the_handoff_file_name() {
  load_hk
  mkdir -p "$CLAUDE_PROJECT_DIR/.claude"
  printf '%s\n' 'LIMIT_HANDOFF_FILE=STATUS.md' > "$CLAUDE_PROJECT_DIR/.claude/limit-handoff.conf"
  assert_eq "HANDOFF.md" "$(hk_handoff_name)" "a project file must not rename HANDOFF.md (batch C #29)"
  export LIMIT_HANDOFF_FILE=NOTES.md
  assert_eq "NOTES.md" "$(hk_handoff_name)" "your own environment setting must still work (batch C #29)"
  unset LIMIT_HANDOFF_FILE
}

test_c2_user_config_can_choose_the_handoff_file_name() {
  load_hk
  mkdir -p "$XDG_CONFIG_HOME/limit-handoff"
  printf '%s\n' 'LIMIT_HANDOFF_FILE=NOTES.md' > "$XDG_CONFIG_HOME/limit-handoff/config"
  assert_eq "NOTES.md" "$(hk_handoff_name)" "your own user config must still choose the name (batch C #29)"
}

test_c2_project_config_cannot_set_keep_or_tail_lines() {
  load_hk
  mkdir -p "$CLAUDE_PROJECT_DIR/.claude"
  printf '%s\n' 'LIMIT_HANDOFF_KEEP=1' 'LIMIT_HANDOFF_TAIL_LINES=3' 'LIMIT_HANDOFF_STALE_MIN=7' > "$CLAUDE_PROJECT_DIR/.claude/limit-handoff.conf"
  assert_eq "30" "$(hk_int_conf_trusted LIMIT_HANDOFF_KEEP 30)" "a project file must not change how many recovered files are kept (batch C #29)"
  assert_eq "4000" "$(hk_int_conf_trusted LIMIT_HANDOFF_TAIL_LINES 4000)" "a project file must not change the transcript read size (batch C #29)"
  assert_eq "7" "$(hk_int_conf LIMIT_HANDOFF_STALE_MIN 20)" "an ordinary setting still reads the project file"
}

test_c2_recover_folder_with_user_files_gets_no_gitignore() {
  local p="$CLAUDE_PROJECT_DIR"
  mkdir -p "$p/.handoff"
  printf '%s\n' 'my own notes' > "$p/.handoff/notes.txt"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "c2-gi" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_missing "$p/.handoff/.gitignore" "a folder with the user's own files must not get a * rule (batch C #29)"
  assert_file_exists "$p/.handoff/notes.txt" "the user's file must be kept"
}

test_c2_recover_folder_made_by_the_kit_gets_its_gitignore() {
  local p="$CLAUDE_PROJECT_DIR"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "c2-gi2" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$p/.handoff/.gitignore" "a folder the kit made keeps its * rule (batch C #29)"
}

test_c34_recovery_reads_only_the_last_bytes_of_a_transcript() {
  load_hk
  local f="$TL_TMP/bytes.jsonl" out first
  {
    jq -n -c --arg t "EARLY-PROMPT $(printf 'x%.0s' $(seq 1 500))" '{type:"user", message:{role:"user", content:$t}}'
    jq -n -c '{type:"user", message:{role:"user", content:"LATE-PROMPT"}}'
  } > "$f"
  HK_TAIL_BYTES=300
  out="$(hk_recover_json "$f" 5)" || fail "recovery failed"
  HK_TAIL_BYTES=33554432
  first="$(printf '%s' "$out" | jq -r '.first_prompt')"
  assert_eq "LATE-PROMPT" "$first" "only the last bytes of the transcript may be read (batch C #34)"
}

test_c30_control_characters_and_backticks_leave_file_paths_and_tasks() {
  load_hk
  local f="$TL_TMP/paths.jsonl" out path
  jq -n -c --arg p "$(printf '/work/a\nb`c`.md')" \
    '{type:"assistant", message:{role:"assistant", content:[{type:"tool_use", id:"t1", name:"Edit", input:{file_path:$p}}]}}' > "$f"
  out="$(hk_recover_json "$f" 5)" || fail "recovery failed"
  path="$(printf '%s' "$out" | jq -r '.files_touched[0]')"
  assert_eq "/work/ab'c'.md" "$path" "a newline or backtick in a file path must not reach the output as it was (batch C #30)"
}

test_c30_next_step_is_one_short_clean_line() {
  load_hk
  local long out
  long="$(printf 'a%.0s' $(seq 1 400))"
  printf '%s\n' '## Next steps (in order)' "1. $long" > "$TL_TMP/hf-long.md"
  out="$(hk_first_next_step "$TL_TMP/hf-long.md")"
  assert_eq "300" "${#out}" "the next step is cut to 300 characters (batch C #30)"
  printf '%s\n' '## Next steps (in order)' "1. first$(printf '\001')bad" > "$TL_TMP/hf-ctrl.md"
  out="$(hk_first_next_step "$TL_TMP/hf-ctrl.md")"
  assert_eq "firstbad" "$out" "control characters are removed from the next step (batch C #30)"
}

test_c31_token_shaped_strings_are_redacted_in_recovered_text() {
  load_hk
  local f="$TL_TMP/secret.jsonl" out sk gh
  # The fake tokens are put together at run time, so no whole token-shaped string sits in this
  # file for a secret scanner to flag.
  sk="sk""-abcdefghijklmnopqrstuvwxyz0123456789"
  gh="gh""p_abcdefghijklmnopqrstuvwxyz0123456789"
  jq -n -c --arg t "use key $sk and $gh now" \
    '{type:"user", message:{role:"user", content:$t}}' > "$f"
  out="$(hk_recover_json "$f" 5)" || fail "recovery failed"
  assert_not_contains "$out" "${sk:0:19}" "an API key must be redacted (batch C #31)"
  assert_not_contains "$out" "${gh:0:20}" "a GitHub token must be redacted (batch C #31)"
  assert_contains "$out" "[redacted]" "the redaction marker must show (batch C #31)"
}

test_c31_created_handoff_does_not_copy_recent_prompts_and_says_to_check_it() {
  local p="$CLAUDE_PROJECT_DIR"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "c31-create" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$p/HANDOFF.md" "HANDOFF.md should be created from the transcript"
  assert_file_not_contains "$p/HANDOFF.md" "Also add a remember-me box" "recent prompts must not be copied into HANDOFF.md (batch C #31)"
  assert_file_contains "$p/HANDOFF.md" "Check it before you commit it." "the created file must say to check it (batch C #31)"
  assert_file_contains "$p/HANDOFF.md" "recovered context file named in the cut-off block" "the created file must point to the recovered file (batch C #31)"
}

test_c33_catch_up_needs_a_cwd_on_the_limit_line() {
  local f="$TL_TMP/nocwd.jsonl" p="$CLAUDE_PROJECT_DIR" out
  jq -n -c '{type:"user", message:{role:"user", content:"hello"}}' > "$f"
  jq -n -c '{type:"assistant", isApiErrorMessage:true, error:"rate_limit", message:{content:[{type:"text", text:"You have hit your limit"}]}}' >> "$f"
  out="$(jq -n -R -c --arg allowed " rate_limit " --arg proj "$p" --arg projp "$p" -f "$TL_ROOT/lib/lastturn.jq" < "$f")"
  assert_eq "" "$(printf '%s' "$out" | jq -r '.code')" "a limit line with no cwd must not count for catch-up (batch C #33)"
  jq -n -c --arg c "$p" '{type:"assistant", cwd:$c, isApiErrorMessage:true, error:"rate_limit", message:{content:[{type:"text", text:"You have hit your limit"}]}}' > "$f"
  out="$(jq -n -R -c --arg allowed " rate_limit " --arg proj "$p" --arg projp "$p" -f "$TL_ROOT/lib/lastturn.jq" < "$f")"
  assert_eq "rate_limit" "$(printf '%s' "$out" | jq -r '.code')" "a limit line with the project cwd still counts"
}

test_c48_long_run_of_spaces_in_a_prompt_is_fast() {
  load_hk
  local f="$TL_TMP/spaces.jsonl" start elapsed
  jq -n -c --arg t "a$(printf '%100000s' '')b" '{type:"user", message:{role:"user", content:$t}}' > "$f"
  start=$SECONDS
  hk_recover_json "$f" 5 > /dev/null || fail "recovery failed"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt "$(tl_time_limit 2)" ] || fail "a prompt with 100000 spaces took $elapsed seconds (batch C #48)"
}

test_c52_a_template_value_over_100k_is_cut_and_shows_it() {
  load_hk
  local t="$TL_TMP/big.tmpl" out
  printf '%s\n' 'START {{BIG}} END' > "$t"
  out="$(hk_render_template "$t" "BIG=$(printf 'z%.0s' $(seq 1 100050))")"
  assert_contains "$out" "[cut]" "a value over 100 KB must show a visible cut (batch C #52)"
  [ "${#out}" -lt 100100 ] || fail "the cut value is still too long (batch C #52)"
}

# ---------------------------------------------------------------------------
# D1-D8. Batch D: markers, catch-up, ordering, the limit time.
# ---------------------------------------------------------------------------

# d_limit_line file cwd time: appends one synthetic limit line (a main-chain StopFailure line).
d_limit_line() {
  jq -n -c --arg c "$2" --arg t "$3" \
    '{type:"assistant", cwd:$c, timestamp:$t, isApiErrorMessage:true, error:"rate_limit", message:{content:[{type:"text", text:"You have hit your session limit"}]}}' >> "$1"
}

test_d1_failed_handoff_write_removes_the_started_marker() {
  local p="$CLAUDE_PROJECT_DIR"
  mkdir -p "$p/HANDOFF.md"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "d1-fail" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_missing "$LIMIT_HANDOFF_STATE_DIR/handled/d1-fail" "a failed write must not leave the started marker (batch D #46/#61)"
  assert_file_missing "$LIMIT_HANDOFF_STATE_DIR/handled/d1-fail.done" "a failed write must not write the done marker (batch D #46/#61)"
}

test_d1_successful_handoff_writes_the_done_marker() {
  local p="$CLAUDE_PROJECT_DIR"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "d1-ok" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$LIMIT_HANDOFF_STATE_DIR/handled/d1-ok.done" "a saved handoff writes the done marker (batch D #46/#61)"
}

test_d1_catchup_retries_a_chat_whose_start_was_never_finished() {
  local p="$CLAUDE_PROJECT_DIR" dir="$TL_TMP/tr-retry"
  mkdir -p "$dir"
  jq -n -c '{type:"user", message:{role:"user", content:"Retry me"}}' > "$dir/retry-01.jsonl"
  d_limit_line "$dir/retry-01.jsonl" "$p" "2026-10-29T10:00:00.000Z"
  mkdir -p "$LIMIT_HANDOFF_STATE_DIR/handled"
  printf '1\n' > "$LIMIT_HANDOFF_STATE_DIR/handled/retry-01"
  touch -t 200001010000 "$LIMIT_HANDOFF_STATE_DIR/handled/retry-01"
  jq -n -c --arg t "$dir/cur.jsonl" --arg c "$p" '{session_id:"cur", transcript_path:$t, cwd:$c, source:"startup", hook_event_name:"SessionStart"}' > "$TL_TMP/cur-payload.json"
  printf '%s\n' '{}' > "$dir/cur.jsonl"
  tl_run "$TL_HOOK_SESSION" "$(cat "$TL_TMP/cur-payload.json")"
  assert_file_contains "$p/HANDOFF.md" 'session="retry-01"' "an old unfinished start is retried by catch-up (batch D #46/#61)"
}

test_d1_catchup_skips_a_chat_whose_start_is_still_running() {
  local p="$CLAUDE_PROJECT_DIR" dir="$TL_TMP/tr-busy"
  mkdir -p "$dir"
  jq -n -c '{type:"user", message:{role:"user", content:"Busy"}}' > "$dir/busy-01.jsonl"
  d_limit_line "$dir/busy-01.jsonl" "$p" "2026-10-29T10:00:00.000Z"
  mkdir -p "$LIMIT_HANDOFF_STATE_DIR/handled"
  printf '1\n' > "$LIMIT_HANDOFF_STATE_DIR/handled/busy-01"
  jq -n -c --arg t "$dir/cur.jsonl" --arg c "$p" '{session_id:"cur", transcript_path:$t, cwd:$c, source:"startup", hook_event_name:"SessionStart"}' > "$TL_TMP/cur-payload.json"
  printf '%s\n' '{}' > "$dir/cur.jsonl"
  tl_run "$TL_HOOK_SESSION" "$(cat "$TL_TMP/cur-payload.json")"
  assert_file_missing "$p/HANDOFF.md" "a chat whose start is still running must not be handed off twice (batch D #46/#61)"
}

test_d2_catchup_run_leaves_the_git_section_out() {
  command -v git >/dev/null 2>&1 || return 0
  local p="$CLAUDE_PROJECT_DIR"
  git -C "$p" init -q </dev/null || fail "git init failed"
  printf 'x\n' > "$p/tracked.txt"
  git -C "$p" add -A </dev/null
  git -C "$p" -c commit.gpgsign=false -c user.name="Test User" -c user.email=test@example.invalid commit -q -m first </dev/null || fail "git commit failed"
  LIMIT_HANDOFF_CATCHUP_RUN=1 tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "d2-catch" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  local rec; rec="$(ls "$p"/.handoff/recovered-*d2-catc*.md 2>/dev/null | head -n 1)"
  assert_file_exists "$rec" "the recovered file is written"
  assert_file_not_contains "$rec" "Repository state" "a catch-up run must not add the git section (batch D #47/#59)"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "d2-live" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  rec="$(ls "$p"/.handoff/recovered-*d2-live*.md 2>/dev/null | head -n 1)"
  assert_file_contains "$rec" "Repository state" "a live stop keeps the git section"
}

test_d4_catchup_runs_the_oldest_chat_last() {
  local p="$CLAUDE_PROJECT_DIR" dir="$TL_TMP/tr-order"
  mkdir -p "$dir"
  jq -n -c '{type:"user", message:{role:"user", content:"Old chat"}}' > "$dir/old-aa.jsonl"
  d_limit_line "$dir/old-aa.jsonl" "$p" "2026-10-29T09:00:00.000Z"
  jq -n -c '{type:"user", message:{role:"user", content:"New chat"}}' > "$dir/new-bb.jsonl"
  d_limit_line "$dir/new-bb.jsonl" "$p" "2026-10-29T10:00:00.000Z"
  # Both chats must be inside the catch-up window (48 hours), so their times are recent.
  touch -t "$(date -v-20M '+%Y%m%d%H%M' 2>/dev/null || date -d '-20 min' '+%Y%m%d%H%M')" "$dir/old-aa.jsonl"
  touch -t "$(date -v-10M '+%Y%m%d%H%M' 2>/dev/null || date -d '-10 min' '+%Y%m%d%H%M')" "$dir/new-bb.jsonl"
  printf '%s\n' '{}' > "$dir/cur.jsonl"
  jq -n -c --arg t "$dir/cur.jsonl" --arg c "$p" '{session_id:"cur", transcript_path:$t, cwd:$c, source:"startup", hook_event_name:"SessionStart"}' > "$TL_TMP/order-payload.json"
  tl_run "$TL_HOOK_SESSION" "$(cat "$TL_TMP/order-payload.json")"
  assert_file_contains "$p/PASTE-PROMPT.txt" "-new-bb" "the newest chat must write the paste prompt last (batch D #54)"
}

test_d5_newest_unresolved_block_is_the_latest_time_not_the_last_in_file() {
  load_hk
  local f="$TL_TMP/two-blocks.md"
  {
    hk_cutoff_block "newer-s" "2026-10-30T08:00:00Z" rate_limit "usage limit reached" "2026-10-30 08:00" "r1.md"
    hk_cutoff_block "older-s" "2026-10-29T10:00:00Z" rate_limit "usage limit reached" "2026-10-29 10:00" "r2.md"
  } > "$f"
  local b; b="$(hk_last_unresolved_block "$f")"
  assert_contains "$b" 'session="newer-s"' "the block with the later time is the newest (batch D #57)"
  assert_eq "2" "$(hk_unresolved_count "$f")" "two unresolved blocks are counted"
}

test_d5_two_unresolved_blocks_say_how_many_and_name_the_session() {
  load_hk
  local f="$CLAUDE_PROJECT_DIR/HANDOFF.md" msg
  {
    hk_cutoff_block "newer-s" "2026-10-30T08:00:00Z" rate_limit "usage limit reached" "2026-10-30 08:00" "r1.md"
    hk_cutoff_block "older-s" "2026-10-29T10:00:00Z" rate_limit "usage limit reached" "2026-10-29 10:00" "r2.md"
  } > "$f"
  msg="$(hk_cutoff_message "$f" "$(hk_last_unresolved_block "$f")")"
  assert_contains "$msg" "2 chats were cut off (sessions: newer-s, older-s)" "the reminder says how many and lists them (batch D #12/#57)"
  assert_contains "$msg" "The newest is session newer-s" "the reminder names the newest (batch D #12/#57)"
  assert_contains "$msg" "resolve --session <id>\` for each chat" "the reminder says to resolve each chat by id (batch D #12/#57)"
}

test_d6_prune_keeps_a_file_that_an_unresolved_block_names() {
  load_hk
  local d="$CLAUDE_PROJECT_DIR/.handoff" i
  mkdir -p "$d"
  for i in 1 2 3; do printf 'old\n' > "$d/recovered-2020010$i-000000-abcdefgh.md"; done
  printf '%s\n' '# H' '<!-- limit-handoff:cutoff session="x" at="2020-01-01T00:00:00Z" error="rate_limit" status="unresolved" -->' \
    '> Check. Recovered context: `.handoff/recovered-20200101-000000-abcdefgh.md`' '<!-- /limit-handoff:cutoff -->' > "$CLAUDE_PROJECT_DIR/HANDOFF.md"
  hk_prune_recovered "$d" 1 ""
  assert_file_exists "$d/recovered-20200101-000000-abcdefgh.md" "the file an unresolved block names must be kept (batch D #56)"
}

test_d7_block_time_is_the_time_of_the_limit_line() {
  local p="$CLAUDE_PROJECT_DIR" tr="$TL_TMP/timed.jsonl"
  export TZ=UTC
  jq -n -c --arg c "$p" '{type:"user", cwd:$c, message:{role:"user", content:"Timed"}}' > "$tr"
  d_limit_line "$tr" "$p" "2026-10-29T10:00:00.000Z"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "d7-time" "$tr" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" 'at="2026-10-29T10:00:00Z"' "the block time is the limit line's own time (batch D #13)"
  assert_file_contains "$p/HANDOFF.md" "(rate or usage limit reached) at 2026-10-29 10:00." "the cut-off line uses the same time (batch D #13)"
}

test_d7_a_reset_time_in_the_past_says_it_has_passed() {
  load_hk
  export TZ=UTC
  assert_contains "$(hk_limit_text five_hour 1000000000)" "the reset time has passed" "a past reset time must say so (batch D #13)"
}

test_d8_a_typed_prompt_after_a_limit_clears_the_limit() {
  load_hk
  local f="$TL_TMP/after-limit.jsonl" out
  jq -n -c '{type:"user", message:{role:"user", content:"first"}}' > "$f"
  d_limit_line "$f" "$CLAUDE_PROJECT_DIR" "2026-10-29T10:00:00.000Z"
  jq -n -c '{type:"user", message:{role:"user", content:"carry on"}}' >> "$f"
  out="$(hk_recover_json "$f" 5)" || fail "recovery failed"
  assert_eq "null" "$(printf '%s' "$out" | jq -c '.limit')" "an old limit must not show after the chat went on (batch D #55)"
}

# ---------------------------------------------------------------------------
# F1-F12. Batch F: command line and hook messages.
# ---------------------------------------------------------------------------

test_f1_install_without_jq_says_so_and_changes_nothing() {
  tl_use_nojq
  local s="$TL_TMP/cfg/settings.json"
  tl_kit install --settings "$s"
  assert_exit 1 "$TL_RC" "install without jq must stop (batch F #7)"
  assert_contains "$TL_ERR" "install needs jq" "the message names jq (batch F #7)"
  assert_contains "$TL_ERR" "Nothing was changed." "the message says nothing changed (batch F #7)"
  assert_file_missing "$s" "no settings file may be made without jq (batch F #7)"
  tl_kit install
  assert_exit 2 "$TL_RC" "a usage error still exits 2 without jq (batch F #7)"
}

test_f1_uninstall_without_jq_says_so() {
  tl_use_nojq
  local s="$TL_TMP/cfg/settings.json"
  mkdir -p "$TL_TMP/cfg"
  printf '%s\n' '{}' > "$s"
  tl_kit uninstall --settings "$s"
  assert_exit 1 "$TL_RC" "uninstall without jq must stop (batch F #7)"
  assert_contains "$TL_ERR" "uninstall needs jq" "the message names jq (batch F #7)"
}

test_f3_simulate_with_a_code_outside_the_list_writes_nothing() {
  local p="$CLAUDE_PROJECT_DIR"
  tl_kit simulate --dir "$p" --error bogus_code
  assert_exit 1 "$TL_RC" "a code that is not in LIMIT_HANDOFF_ERRORS is an error (batch F #14)"
  assert_contains "$TL_OUT$TL_ERR" "Nothing was written: bogus_code is not in LIMIT_HANDOFF_ERRORS" "the message says so (batch F #14)"
  assert_file_missing "$p/HANDOFF.md" "nothing may be written for a code the hook ignores (batch F #14)"
}

test_f3_two_simulate_runs_each_check_their_own_files() {
  local p="$CLAUDE_PROJECT_DIR"
  tl_kit simulate --dir "$p"
  assert_exit 0 "$TL_RC" "the first simulate succeeds (batch F #14)"
  tl_kit simulate --dir "$p"
  assert_exit 0 "$TL_RC" "a second simulate succeeds too (batch F #14)"
  assert_count "$p/HANDOFF.md" 'limit-handoff:cutoff session="simulated-' 2 "each run adds its own block (batch F #14)"
  # Each block must name its own recovered file (two runs in one second must not share a name).
  local names
  names="$(sed -n 's/.*Recovered context: `\([^`]*\)`.*/\1/p' "$p/HANDOFF.md" | sort -u | grep -c .)"
  assert_eq "2" "$names" "two simulate runs must get two recovered files"
}

test_f4_reminders_name_the_handoff_file_from_the_setting() {
  local p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# Status' > "$p/STATUS.md"
  export LIMIT_HANDOFF_FILE=STATUS.md LIMIT_HANDOFF_REMIND=always
  tl_run "$TL_HOOK_PROMPT" "$(tl_payload_plain UserPromptSubmit "f4-sess" "$p" "")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "STATUS.md exists here" "the reminder names the configured file (batch F #15)"
  assert_not_contains "$TL_OUT" "HANDOFF.md" "the default name must not show (batch F #15)"
}

test_f5_install_with_fewer_events_says_what_was_removed() {
  local s="$TL_TMP/cfg/settings.json"
  mkdir -p "$TL_TMP/cfg"
  tl_kit install --settings "$s" --events stop-failure,prompt-submit
  assert_exit 0 "$TL_RC" "the first install succeeds"
  tl_kit install --settings "$s" --events stop-failure
  assert_exit 0 "$TL_RC" "the second install succeeds"
  assert_contains "$TL_OUT" "Removed kit hooks not in --events: prompt-submit" "the removed hook is named (batch F #17)"
}

test_f6_prompt_with_clipboard_off_says_nothing_was_copied() {
  local p="$CLAUDE_PROJECT_DIR"
  export LIMIT_HANDOFF_CLIPBOARD=off
  tl_kit prompt --dir "$p"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "Clipboard is off in your settings, so nothing was copied. Copy the text below by hand." "the message says the clipboard is off (batch F #19)"
}

test_f8_doctor_with_invalid_settings_json_exits_2() {
  local s="$TL_TMP/cfg/settings.json"
  mkdir -p "$TL_TMP/cfg"
  printf '%s\n' '{ not json' > "$s"
  tl_kit doctor --settings "$s"
  assert_exit 2 "$TL_RC" "invalid settings JSON is a problem for doctor (batch F #22)"
  assert_contains "$TL_OUT" "is not valid JSON, so its hooks could not be checked" "doctor says what is wrong (batch F #22)"
}

test_f9_status_with_a_blank_settings_file_is_none_and_exits_0() {
  local s="$TL_TMP/cfg/settings.json"
  mkdir -p "$TL_TMP/cfg"
  printf '\n  \n' > "$s"
  tl_kit status --settings "$s"
  assert_exit 0 "$TL_RC" "a blank settings file is not an error (batch F #23)"
  assert_contains "$TL_OUT" "Kit hooks in $s: none (the file is empty)" "the blank file is reported (batch F #23)"
}

test_f10_unknown_error_code_lists_the_codes_a_user_can_use() {
  local s="$TL_TMP/cfg/settings.json"
  mkdir -p "$TL_TMP/cfg"
  tl_kit install --settings "$s" --errors bogus_code
  assert_exit 2 "$TL_RC" "an unknown code is a usage error"
  assert_contains "$TL_ERR" "Codes you can use: rate_limit" "the message lists the codes (batch F #24)"
  assert_not_contains "$TL_ERR" "prompt_too_long" "prompt_too_long is not a code a user can give (batch F #24)"
}

test_f11_resolve_without_handoff_says_where_to_run_it() {
  tl_kit resolve --dir "$CLAUDE_PROJECT_DIR"
  assert_exit 1 "$TL_RC"
  assert_contains "$TL_ERR" "Run this from your project folder, or add --dir <project folder>." "the message says where to run it (batch F #25)"
}

test_f12_install_warns_when_a_sibling_settings_file_turns_the_plugin_on() {
  local s="$TL_TMP/cfg/settings.json"
  mkdir -p "$TL_TMP/cfg"
  printf '%s\n' '{"enabledPlugins":{"limit-handoff@limit-handoff":true}}' > "$TL_TMP/cfg/settings.local.json"
  tl_kit install --settings "$s"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_ERR" "already turned on in $TL_TMP/cfg/settings.local.json" "the sibling file is checked too (batch F #62)"
}

test_a10_shellcheck_passes_at_warning_level_when_installed() {
  # The same command as the CI job. Skipped when ShellCheck is not installed.
  command -v shellcheck >/dev/null 2>&1 || return 0
  local out
  out="$(cd "$TL_ROOT" && shellcheck --shell=bash --severity=warning --external-sources \
    bin/limit-handoff hooks/*.sh lib/common.sh 2>&1)" || fail "ShellCheck reports warnings: $out"
}

# ---------------------------------------------------------------------------
# O1-O6. Fixes from the Opus review of the batch work.
# ---------------------------------------------------------------------------

# o_session_start dir: runs the session-start hook as a new chat in dir (startup source).
o_session_start() {
  printf '%s\n' '{}' > "$1/cur.jsonl"
  tl_run "$TL_HOOK_SESSION" "$(jq -n -c --arg t "$1/cur.jsonl" --arg c "$CLAUDE_PROJECT_DIR" \
    '{session_id:"cur", transcript_path:$t, cwd:$c, source:"startup", hook_event_name:"SessionStart"}')"
}

test_o1_catchup_remembers_a_chat_with_no_limit() {
  local p="$CLAUDE_PROJECT_DIR" dir="$TL_TMP/tr-checked"
  mkdir -p "$dir"
  jq -n -c --arg c "$p" '{type:"user", cwd:$c, message:{role:"user", content:"All fine"}}' > "$dir/fine-01.jsonl"
  jq -n -c --arg c "$p" '{type:"assistant", cwd:$c, message:{content:[{type:"text", text:"Done."}]}}' >> "$dir/fine-01.jsonl"
  o_session_start "$dir"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$LIMIT_HANDOFF_STATE_DIR/checked/fine-01" "a chat with no limit is remembered (batch D #53)"
  load_hk
  assert_eq "$(hk_file_mtime "$dir/fine-01.jsonl")" "$(cat "$LIMIT_HANDOFF_STATE_DIR/checked/fine-01")" "the memory holds the transcript time (batch D #53)"
}

test_o2_catchup_skips_a_chat_whose_block_exists_and_restores_the_done_marker() {
  local p="$CLAUDE_PROJECT_DIR" dir="$TL_TMP/tr-resolved"
  mkdir -p "$dir"
  jq -n -c '{type:"user", message:{role:"user", content:"Old work"}}' > "$dir/done-01.jsonl"
  d_limit_line "$dir/done-01.jsonl" "$p" "2026-10-29T10:00:00.000Z"
  printf '%s\n' '# H' '<!-- limit-handoff:cutoff session="done-01" at="2026-10-29T10:00:00Z" error="rate_limit" status="resolved" -->' \
    '> old' '<!-- /limit-handoff:cutoff -->' > "$p/HANDOFF.md"
  o_session_start "$dir"
  assert_exit 0 "$TL_RC"
  assert_not_contains "$TL_OUT" "wrote a handoff" "a chat whose block exists is not handed off again (batch D #58)"
  assert_eq "1" "$(grep -c 'session="done-01"' "$p/HANDOFF.md")" "no second block is added (batch D #58)"
  assert_file_exists "$LIMIT_HANDOFF_STATE_DIR/handled/done-01.done" "the done marker is put back (batch D #58)"
}

test_o3_catchup_line_names_the_real_stop_reason() {
  local p="$CLAUDE_PROJECT_DIR" dir="$TL_TMP/tr-overloaded"
  mkdir -p "$dir"
  jq -n -c '{type:"user", message:{role:"user", content:"Busy API"}}' > "$dir/over-01.jsonl"
  jq -n -c --arg c "$p" '{type:"assistant", cwd:$c, isApiErrorMessage:true, error:"overloaded", message:{content:[{type:"text", text:"API Error: overloaded"}]}}' >> "$dir/over-01.jsonl"
  o_session_start "$dir"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "It stopped (API overloaded) and had no handoff." "a stop that is not a usage limit is not called one"
  assert_not_contains "$TL_OUT" "usage limit" "the catch-up line must not say usage limit for an overloaded stop"
}

test_o4_redact_keeps_long_words_and_hides_mixed_tokens() {
  local out
  out="$(jq -n -c '{type:"assistant", message:{content:[{type:"tool_use", name:"Bash", input:{command:"echo AbstractSingletonProxyFactoryBeanConfigurationHelper k8sTOKEN1234567890abcdefghijklmnopqrstuvwxyz"}}]}}' \
    | jq -n -R -c --argjson np 5 -f "$TL_ROOT/lib/transcript.jq" | jq -r '.last_commands[0].command')"
  assert_contains "$out" "AbstractSingletonProxyFactoryBeanConfigurationHelper" "a long plain word is not a token"
  assert_not_contains "$out" "k8sTOKEN1234567890" "a long mix of letters and digits is redacted"
}

test_o4_redact_is_fast_on_a_huge_command() {
  local f="$TL_TMP/huge-cmd.jsonl" start
  jq -n -c --arg c "echo $(printf 'b%.0s' $(seq 1 100000))" '{type:"assistant", message:{content:[{type:"tool_use", name:"Bash", input:{command:$c}}]}}' > "$f"
  start=$SECONDS
  jq -n -R -c --argjson np 5 -f "$TL_ROOT/lib/transcript.jq" < "$f" > /dev/null || fail "the filter failed"
  [ $((SECONDS - start)) -lt "$(tl_time_limit 3)" ] || fail "redacting a 100000 letter command took too long"
}

test_o5_created_handoff_shows_the_default_lines_when_nothing_was_found() {
  local p="$CLAUDE_PROJECT_DIR" tr="$TL_TMP/bare.jsonl"
  jq -n -c '{type:"user", message:{role:"user", content:"Just a question"}}' > "$tr"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "o5-bare" "$tr" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "Nothing was recorded in the recent transcript." "an empty Done list gets its default line"
}

test_o6_limit_text_with_a_bad_epoch_prints_no_error() {
  load_hk
  local err
  err="$(hk_limit_text five_hour "12x" 2>&1 >/dev/null)"
  assert_eq "" "$err" "a bad reset time must not print a shell error"
}

test_s1_simulate_uses_fresh_times_for_the_bundled_sample() {
  local p="$CLAUDE_PROJECT_DIR" before
  before="$(cksum < "$TL_ROOT/examples/sample-transcript.jsonl")"
  tl_kit simulate --dir "$p"
  assert_exit 0 "$TL_RC"
  assert_eq "" "$TL_ERR" "simulate prints no errors"
  assert_file_contains "$p/HANDOFF.md" "5-hour limit, resets" "the sample's limit details are shown"
  assert_file_not_contains "$p/HANDOFF.md" "the reset time has passed" "the sample's reset time is in the future"
  assert_file_contains "$p/HANDOFF.md" "1. Add email and password validation" "the sample's open tasks become the next steps"
  assert_eq "$before" "$(cksum < "$TL_ROOT/examples/sample-transcript.jsonl")" "the bundled sample is not changed"
}

test_s2_simulate_with_another_code_shows_no_limit_details() {
  local p="$CLAUDE_PROJECT_DIR"
  tl_kit simulate --dir "$p" --error unknown
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" 'error="unknown"' "the block has the simulated code"
  assert_file_not_contains "$p/HANDOFF.md" "5-hour limit" "no usage-limit details for a code that is not rate_limit"
}

# ---------------------------------------------------------------------------
# L1-L5. The lock is a noclobber file (mkdir is not atomic in Ubuntu 26.04's uutils).
# ---------------------------------------------------------------------------

# l_lock_path file: the lock file hk_lock_take uses for file.
l_lock_path() {
  local key
  key="$(printf '%s' "$(hk_real_path "$1")" | cksum | tr -s ' \t' '__' | tr -cd '0-9_')"
  printf '%s/locks/%s.lock\n' "$(hk_state_dir)" "$key"
}

test_l1_lock_is_a_file_with_the_owner_pid_and_release_removes_it() {
  load_hk
  local f="$TL_TMP/target.md" lock
  lock="$(l_lock_path "$f")"
  hk_lock_take "$f" || fail "the lock was not taken"
  [ -f "$lock" ] || fail "the lock must be a file: $lock"
  assert_eq "$$" "$(cat "$lock")" "the lock holds the owner's process id"
  hk_lock_release
  assert_file_missing "$lock" "release removes the lock"
}

test_l2_a_lock_left_by_an_ended_process_is_cleared_fast() {
  load_hk
  local f="$TL_TMP/target.md" lock dead start
  lock="$(l_lock_path "$f")"
  sleep 0 & dead=$!
  wait "$dead"
  mkdir -p "$(dirname "$lock")"
  printf '%s\n' "$dead" > "$lock"
  start=$SECONDS
  hk_lock_take "$f" || fail "the lock was not taken"
  [ $((SECONDS - start)) -lt "$(tl_time_limit 4)" ] || fail "a lock of an ended process took too long to clear"
  assert_eq "$$" "$(cat "$lock")" "the lock now belongs to this process"
  hk_lock_release
}

test_l3_an_old_style_lock_folder_is_cleaned_up() {
  load_hk
  local f="$TL_TMP/target.md" lock
  lock="$(l_lock_path "$f")"
  mkdir -p "$lock"
  hk_lock_take "$f" || fail "the lock was not taken"
  [ -f "$lock" ] || fail "the old lock folder must be replaced by a lock file"
  hk_lock_release
}

test_l4_release_leaves_a_lock_that_another_process_took_over() {
  load_hk
  local f="$TL_TMP/target.md" lock
  lock="$(l_lock_path "$f")"
  hk_lock_take "$f" || fail "the lock was not taken"
  printf '%s\n' 999999 > "$lock"
  hk_lock_release
  assert_file_exists "$lock" "a lock owned by another process must not be removed"
  rm -f "$lock"
}

test_l5_two_processes_never_hold_the_lock_together() {
  load_hk
  local f="$TL_TMP/counter.md" c="$TL_TMP/count"
  printf '0\n' > "$c"
  # Each worker adds 1 to the counter 50 times, with a read, a pause and a write under the lock.
  l_worker() {
    local i n
    for i in $(seq 1 50); do
      hk_lock_take "$f"
      n="$(cat "$c")"
      sleep 0.001 2>/dev/null
      printf '%s\n' $((n + 1)) > "$c"
      hk_lock_release
    done
  }
  l_worker & l_worker & wait
  assert_eq "100" "$(cat "$c")" "a lost update means two processes held the lock at once"
}

test_l5_the_lock_does_not_use_mkdir() {
  if sed -n '/^hk_lock_take()/,/^}/p' "$TL_ROOT/lib/common.sh" | grep -q 'while ! mkdir'; then
    fail "hk_lock_take must not use mkdir as the lock (not atomic with uutils mkdir)"
  fi
}

# ---------------------------------------------------------------------------
# V1-V16. Leftovers found when every finding was checked again on the fixed code.
# ---------------------------------------------------------------------------

# v_bare_transcript file: a chat with one prompt and no tasks, so no next step can be derived.
v_bare_transcript() {
  jq -n -c --arg c "$CLAUDE_PROJECT_DIR" '{type:"user", cwd:$c, message:{role:"user", content:"Help me"}}' > "$1"
}

test_v1_install_without_jq_still_reports_a_bad_event_as_a_usage_error() {
  tl_use_nojq
  tl_kit install --settings "$TL_TMP/cfg/settings.json" --events nope
  assert_exit 2 "$TL_RC" "a bad --events name is a usage error, even without jq (#7)"
}

test_v2_failed_create_gives_a_paste_prompt_without_handoff_md() {
  local p="$CLAUDE_PROJECT_DIR"
  mkdir -p "$p/HANDOFF.md"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "v2-fail" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_not_contains "$p/PASTE-PROMPT.txt" "First read" "the paste prompt must not send the new chat to a HANDOFF.md that was not made (#8/#61)"
  assert_file_not_contains "$p/PASTE-PROMPT.txt" "Keep HANDOFF.md updated" "no keep-updated line without HANDOFF.md (#8)"
}

test_v3_no_next_step_asks_the_new_chat_to_work_it_out() {
  local p="$CLAUDE_PROJECT_DIR" tr="$TL_TMP/bare.jsonl"
  v_bare_transcript "$tr"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "v3-bare" "$tr" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/PASTE-PROMPT.txt" "Read the recovered file, work out the next step, and tell me what it is before you change any file." "the no-next-step wording is used (#8)"
  assert_file_not_contains "$p/PASTE-PROMPT.txt" "start with: Read the recovered" "no fake next step (#8)"
}

test_v4_no_recovered_file_means_the_created_handoff_points_at_none() {
  local p="$CLAUDE_PROJECT_DIR" tr="$TL_TMP/bare.jsonl"
  v_bare_transcript "$tr"
  printf 'x\n' > "$p/.handoff"
  mkdir -p "$LIMIT_HANDOFF_STATE_DIR"
  printf 'x\n' > "$LIMIT_HANDOFF_STATE_DIR/recovered"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "v4-norec" "$tr" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "Recovered context: not written" "the block says no file was written (#11/#60)"
  assert_file_not_contains "$p/HANDOFF.md" "recovered context file named in the cut-off block" "the created file must not point at a file that does not exist (#11)"
  assert_file_not_contains "$p/PASTE-PROMPT.txt" "recovered file," "the paste prompt must not point at a recovered file (#11)"
}

test_v5_created_handoff_status_uses_the_limit_time() {
  local p="$CLAUDE_PROJECT_DIR" tr="$TL_TMP/timed2.jsonl"
  export TZ=UTC
  v_bare_transcript "$tr"
  d_limit_line "$tr" "$p" "2026-10-29T10:00:00.000Z"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "v5-time" "$tr" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "at 2026-10-29 10:00 — auto-created" "the Status line uses the limit line's time (#13)"
}

test_v6_notification_says_when_no_handoff_md_was_made() {
  local p="$CLAUDE_PROJECT_DIR"
  tl_use_notify
  export LIMIT_HANDOFF_CREATE_IF_MISSING=0
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "v6-none" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_contains "$(sed -n 2p "$TEST_OUT/notify.txt")" "No HANDOFF.md was written, so the paste prompt is all you have" "the body must not say Handoff saved (#9)"
}

test_v7_paste_prompt_falls_back_to_the_state_folder_and_the_notification_says_where() {
  local p="$CLAUDE_PROJECT_DIR"
  tl_use_notify
  mkdir -p "$p/PASTE-PROMPT.txt"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "v7-pp" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$LIMIT_HANDOFF_STATE_DIR/PASTE-PROMPT.txt" "the paste prompt goes to the state folder (#8/#18)"
  assert_contains "$(sed -n 2p "$TEST_OUT/notify.txt")" "paste prompt saved to $LIMIT_HANDOFF_STATE_DIR/PASTE-PROMPT.txt" "the body names the real place (#9/#18)"
}

test_v8_clipboard_off_words_all_give_the_off_message() {
  local p="$CLAUDE_PROJECT_DIR" w
  for w in no 0 false none; do
    export LIMIT_HANDOFF_CLIPBOARD="$w"
    tl_kit prompt --dir "$p"
    assert_contains "$TL_OUT" "Clipboard is off in your settings" "LIMIT_HANDOFF_CLIPBOARD=$w is off too (#19)"
  done
}

test_v9_status_reports_an_unreadable_settings_file() {
  [ "$(id -u)" != 0 ] || return 0
  local s="$TL_TMP/cfg/settings.json"
  mkdir -p "$TL_TMP/cfg"
  printf '{}\n' > "$s"
  chmod 000 "$s"
  tl_kit status --settings "$s"
  chmod 600 "$s"
  assert_contains "$TL_OUT" "cannot read $s" "an unreadable file is not called empty (#23)"
  assert_not_contains "$TL_OUT" "the file is empty" "an unreadable file is not called empty (#23)"
}

test_v10_errors_prompt_too_long_is_a_usage_error() {
  tl_kit install --settings "$TL_TMP/cfg/settings.json" --errors prompt_too_long
  assert_exit 2 "$TL_RC" "prompt_too_long is not a code a user can give (#24)"
}

test_v11_doctor_refuses_settings_that_are_not_an_object() {
  local s="$TL_TMP/cfg/settings.json"
  mkdir -p "$TL_TMP/cfg"
  printf '[]\n' > "$s"
  tl_kit doctor --settings "$s"
  assert_exit 2 "$TL_RC" "a JSON list is not a settings file (#22)"
}

test_v12_a_handoff_link_into_dot_claude_is_not_written() {
  local p="$CLAUDE_PROJECT_DIR"
  mkdir -p "$p/.claude"
  printf '%s\n' '{"hooks":{}}' > "$p/.claude/settings.json"
  cp "$p/.claude/settings.json" "$TL_TMP/settings.before"
  ln -s ".claude/settings.json" "$p/HANDOFF.md"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "v12-claude" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_same_file "$TL_TMP/settings.before" "$p/.claude/settings.json" "a HANDOFF.md link into .claude must not be written (#28)"
}

test_v13_an_empty_folder_the_user_made_gets_no_gitignore() {
  local p="$CLAUDE_PROJECT_DIR"
  export LIMIT_HANDOFF_RECOVER_DIR=notes
  mkdir -p "$p/notes"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "v13-empty" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  assert_file_missing "$p/notes/.gitignore" "an empty folder the user made must not get a * rule (#32)"
}

test_v13_a_dot_dot_name_counts_as_a_user_file() {
  local p="$CLAUDE_PROJECT_DIR"
  mkdir -p "$p/.handoff"
  printf 'x\n' > "$p/.handoff/..notes"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "v13-dots" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_file_missing "$p/.handoff/.gitignore" "a ..name file is the user's (#32)"
}

test_v14_catchup_read_is_bounded_in_bytes() {
  grep -q 'tail -c "\$HK_TAIL_BYTES" "\$file" 2>/dev/null | tail -n 300' "$TL_ROOT/lib/common.sh" \
    || fail "hk_last_limit_code must read a byte-bounded tail (#34)"
}

test_v15_a_long_run_of_zeros_in_config_is_fast() {
  load_hk
  local start out
  start=$SECONDS
  out="$(_hk_int_clean "$(printf '0%.0s' $(seq 1 100000))5" 20)"
  assert_eq "20" "$out" "a value over 64 characters uses the default (#49)"
  assert_eq "8" "$(_hk_int_clean "0008" 20)" "leading zeros are removed (#49)"
  [ $((SECONDS - start)) -lt "$(tl_time_limit 3)" ] || fail "100000 leading zeros took too long (#49)"
}

test_v16_direction_marks_leave_file_paths() {
  local out
  out="$(jq -n -c '{type:"assistant", message:{content:[{type:"tool_use", name:"Edit", input:{file_path:"a‮b c.txt"}}]}}' \
    | jq -n -R -c --argjson np 5 -f "$TL_ROOT/lib/transcript.jq" | jq -r '.files_touched[0]')"
  assert_eq "abc.txt" "$out" "direction marks and line separators are removed (#30)"
}

test_v16_a_multibyte_template_value_is_cut_by_bytes() {
  load_hk
  local t="$TL_TMP/mb.tmpl" out v loc
  # A UTF-8 locale is needed, or bash counts bytes anyway and the test proves nothing.
  loc="$(locale -a 2>/dev/null | grep -i -E '^(en_US|C)\.utf-?8$' | head -n 1)"
  [ -n "$loc" ] || return 0
  printf '%s\n' 'S {{V}} E' > "$t"
  v="$(printf 'é%.0s' $(seq 1 60000))"
  out="$(export LC_ALL="$loc"; [ "${#v}" = 60000 ] || exit 3; hk_render_template "$t" "V=$v")" \
    || fail "the UTF-8 locale $loc did not count characters"
  assert_contains "$out" "[cut]" "120000 bytes of text must be cut at 100 KB (#52)"
}

test_v16_manual_prompt_does_not_promise_messages() {
  tl_kit prompt --dir "$CLAUDE_PROJECT_DIR"
  assert_file_not_contains "$CLAUDE_PROJECT_DIR/PASTE-PROMPT.txt" "for the last messages before the cut-off" "a manual handoff has no messages to point to (#8)"
}

run_tests
