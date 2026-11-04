#!/bin/bash
# Tests for the fixes from the full test of the public repo (2026-11-04): more secret shapes
# redacted (also in the git commit line), a reminder filter whose time grows in step with the
# text, no finished step handed out as the next one, no files from empty or broken hook input,
# a closed stdin, a CLI run through a symlink, a project folder whose name starts with "-",
# dangling and read-only settings files, and a temp file that cannot be redirected by a link.
# See docs/DECISIONS.md 189-197.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_common() {
  . "$TL_ROOT/lib/common.sh"
  HK_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
}

# user_line text: one main-chat user line of a transcript, as JSON.
user_line() {
  jq -nc --arg t "$1" '{type: "user", isSidechain: false, message: {role: "user", content: $t}}'
}

# bash_line command: one assistant line with a Bash tool call, as JSON.
bash_line() {
  jq -nc --arg c "$1" '{type: "assistant", isSidechain: false,
    message: {role: "assistant", content: [{type: "tool_use", id: "t1", name: "Bash",
      input: {command: $c, description: "run it"}}]}}'
}

# --- F1: more secret shapes are redacted --------------------------------------

test_f1_common_secret_shapes_are_redacted() {
  local p="$CLAUDE_PROJECT_DIR" t="$TL_TMP/sec.jsonl" aws stripe goog npm pem jwt
  # The fake secrets are built at run time, so no whole token-shaped string sits in this file.
  aws="wJalrXUtnFEMI/K7MDENG/bPxRfi""CYEXAMPLEKEY"
  stripe="sk_live_""a1B2c3D4e5F6g7H8i9J0k1L2"
  goog="AIza""SyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p"
  npm="npm_""aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC1dE3fG5"
  pem="3OyV2dZAkg05rK+gqv81RKMGHZEM9YpvujA/C5Q52ryFlwRlOEVHzc0X0AWIRh/J"
  jwt="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
  {
    user_line "deploy with $aws and $stripe and $goog and $npm"
    user_line "db is postgres://app:SuperSecretPw9@db.example.invalid/x and password=hunter2 and $jwt"
    user_line '{"api_key": "abc123xyz789", "client_secret":"zzTopSecret1"} Authorization: Bearer abcdefghijklmnop1234'
    bash_line "printf '%s\n' '-----BEGIN PRIVATE KEY-----' '$pem' '-----END PRIVATE KEY-----' > k.pem"
    bash_line "echo $pem"
  } > "$t"
  tl_kit recover --transcript "$t" --dir "$p" --stdout
  assert_exit 0 "$TL_RC"
  local s
  for s in "$aws" "$stripe" "$goog" "$npm" "SuperSecretPw9" "hunter2" "$jwt" "abc123xyz789" "zzTopSecret1" \
           "abcdefghijklmnop1234" "$pem" "3OyV2dZAkg05rK"; do
    assert_not_contains "$TL_OUT" "$s" "secret shown: ${s:0:12}..."
  done
  assert_contains "$TL_OUT" "postgres://app:[redacted]@db.example.invalid/x" "the URL is kept, only the password goes"
  assert_contains "$TL_OUT" "password=[redacted]" "the name is kept, only the value goes"
  assert_contains "$TL_OUT" "Bearer [redacted]" "the Bearer word is kept"
}

test_f1_paths_links_and_plain_words_are_not_redacted() {
  local p="$CLAUDE_PROJECT_DIR" t="$TL_TMP/plain.jsonl" a b c
  a="Edit /Users/me/code/my-shop/backend/lib/common.sh and src/components/ProductCard/index.tsx"
  b="Fix the password reset flow. The token: is wrong. See https://github.com/example/limit-handoff/blob/main/README.md"
  c="tokens: 5, secret sauce, password_reset_url, api-keys, git clone git@github.com:user/repo.git"
  { user_line "$a"; user_line "$b"; user_line "$c"; } > "$t"
  tl_kit recover --transcript "$t" --dir "$p" --stdout
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "$a" "paths are kept"
  assert_contains "$TL_OUT" "$b" "links and prose are kept"
  assert_contains "$TL_OUT" "$c" "secret-like words without a value are kept"
  assert_not_contains "$TL_OUT" "[redacted]" "nothing was redacted"
}

test_f1_git_commit_subject_is_redacted() {
  local p="$CLAUDE_PROJECT_DIR" key
  key="AKIA""IOSFODNN7EXAMPLE"
  git -C "$p" init -q
  printf 'a\n' > "$p/a.txt"
  git -C "$p" add a.txt
  git -C "$p" -c user.name="Test User" -c user.email=test@example.invalid commit -qm "Rotate key $key now"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "f1-git" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_exit 0 "$TL_RC"
  local rec
  rec="$(ls "$p"/.handoff/recovered-*.md | head -n 1)"
  assert_file_contains "$rec" "Rotate key [redacted] now" "the subject is shown with the key hidden"
  assert_file_not_contains "$rec" "$key" "the key is not in the recovered file"
}

