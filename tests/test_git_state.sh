#!/bin/bash
# Tests for the repository section from git (hk_git_state in lib/common.sh, used by the
# recovered file). Every repository is made inside the temp folder of the test. The identity is
# fixed by environment variables, and no global or system git config is read (HOME and the XDG
# folders are temp folders, and GIT_CONFIG_NOSYSTEM=1). If git is not installed, every test in
# this file passes at once.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# have_git: true when git is on PATH.
have_git() { command -v git >/dev/null 2>&1; }

# gt_env: a fixed identity, no system config, and a ceiling so git never looks above the temp folder.
gt_env() {
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="Test User" GIT_AUTHOR_EMAIL="test@example.invalid"
  export GIT_COMMITTER_NAME="Test User" GIT_COMMITTER_EMAIL="test@example.invalid"
  export GIT_CEILING_DIRECTORIES="$TL_TMP"
}

# gt_repo dir: makes an empty repository whose branch is main.
gt_repo() {
  mkdir -p "$1"
  git -C "$1" init -q </dev/null || fail "git init failed in $1"
  git -C "$1" symbolic-ref HEAD refs/heads/main </dev/null || fail "could not name the branch in $1"
}

# gt_commit dir message: stages everything and commits it.
gt_commit() {
  git -C "$1" add -A </dev/null || fail "git add failed in $1"
  git -C "$1" -c commit.gpgsign=false commit -q -m "$2" </dev/null || fail "git commit failed in $1"
}

# gt_repo_with_one_commit dir: a repository with README.txt committed.
gt_repo_with_one_commit() {
  gt_repo "$1"
  printf 'hello\n' > "$1/README.txt"
  gt_commit "$1" "first commit"
}

# gt_section dir: prints what hk_git_state prints for dir (empty when there is no section).
gt_section() {
  (
    . "$TL_ROOT/lib/common.sh"
    HK_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
    hk_git_state "$1"
  )
}

# gt_count_line text line: how many lines of text are exactly this line.
gt_count_line() { printf '%s\n' "$1" | grep -c -x -F -- "$2"; }

# gt_run_stop sid: a StopFailure for the project folder, with the basic fixture transcript.
gt_run_stop() {
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "$1" "$(tl_fixture basic.jsonl)" "$CLAUDE_PROJECT_DIR" "rate_limit")"
}

# gt_recovered: the newest recovered file in the project folder.
gt_recovered() {
  ls -t "$CLAUDE_PROJECT_DIR/.handoff"/recovered-*.md 2>/dev/null | head -n 1
}

test_clean_repo_gives_branch_commit_and_no_changes() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" out
  gt_repo_with_one_commit "$d"
  out="$(gt_section "$d")"
  assert_contains "$out" "## Repository state (from git, when this file was made)"
  assert_contains "$out" "- Branch: main"
  assert_contains "$out" "- Last commit: "
  assert_contains "$out" "first commit"
  assert_contains "$out" "- Changes: no changes against the last commit"
  assert_contains "$out" "The working tree is clean"
  assert_not_contains "$out" '```' "a clean tree has no code block"
}

test_modified_and_untracked_files_are_listed_in_a_fence() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" out
  gt_repo_with_one_commit "$d"
  printf 'hello\nmore\n' > "$d/README.txt"
  printf 'new\n' > "$d/notes.txt"
  out="$(gt_section "$d")"
  assert_contains "$out" "- Changes: 1 file changed, 1 insertion(+)"
  assert_contains "$out" " M README.txt"
  assert_contains "$out" "?? notes.txt"
  assert_eq "2" "$(gt_count_line "$out" '````')" "the code block opens and closes with four backticks"
}

test_repo_without_commits_says_so() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" out
  gt_repo "$d"
  printf 'draft\n' > "$d/draft.txt"
  out="$(gt_section "$d")"
  assert_contains "$out" "- Branch: No commits yet on main"
  assert_contains "$out" "- Last commit: (no commits yet)"
  assert_contains "$out" "no diff summary, because there are no commits yet"
  assert_contains "$out" "?? draft.txt"
}

