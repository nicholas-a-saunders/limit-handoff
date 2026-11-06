#!/bin/bash
# Tests for the housekeeping of recovered files: the .gitignore that keeps chat text out of git,
# and the pruning of old recovered files (LIMIT_HANDOFF_KEEP). All files are made up in tests/.tmp.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The name pattern a recovered file must match before it can be counted or pruned.
RE_PAT='^recovered-[0-9]{8}-[0-9]{6}-[A-Za-z0-9_-]{1,8}(-precompact)?\.md$'

project() {
  [ -n "$CLAUDE_PROJECT_DIR" ] || fail "CLAUDE_PROJECT_DIR is empty; refusing to continue"
  printf "%s\n" "$CLAUDE_PROJECT_DIR"
}

# run_stop: sends one StopFailure for the project, with a fixed session id "prune-sess".
run_stop() {
  local payload
  payload="$(tl_payload_stop "prune-sess" "$(tl_fixture basic.jsonl)" "$CLAUDE_PROJECT_DIR" "rate_limit")"
  tl_run "$TL_HOOK_STOP" "$payload"
}

# make_old_recovered dir count: makes count recovered files with 2020 stamps, oldest first.
# The names are regular files that match the pattern: recovered-20200101-000001-abcdefgh.md, and so on.
make_old_recovered() {
  local d="$1" n="$2" i=1 num
  mkdir -p "$d"
  while [ "$i" -le "$n" ]; do
    num="$(printf '%06d' "$i")"
    printf 'old file %s\n' "$i" > "$d/recovered-20200101-$num-abcdefgh.md"
    i=$((i + 1))
  done
}

# count_recovered dir: how many regular files in dir match the recovered file pattern (links excluded).
count_recovered() {
  find "$1" -maxdepth 1 -type f 2>/dev/null | sed 's#.*/##' | grep -c -E "$RE_PAT" || true
}

# load_common: loads the shared library for direct function tests (as test_common.sh does).
load_common() {
  . "$TL_ROOT/lib/common.sh"
  HK_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
}

# The exact two lines the kit writes into a new .gitignore.
expected_gitignore() {
  printf '%s\n%s\n' "# Created by limit-handoff: recovered chat text stays out of git." "*"
}

# ---------------------------------------------------------------------------
# .gitignore inside the recover folder
# ---------------------------------------------------------------------------

test_gitignore_is_created_once_with_exact_content() {
  local p gi; p="$(project)"; gi="$p/.handoff/.gitignore"
  expected_gitignore > "$TL_TMP/expected-gitignore"
  run_stop
  assert_exit 0 "$TL_RC"
  assert_file_exists "$gi" "the recover folder gets a .gitignore"
  assert_same_file "$gi" "$TL_TMP/expected-gitignore" ".gitignore has exactly the two lines"
  assert_eq "2" "$(wc -l < "$gi" | tr -d ' ')" "two lines, no more"
  # A second chat in the same folder must not change it.
  run_stop
  assert_exit 0 "$TL_RC"
  assert_same_file "$gi" "$TL_TMP/expected-gitignore" ".gitignore is still the same after a second write"
}

test_project_root_gitignore_is_never_created_or_touched() {
  local p; p="$(project)"
  run_stop
  assert_exit 0 "$TL_RC"
  assert_file_missing "$p/.gitignore" "the project root must not get a .gitignore"
  printf 'node_modules/\n' > "$p/.gitignore"
  cp "$p/.gitignore" "$TL_TMP/root-before"
  run_stop
  assert_same_file "$p/.gitignore" "$TL_TMP/root-before" "the project root .gitignore must stay byte for byte"
}

test_existing_gitignore_is_left_byte_for_byte() {
  local p gi; p="$(project)"; gi="$p/.handoff/.gitignore"
  mkdir -p "$p/.handoff"
  printf 'my own rule\n\n# keep this\n!LATEST.md' > "$gi"
  cp "$gi" "$TL_TMP/gitignore-before"
  run_stop
  assert_exit 0 "$TL_RC"
  assert_same_file "$gi" "$TL_TMP/gitignore-before" "an existing .gitignore must not change"
  assert_eq "1" "$(count_recovered "$p/.handoff")" "the recovered file is still written"
}

test_dangling_gitignore_link_is_not_followed() {
  local p gi target; p="$(project)"; gi="$p/.handoff/.gitignore"; target="$TL_TMP/outside/target-ignore"
  mkdir -p "$p/.handoff" "$TL_TMP/outside"
  ln -s "$target" "$gi"
  run_stop
  assert_exit 0 "$TL_RC"
  assert_file_missing "$target" "a link must not make the kit write outside the project"
  [ -L "$gi" ] || fail "the .gitignore link must be left as it was"
}