test_f1_redact_line_uses_the_transcript_rules() {
  load_common
  assert_eq "key [redacted] end" "$(hk_redact_line "key sk-""ant-api03-abcdefghijklmnopqrstuvwxyz end")"
  assert_eq "plain words stay" "$(hk_redact_line "plain words stay")"
}

# --- F2: the reminder filter keeps up with long prompts ---------------------

test_f2_many_unclosed_reminder_tags_are_fast() {
  local p="$CLAUDE_PROJECT_DIR" t="$TL_TMP/rem.jsonl" start end limit
  # Written by perl, not passed as an argument: 800 KB is close to the argument size limit.
  perl -e 'print "{\"type\":\"user\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":\"" . ("<system-reminder> x " x 40000) . "\"}}\n"' > "$t"
  user_line "the real prompt" >> "$t"
  limit="$(tl_time_limit 5)"
  start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  tl_kit recover --transcript "$t" --dir "$p" --stdout
  end="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "the real prompt" "the next prompt is still found"
  perl -e "exit(($end - $start) < $limit ? 0 : 1)" || fail "800 KB of unclosed tags took $(perl -e "print $end - $start") s (limit $limit s)"
}

test_f2_reminder_sections_are_removed_like_before() {
  local d
  d="$(sed -n '/^def strip_reminders:/,/end);$/p' "$TL_ROOT/lib/transcript.jq")"
  sr() { jq -nr --arg s "$1" "$d"$'\n''$s | strip_reminders'; }
  assert_eq "A  B  C <system-reminder>open" \
    "$(sr "A <system-reminder>r1</system-reminder> B <system-reminder> x <system-reminder> y </system-reminder> C <system-reminder>open")" \
    "a section runs to the first closing tag; a last unclosed tag stays"
  assert_eq "b</system-reminder>c" "$(sr "<system-reminder>a</system-reminder>b</system-reminder>c")" "a second closing tag is text"
  assert_eq "x</system-reminder>y" "$(sr "x</system-reminder>y")" "a closing tag alone is text"
  assert_eq "ü typed" "$(sr "<system-reminder>é</system-reminder>ü typed")" "non-English letters are cut in the right place"
  assert_eq "" "$(sr "<system-reminder>only</system-reminder>")"
}

# --- F3: a finished step is never the next step ------------------------------

test_f3_all_finished_steps_give_no_next_step() {
  local p="$CLAUDE_PROJECT_DIR"
  printf '%s\n' '# H' '' '## Next steps' '1. [x] Set up CI' '2. [x] Write docs' > "$p/HANDOFF.md"
  load_common
  assert_eq "" "$(hk_first_next_step "$p/HANDOFF.md")" "every item is finished"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "f3-done" "$(tl_fixture basic.jsonl)" "$p" "rate_limit")"
  assert_file_not_contains "$p/PASTE-PROMPT.txt" "start with: Set up CI" "a finished step is not handed out"
  assert_file_contains "$p/PASTE-PROMPT.txt" "work out the next step" "Claude is asked to work it out"
}

test_f3_first_unfinished_item_of_any_kind_is_the_next_step() {
  local f="$TL_TMP/hf.md"
  load_common
  printf '%s\n' '## Next steps' '1. [x] Set up CI' '2. Write docs' > "$f"
  assert_eq "Write docs" "$(hk_first_next_step "$f")" "a plain item after a finished one"
  printf '%s\n' '## Next steps' '- [x] Done box' '- [~] Half box' > "$f"
  assert_eq "Half box" "$(hk_first_next_step "$f")" "a half-done item after a finished one"
}

# --- F4: empty, broken or closed input writes nothing ------------------------

test_f4_empty_or_broken_input_writes_nothing_in_the_current_folder() {
  local here="$TL_TMP/shell-folder" h
  mkdir -p "$here"
  unset CLAUDE_PROJECT_DIR
  for h in "$TL_HOOK_STOP" "$TL_ROOT/hooks/pre-compact.sh"; do
    ( cd "$here" && printf '' | /bin/bash "$h" ) || fail "rc $? for empty input to $h"
    ( cd "$here" && printf '{broken' | /bin/bash "$h" ) || fail "rc $? for broken input to $h"
    ( cd "$here" && printf '[1,2]' | /bin/bash "$h" ) || fail "rc $? for a JSON list to $h"
  done
  assert_eq "" "$(ls -A "$here")" "nothing was written in the shell's folder"
  assert_file_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "input is empty or not a JSON object; nothing written"
}