test_folder_that_is_not_a_repo_gives_no_section() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" rec
  printf 'plain\n' > "$d/plain.txt"
  assert_eq "" "$(gt_section "$d")" "no section outside a repository"
  assert_eq "" "$(gt_section "$TL_TMP/does-not-exist")" "no section for a missing folder"
  gt_run_stop "norepo-sess"
  assert_exit 0 "$TL_RC"
  rec="$(gt_recovered)"
  assert_file_exists "$rec"
  assert_file_not_contains "$rec" "## Repository state" "the hook must leave the section out"
}

test_limit_handoff_git_zero_turns_the_section_off() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" rec
  gt_repo_with_one_commit "$d"
  printf 'hello\nmore\n' > "$d/README.txt"
  export LIMIT_HANDOFF_GIT=0
  assert_eq "" "$(gt_section "$d")" "LIMIT_HANDOFF_GIT=0 in the environment"
  unset LIMIT_HANDOFF_GIT
  mkdir -p "$XDG_CONFIG_HOME/limit-handoff"
  printf 'LIMIT_HANDOFF_GIT=off\n' > "$XDG_CONFIG_HOME/limit-handoff/config"
  assert_eq "" "$(gt_section "$d")" "LIMIT_HANDOFF_GIT=off in the user file"
  rm -f "$XDG_CONFIG_HOME/limit-handoff/config"
  export LIMIT_HANDOFF_GIT=0
  gt_run_stop "gitoff-sess"
  assert_exit 0 "$TL_RC"
  rec="$(gt_recovered)"
  assert_file_exists "$rec"
  assert_file_not_contains "$rec" "## Repository state" "no section when the setting is 0"
}

test_more_than_thirty_changes_show_thirty_and_a_count() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" out i=1
  gt_repo_with_one_commit "$d"
  while [ "$i" -le 40 ]; do
    printf 'x\n' > "$d/file-$i.txt"
    i=$((i + 1))
  done
  out="$(gt_section "$d")"
  assert_eq "30" "$(printf '%s\n' "$out" | grep -c '^?? file-')" "only 30 status lines are shown"
  assert_contains "$out" "... and 10 more"
}

test_fsmonitor_program_in_repo_config_is_not_run() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" out
  gt_repo_with_one_commit "$d"
  printf '#!/bin/sh\ntouch "%s/ran-fsmonitor"\nexit 0\n' "$TL_TMP" > "$TL_TMP/fsmonitor.sh"
  chmod +x "$TL_TMP/fsmonitor.sh"
  git -C "$d" config core.fsmonitor "$(tl_shq "$TL_TMP/fsmonitor.sh")" </dev/null || fail "could not set core.fsmonitor"
  printf 'hello\nmore\n' > "$d/README.txt"
  # Control: plain git runs the program, so the marker proves the check can see a run.
  git -C "$d" status --porcelain=v1 </dev/null >/dev/null 2>&1
  assert_file_exists "$TL_TMP/ran-fsmonitor" "control: plain git status should run the fsmonitor program"
  rm -f "$TL_TMP/ran-fsmonitor"
  out="$(gt_section "$d")"
  assert_file_missing "$TL_TMP/ran-fsmonitor" "hk_git_state must not run the fsmonitor program"
  assert_contains "$out" " M README.txt"
}

test_filter_driver_in_repo_config_is_not_run() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" out
  gt_repo "$d"
  printf 'hello\n' > "$d/tracked.txt"
  gt_commit "$d" "first commit"
  printf 'tracked.txt filter=evil\n' > "$d/.gitattributes"
  gt_commit "$d" "add attributes"
  printf '#!/bin/sh\ntouch "%s/ran-filter"\ncat\n' "$TL_TMP" > "$TL_TMP/filter.sh"
  chmod +x "$TL_TMP/filter.sh"
  git -C "$d" config filter.evil.clean "$(tl_shq "$TL_TMP/filter.sh")" </dev/null || fail "could not set the filter"
  printf 'changed\n' >> "$d/tracked.txt"
  # Control: plain git diff runs the clean filter, so the marker proves the check can see a run.
  git -C "$d" diff --stat HEAD </dev/null >/dev/null 2>&1
  assert_file_exists "$TL_TMP/ran-filter" "control: plain git diff should run the clean filter"
  rm -f "$TL_TMP/ran-filter"
  out="$(gt_section "$d")"
  assert_file_missing "$TL_TMP/ran-filter" "hk_git_state must not run a filter driver"
  assert_contains "$out" " M tracked.txt"
}