test_state_folder_fallback_gets_no_gitignore() {
  local p sd; p="$(project)"; sd="$LIMIT_HANDOFF_STATE_DIR/recovered"
  # The recover folder is a link to a folder outside the project, so the file goes to the state folder.
  mkdir -p "$TL_TMP/outside-dir"
  ln -s "$TL_TMP/outside-dir" "$p/.handoff"
  run_stop
  assert_exit 0 "$TL_RC"
  assert_eq "1" "$(count_recovered "$sd")" "the recovered file went to the state folder"
  assert_file_missing "$sd/.gitignore" "the state folder fallback must not get a .gitignore"
  assert_file_missing "$TL_TMP/outside-dir/.gitignore" "nothing may be written into the linked folder"
  assert_eq "0" "$(count_recovered "$TL_TMP/outside-dir")" "no recovered file goes into the linked folder"
}

# ---------------------------------------------------------------------------
# Pruning through the StopFailure hook
# ---------------------------------------------------------------------------

test_thirty_five_old_files_leave_the_thirty_newest() {
  local p d; p="$(project)"; d="$p/.handoff"
  make_old_recovered "$d" 35
  printf 'user notes\n' > "$d/notes.md"
  printf 'not a stamp\n' > "$d/recovered-notes.md"
  printf 'latest from before\n' > "$d/LATEST.md"
  printf 'outside\n' > "$TL_TMP/outside.md"
  ln -s "$TL_TMP/outside.md" "$d/recovered-20200101-000000-linkone.md"
  run_stop
  assert_exit 0 "$TL_RC"
  assert_eq "30" "$(count_recovered "$d")" "30 recovered files remain (29 old plus the new one)"
  assert_file_missing "$d/recovered-20200101-000001-abcdefgh.md" "the oldest file is deleted"
  assert_file_missing "$d/recovered-20200101-000006-abcdefgh.md" "the sixth oldest is deleted"
  assert_file_exists "$d/recovered-20200101-000007-abcdefgh.md" "the seventh oldest is kept"
  assert_file_exists "$d/recovered-20200101-000035-abcdefgh.md" "the newest old file is kept"
  assert_eq "1" "$(ls "$d"/recovered-*-prune-se.md 2>/dev/null | wc -l | tr -d ' ')" "the new file is kept"
  assert_file_contains "$d/notes.md" "user notes" "notes.md is untouched"
  assert_file_contains "$d/recovered-notes.md" "not a stamp" "a name without a stamp is untouched"
  assert_file_exists "$d/LATEST.md" "LATEST.md is kept"
  assert_file_exists "$d/.gitignore" "user notes folder (batch C #29, stress test M2): the folder gets a .gitignore that names only the kit's files"
  assert_file_contains "$d/.gitignore" "recovered-*.md" "user notes folder (batch C #29, stress test M2): recovered chat text stays out of git"
  if grep -qx '\*' "$d/.gitignore"; then fail "user notes folder (batch C #29, stress test M2): no * rule, it would hide the user's own files"; fi
  [ -L "$d/recovered-20200101-000000-linkone.md" ] || fail "a link with a recovered name must be left alone"
  assert_file_contains "$TL_TMP/outside.md" "outside" "the target of that link must not be deleted"
  assert_file_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "removed 6 old recovered file(s)" "the log says how many were removed"
}

test_keep_zero_keeps_every_file() {
  local p d; p="$(project)"; d="$p/.handoff"
  export LIMIT_HANDOFF_KEEP=0
  make_old_recovered "$d" 35
  run_stop
  assert_exit 0 "$TL_RC"
  assert_eq "36" "$(count_recovered "$d")" "KEEP=0 keeps all 35 old files and the new one"
  assert_file_exists "$d/recovered-20200101-000001-abcdefgh.md" "the oldest file is kept with KEEP=0"
}

test_small_keep_value_is_honoured() {
  local p d; p="$(project)"; d="$p/.handoff"
  export LIMIT_HANDOFF_KEEP=5
  make_old_recovered "$d" 35
  run_stop
  assert_exit 0 "$TL_RC"
  assert_eq "5" "$(count_recovered "$d")" "KEEP=5 leaves five files"
  assert_file_exists "$d/recovered-20200101-000035-abcdefgh.md" "the newest old file is kept"
  assert_file_missing "$d/recovered-20200101-000031-abcdefgh.md" "the fifth-newest old file is gone"
}

test_bad_keep_value_uses_the_default_of_thirty() {
  local p d; p="$(project)"; d="$p/.handoff"
  export LIMIT_HANDOFF_KEEP=abc
  make_old_recovered "$d" 35
  run_stop
  assert_exit 0 "$TL_RC"
  assert_eq "30" "$(count_recovered "$d")" "a value that is not a number means the default 30"
}