test_f4_a_closed_stdin_does_not_wait_for_the_timeout() {
  local h rc
  # The hook's output goes to files: with the old code, a cat stuck on its own pipe outlived the
  # killed hook and held any pipe the hook wrote to, so the test run itself would hang.
  for h in stop-failure prompt-submit session-start pre-compact; do
    perl -e 'alarm 10; exec @ARGV' /bin/bash -c 'cd "$2" && exec /bin/bash "$1" <&- >"$2/cs.out" 2>"$2/cs.err"' _ "$TL_ROOT/hooks/$h.sh" "$TL_TMP"
    rc=$?
    assert_eq 0 "$rc" "$h with a closed stdin (142 means it was still waiting after 10 s)"
  done
}

# --- F5: the command line tool through a symlink -----------------------------

test_f5_cli_runs_through_a_symlink_and_a_chain_of_links() {
  mkdir -p "$TL_TMP/bin" "$TL_TMP/other"
  ln -s "$TL_ROOT/bin/limit-handoff" "$TL_TMP/other/lh-real-link"
  ln -s ../other/lh-real-link "$TL_TMP/bin/limit-handoff"
  local out
  out="$(cd / && /bin/bash "$TL_TMP/bin/limit-handoff" --version 2>&1)"
  assert_eq "limit-handoff $(tl_hk_version)" "$out" "a relative link to a link works"
}

# --- F6: a project folder whose name starts with "-" ------------------------

test_f6_dir_starting_with_a_dash_is_used_as_a_folder() {
  mkdir -p "$TL_TMP/-rf" "$TL_TMP/-"
  tl_kit prompt --dir -rf --no-copy
  assert_exit 0 "$TL_RC"
  assert_file_exists "$TL_TMP/-rf/PASTE-PROMPT.txt"
  assert_not_contains "$TL_ERR" "invalid option"
  tl_kit status --dir -
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "$TL_TMP/-" "a folder named - is not the previous folder"
}

# --- F7: settings files that must not be written ------------------------------

test_f7_dangling_settings_link_is_refused() {
  ln -s "$TL_TMP/nowhere.json" "$TL_TMP/dang.json"
  tl_kit install --settings "$TL_TMP/dang.json"
  assert_exit 1 "$TL_RC"
  assert_contains "$TL_ERR" "dangling link"
  assert_file_missing "$TL_TMP/nowhere.json"
}

test_f7_read_only_settings_file_is_not_replaced() {
  local f="$TL_TMP/ro.json"
  printf '{"model":"opus"}\n' > "$f"
  chmod 444 "$f"
  tl_kit install --settings "$f"
  assert_exit 1 "$TL_RC"
  assert_contains "$TL_ERR" "read-only"
  assert_eq '{"model":"opus"}' "$(cat "$f")" "the file is unchanged"
  assert_eq "" "$(find "$TL_TMP" -maxdepth 1 -name 'ro.json.bak-*')" "no backup is made for a refused change"
  tl_kit install --settings "$f" --dry-run
  assert_exit 0 "$TL_RC"
  chmod 644 "$f"
}

# --- F8: the temp file of a write cannot be redirected -------------------------

test_f8_planted_link_at_the_old_temp_name_is_not_followed() {
  local p="$CLAUDE_PROJECT_DIR"
  load_common
  mkdir -p "$TL_TMP/outside"
  # The old code wrote to "<file>.tmp.<pid>". A link planted there must not get the text.
  ln -s "$TL_TMP/outside/victim" "$p/PASTE-PROMPT.txt.tmp.$$"
  printf 'hello\n' | hk_atomic_write "$p/PASTE-PROMPT.txt" || fail "the write failed"
  assert_file_missing "$TL_TMP/outside/victim"
  assert_eq "hello" "$(cat "$p/PASTE-PROMPT.txt")"
  [ ! -L "$p/PASTE-PROMPT.txt" ] || fail "the file became a link"
  assert_eq 1 "$(find "$p" -maxdepth 1 -name '*.tmp.*' | wc -l | tr -d ' ')" "only the planted link is left, no temp file"
}

test_f8_new_file_gets_the_umask_mode() {
  local p="$CLAUDE_PROJECT_DIR"
  load_common
  ( umask 022; printf 'a\n' | hk_atomic_write "$p/new-022.txt" )
  ( umask 077; printf 'a\n' | hk_atomic_write "$p/new-077.txt" )
  assert_eq 644 "$(tl_file_mode "$p/new-022.txt")"
  assert_eq 600 "$(tl_file_mode "$p/new-077.txt")"
}

run_tests