test_textconv_and_external_diff_in_repo_config_are_not_run() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" out
  gt_repo "$d"
  printf 'hello\n' > "$d/tracked.txt"
  gt_commit "$d" "first commit"
  printf 'tracked.txt diff=evil\n' > "$d/.gitattributes"
  gt_commit "$d" "add attributes"
  printf '#!/bin/sh\ntouch "%s/ran-textconv"\ncat "$1"\n' "$TL_TMP" > "$TL_TMP/textconv.sh"
  chmod +x "$TL_TMP/textconv.sh"
  git -C "$d" config diff.evil.textconv "$(tl_shq "$TL_TMP/textconv.sh")" </dev/null || fail "could not set textconv"
  printf 'changed\n' >> "$d/tracked.txt"
  # Control: a plain patch diff runs the textconv program.
  git -C "$d" diff HEAD </dev/null >/dev/null 2>&1
  assert_file_exists "$TL_TMP/ran-textconv" "control: plain git diff should run the textconv program"
  rm -f "$TL_TMP/ran-textconv"
  printf '#!/bin/sh\ntouch "%s/ran-external"\nexit 0\n' "$TL_TMP" > "$TL_TMP/external.sh"
  chmod +x "$TL_TMP/external.sh"
  git -C "$d" config diff.external "$(tl_shq "$TL_TMP/external.sh")" </dev/null || fail "could not set diff.external"
  # Control: with an external diff set, a plain patch diff runs that program.
  git -C "$d" diff HEAD </dev/null >/dev/null 2>&1
  assert_file_exists "$TL_TMP/ran-external" "control: plain git diff should run the external diff program"
  rm -f "$TL_TMP/ran-external"
  out="$(gt_section "$d")"
  assert_file_missing "$TL_TMP/ran-textconv" "hk_git_state must not run textconv"
  assert_file_missing "$TL_TMP/ran-external" "hk_git_state must not run the external diff"
  assert_contains "$out" " M tracked.txt"
}

test_odd_file_names_stay_literal_inside_the_fence() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" out n1 n2 n3
  gt_repo_with_one_commit "$d"
  n1='odd`name`.txt'
  n2='$(touch pwn-name).txt'
  n3='four````ticks.txt'
  printf 'a\n' > "$d/$n1"
  printf 'b\n' > "$d/$n2"
  printf 'c\n' > "$d/$n3"
  out="$(gt_section "$d")"
  assert_contains "$out" "?? $n1" "a backtick name is shown as it is"
  # Git puts double quotes around a name with "$" in it. The name itself must still be literal.
  assert_contains "$out" "$n2" "a name with \$(...) is shown as it is"
  assert_contains "$out" "?? $n3"
  assert_file_missing "$d/pwn-name" "a file name must never run"
  assert_file_missing "$TL_TMP/pwn-name" "a file name must never run"
  assert_eq "2" "$(gt_count_line "$out" '`````')" "the fence is five backticks, longer than the four in a name"
}

test_branch_name_with_backticks_is_shown_with_apostrophes() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" out
  gt_repo_with_one_commit "$d"
  git -C "$d" branch -m 'feat`x`' </dev/null || fail "could not rename the branch"
  out="$(gt_section "$d")"
  assert_contains "$out" "- Branch: feat'x'" "backticks in the branch become apostrophes"
  assert_not_contains "$out" "feat\`x\`" "the branch text must not keep backticks"
}