test_state_folder_fallback_is_pruned_too() {
  local p sd; p="$(project)"; sd="$LIMIT_HANDOFF_STATE_DIR/recovered"
  mkdir -p "$TL_TMP/outside-dir"
  ln -s "$TL_TMP/outside-dir" "$p/.handoff"
  export LIMIT_HANDOFF_KEEP=2
  make_old_recovered "$sd" 3
  run_stop
  assert_exit 0 "$TL_RC"
  assert_eq "2" "$(count_recovered "$sd")" "the state folder keeps two files too"
  assert_file_missing "$sd/recovered-20200101-000001-abcdefgh.md" "the oldest state file is deleted"
}

# ---------------------------------------------------------------------------
# hk_prune_recovered on its own
# ---------------------------------------------------------------------------

test_prune_protects_the_named_file_and_counts_it() {
  load_common
  local d="$TL_TMP/prune-named"
  make_old_recovered "$d" 5
  printf 'new\n' > "$d/recovered-20261030-101010-keepme.md"
  hk_prune_recovered "$d" 3 "recovered-20261030-101010-keepme.md"
  assert_eq "3" "$(count_recovered "$d")" "three files remain, the named one included"
  assert_file_missing "$d/recovered-20200101-000003-abcdefgh.md" "the oldest three are deleted"
  assert_file_exists "$d/recovered-20200101-000004-abcdefgh.md" "the fourth is kept"
  assert_file_exists "$d/recovered-20261030-101010-keepme.md" "the named file is never deleted"
}

test_prune_only_touches_names_that_match_the_pattern() {
  load_common
  local d="$TL_TMP/prune-pattern"
  make_old_recovered "$d" 3
  # A precompact snapshot matches the pattern, so it is the oldest and goes first.
  printf 'snap\n' > "$d/recovered-20200101-000000-abcdefgh-precompact.md"
  # Too long a session part, a stray suffix and plain names do not match.
  printf 'long\n' > "$d/recovered-20200101-000009-abcdefghi.md"
  printf 'bak\n' > "$d/recovered-20200101-000009-abcdefgh.md.bak"
  printf 'notes\n' > "$d/notes.md"
  printf 'plain\n' > "$d/recovered-notes.md"
  printf 'gitignore\n' > "$d/.gitignore"
  printf 'latest\n' > "$d/LATEST.md"
  ln -s "$TL_TMP/prune-target.md" "$d/recovered-20200101-000008-linkone.md"
  printf 'target\n' > "$TL_TMP/prune-target.md"
  hk_prune_recovered "$d" 2 ""
  # Snapshots have their own count (batch D #56): one snapshot is within its limit, so it stays.
  assert_eq "3" "$(count_recovered "$d")" "two normal files and the one snapshot remain"
  assert_file_exists "$d/recovered-20200101-000000-abcdefgh-precompact.md" "the snapshot is within its own count"
  assert_file_missing "$d/recovered-20200101-000001-abcdefgh.md" "the oldest normal file is deleted"
  assert_file_exists "$d/recovered-20200101-000003-abcdefgh.md" "the newest normal file is kept"
  assert_file_contains "$d/recovered-20200101-000009-abcdefghi.md" "long" "a name with a 9 character session part is untouched"
  assert_file_contains "$d/recovered-20200101-000009-abcdefgh.md.bak" "bak" "a backup name is untouched"
  assert_file_contains "$d/notes.md" "notes" "notes.md is untouched"
  assert_file_contains "$d/recovered-notes.md" "plain" "recovered-notes.md is untouched"
  assert_file_contains "$d/.gitignore" "gitignore" ".gitignore is untouched"
  assert_file_contains "$d/LATEST.md" "latest" "LATEST.md is untouched"
  [ -L "$d/recovered-20200101-000008-linkone.md" ] || fail "a link with a matching name is untouched"
  assert_file_contains "$TL_TMP/prune-target.md" "target" "the link target is untouched"
}

test_prune_does_nothing_for_zero_bad_or_missing_values() {
  load_common
  local d="$TL_TMP/prune-noop"
  make_old_recovered "$d" 4
  hk_prune_recovered "$d" 0 ""
  assert_eq "4" "$(count_recovered "$d")" "keep 0 removes nothing"
  hk_prune_recovered "$d" "" ""
  assert_eq "4" "$(count_recovered "$d")" "an empty keep value removes nothing"
  hk_prune_recovered "$d" "x1" ""
  assert_eq "4" "$(count_recovered "$d")" "a keep value that is not a number removes nothing"
  hk_prune_recovered "$TL_TMP/no-such-folder" 2 ""
  assert_eq "0" "$(count_recovered "$TL_TMP/no-such-folder")" "a missing folder is fine"
}

run_tests