test_commit_subject_is_cut_to_120_characters() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" out line subj
  gt_repo "$d"
  printf 'a\n' > "$d/a.txt"
  subj="$(printf '%0130d' 0 | tr 0 q)"
  gt_commit "$d" "$subj"
  out="$(gt_section "$d")"
  line="$(printf '%s\n' "$out" | grep '^- Last commit: ')"
  assert_eq "120" "$(printf '%s' "$line" | tr -cd 'q' | wc -c | tr -d ' ')" "only 120 characters of the subject are shown"
}

test_recovered_file_has_the_section_between_files_and_commands() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" rec files_line repo_line last_line
  gt_repo_with_one_commit "$d"
  printf 'hello\nmore\n' > "$d/README.txt"
  gt_run_stop "git-sess"
  assert_exit 0 "$TL_RC"
  rec="$(gt_recovered)"
  assert_file_exists "$rec"
  assert_file_contains "$rec" "## Repository state (from git, when this file was made)"
  assert_file_contains "$rec" "- Branch: main"
  assert_file_contains "$rec" " M README.txt"
  files_line="$(grep -n '^## Files touched' "$rec" | head -n 1 | cut -d: -f1)"
  repo_line="$(grep -n '^## Repository state' "$rec" | head -n 1 | cut -d: -f1)"
  last_line="$(grep -n '^## Last commands' "$rec" | head -n 1 | cut -d: -f1)"
  [ -n "$files_line" ] && [ -n "$repo_line" ] && [ -n "$last_line" ] || fail "a heading is missing in $rec"
  [ "$files_line" -lt "$repo_line" ] && [ "$repo_line" -lt "$last_line" ] \
    || fail "the section must sit between Files touched and Last commands"
}

test_without_git_on_path_the_section_is_left_out_and_the_hook_exits_zero() {
  have_git || return 0
  gt_env
  local d="$CLAUDE_PROJECT_DIR" rec jqpath nogit f n
  gt_repo_with_one_commit "$d"
  printf 'hello\nmore\n' > "$d/README.txt"
  # A folder of links to every system tool except git (and jq, which the hook needs).
  jqpath="$(command -v jq)"
  nogit="$TL_TMP/nogit-bin"
  mkdir -p "$nogit"
  for dd in /bin /usr/bin; do
    for f in "$dd"/*; do
      n="${f##*/}"
      case "$n" in
        git|jq) continue ;;
      esac
      if [ -x "$f" ] && [ ! -d "$f" ] && [ ! -e "$nogit/$n" ]; then ln -s "$f" "$nogit/$n" 2>/dev/null; fi
    done
  done
  ln -s "$jqpath" "$nogit/jq" || fail "could not link jq"
  export PATH="$TL_SHIMS:$nogit"
  assert_eq "" "$(command -v git)" "git must not be found for this test"
  gt_run_stop "nogit-sess"
  assert_exit 0 "$TL_RC"
  rec="$(gt_recovered)"
  assert_file_exists "$rec" "the recovered file is still written"
  assert_file_not_contains "$rec" "## Repository state" "no section without git"
  assert_file_contains "$rec" "## Last commands" "the other sections are still there"
  assert_file_exists "$d/PASTE-PROMPT.txt"
}

test_render_puts_the_given_section_before_last_commands() {
  local j md md_none
  . "$TL_ROOT/lib/common.sh"
  HK_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
  j="$(hk_recover_json "$(tl_fixture basic.jsonl)" 5)"
  md="$(hk_render_recovered "$j" "sess" "rate_limit" "usage limit reached" "/t.jsonl" "" "" \
    "$(printf '%s\n' '## Repository state (from git, when this file was made)' '' '- Branch: main')")"
  assert_contains "$md" "## Repository state (from git, when this file was made)"
  assert_contains "$md" "- Branch: main"
  md_none="$(hk_render_recovered "$j" "sess" "rate_limit" "usage limit reached" "/t.jsonl" "")"
  assert_not_contains "$md_none" "## Repository state" "no section when none is given"
}

if ! command -v git >/dev/null 2>&1; then
  echo "  SKIP: git is not installed. The git tests in this file pass without running."
fi
run_tests
