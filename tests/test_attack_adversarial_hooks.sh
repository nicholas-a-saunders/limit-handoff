#!/bin/bash
# Adversarial tests: inputs chosen to break the kit.
# Area: hook robustness. Bad stdin, missing jq, huge transcripts, odd paths, read-only folders.
# Rules come from docs/SPEC.md.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# adv_big_transcript file lines: a valid transcript with many lines (prompts, edits, results).
adv_big_transcript() {
  perl -e 'for my $i (1..'"$2"'){ if($i%3==0){print qq({"type":"user","message":{"role":"user","content":"prompt number $i with some words here"}}\n)} elsif($i%3==1){print qq({"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reply $i"},{"type":"tool_use","id":"t$i","name":"Edit","input":{"file_path":"/w/f$i.py"}}]}}\n)} else {print qq({"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t$i","content":"ok $i"}]}}\n)} }' > "$1"
}

# adv_timed_stop payload_file: runs the StopFailure hook with the file on stdin.
# Sets TL_RC (exit status) and ADV_SECS (seconds taken). Not called inside $( ).
adv_timed_stop() {
  local start end
  start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  /bin/bash "$TL_HOOK_STOP" < "$1" >/dev/null 2>&1
  TL_RC=$?
  end="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  ADV_SECS="$(perl -e "printf '%.3f', $end - $start")"
}

# adv_alive pid: succeeds when the process runs (a finished, unreaped zombie does not count).
adv_alive() {
  local st
  st="$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')"
  case "$st" in
    ""|Z*) return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Bad stdin. SPEC "Hard constraints": a hook must never die half way and must exit 0.
# ---------------------------------------------------------------------------

test_every_hook_exits_zero_on_bad_stdin() {
  local h input big n=0 rc
  big="$(perl -e 'print "{" . ("x" x 2000000)')"
  for h in "$TL_HOOK_STOP" "$TL_HOOK_PROMPT" "$TL_HOOK_SESSION" "$TL_HOOK_COMPACT"; do
    for input in "" "not json at all" "[1,2,3]" '"just a string"' "null" '{"cwd":5' \
                 '{"session_id":{"a":1},"error":["rate_limit"],"transcript_path":{"x":1},"cwd":null}' \
                 '{"hook_event_name":"StopFailure","error":"rate_limit","transcript_path":12}' "$big"; do
      printf '%s' "$input" | /bin/bash "$h" >/dev/null 2>&1
      rc=$?
      n=$((n + 1))
      assert_eq "0" "$rc" "hook $(basename "$h") exited $rc on bad stdin (first 40 chars: ${input:0:40})"
    done
  done
  assert_eq "36" "$n" "every hook and input pair must be tried"
}

# ---------------------------------------------------------------------------
# Missing jq. SPEC "Dependencies": without jq, still write the cut-off marker and a basic prompt.
# ---------------------------------------------------------------------------

test_stop_failure_without_jq_writes_marker_and_paste_prompt() {
  local p="$CLAUDE_PROJECT_DIR" payload
  printf '%s\n' '# My handoff' '' '## Next steps' '1. Finish the parser' > "$p/HANDOFF.md"
  payload="$(tl_payload_stop "nojq-sess" "$TL_FIX/basic.jsonl" "$p" rate_limit)"
  tl_use_nojq
  tl_run "$TL_HOOK_STOP" "$payload"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" 'session="nojq-sess"' "the cut-off marker must still be written"
  assert_file_contains "$p/PASTE-PROMPT.txt" "Finish the parser" "the paste prompt must still name the next step"
  assert_file_contains "$p/PASTE-PROMPT.txt" "$p" "the paste prompt must name the project folder"
}

test_prompt_and_session_hooks_show_the_cut_off_without_jq() {
  local p="$CLAUDE_PROJECT_DIR" pp ps
  printf '%s\n' '# H' '' '<!-- limit-handoff:cutoff session="old1" at="2026-10-28 10:00" error="rate_limit" status="unresolved" -->' \
    '> ⚠️ **Session cut off** (usage limit reached) at 2026-10-28 10:00. Old.' \
    '> Check the files. Recovered context: `.handoff/recovered-old.md`' \
    '<!-- /limit-handoff:cutoff -->' > "$p/HANDOFF.md"
  pp="$(tl_payload_plain UserPromptSubmit "s9" "$p" "")"
  ps="$(tl_payload_plain SessionStart "s9" "$p" "startup")"
  tl_use_nojq
  tl_run "$TL_HOOK_PROMPT" "$pp"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "unresolved cut-off" "prompt hook must warn about the cut-off without jq"
  tl_run "$TL_HOOK_SESSION" "$ps"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "unresolved cut-off" "session hook must warn about the cut-off without jq"
}

test_pre_compact_without_jq_still_writes_a_snapshot() {
  local p="$CLAUDE_PROJECT_DIR" payload
  payload="$(tl_payload_plain PreCompact "pc-nojq" "$p" "")"
  tl_use_nojq
  tl_run "$TL_HOOK_COMPACT" "$payload"
  assert_exit 0 "$TL_RC"
  if [ -z "$(ls "$p/.handoff"/recovered-*precompact.md 2>/dev/null)" ]; then
    fail "pre-compact without jq wrote no snapshot file"
  fi
}

# ---------------------------------------------------------------------------
# Speed. SPEC "Hard constraints": StopFailure finishes < 2 s, reads only the tail.
# ---------------------------------------------------------------------------

test_sixty_thousand_line_transcript_finishes_under_two_seconds() {
  local p="$CLAUDE_PROJECT_DIR" f="$TL_TMP/sixty.jsonl" ok rec
  adv_big_transcript "$f" 60000
  printf '%s' "$(tl_payload_stop "big60" "$f" "$p" rate_limit)" > "$TL_TMP/big60.payload"
  adv_timed_stop "$TL_TMP/big60.payload"
  assert_exit 0 "$TL_RC"
  ok="$(perl -e "print(($ADV_SECS < 2.0) ? 'yes' : 'no')")"
  assert_eq "yes" "$ok" "60k-line transcript took ${ADV_SECS}s (limit 2 s)"
  rec="$(ls -t "$p/.handoff"/recovered-*.md | head -n 1)"
  assert_file_contains "$rec" "prompt number 59997" "the newest prompt must be in the recovered file"
}

test_fifty_megabyte_transcript_with_two_megabyte_lines_finishes_under_two_seconds() {
  local p="$CLAUDE_PROJECT_DIR" f="$TL_TMP/big2mb.jsonl" ok rec
  perl -e 'my $pad = "x" x (2*1024*1024 - 200); for my $i (1..25){ print qq({"type":"user","message":{"role":"user","content":"prompt $i"},"pad":"$pad"}\n) }' > "$f"
  printf '%s' "$(tl_payload_stop "big2" "$f" "$p" rate_limit)" > "$TL_TMP/big2.payload"
  adv_timed_stop "$TL_TMP/big2.payload"
  assert_exit 0 "$TL_RC"
  ok="$(perl -e "print(($ADV_SECS < 2.0) ? 'yes' : 'no')")"
  assert_eq "yes" "$ok" "50 MB transcript took ${ADV_SECS}s (limit 2 s)"
  rec="$(ls -t "$p/.handoff"/recovered-*.md | head -n 1)"
  assert_file_contains "$rec" "prompt 25" "the last prompt must be recovered from the big transcript"
}

test_fifo_transcript_does_not_hang_the_hook() {
  local p="$CLAUDE_PROJECT_DIR" fifo="$TL_TMP/pipe-transcript" pid i alive=1 rc
  mkfifo "$fifo" || fail "could not create the test FIFO"
  printf '%s' "$(tl_payload_stop "fifo-sess" "$fifo" "$p" rate_limit)" | /bin/bash "$TL_HOOK_STOP" >/dev/null 2>&1 &
  pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if ! adv_alive "$pid"; then alive=0; break; fi
  done
  if [ "$alive" = 1 ]; then
    pkill -f "$fifo" 2>/dev/null
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    fail "hook was still running after 5 s on a FIFO transcript (minor: SPEC says StopFailure must finish < 2 s)"
  fi
  wait "$pid"
  rc=$?
  assert_eq "0" "$rc" "hook exit status after a FIFO transcript"
}

# ---------------------------------------------------------------------------
# Read-only and unwritable folders. SPEC: always exit 0 even when the project dir is read-only.
# ---------------------------------------------------------------------------

test_read_only_project_with_hostile_transcript_exits_zero() {
  local p="$CLAUDE_PROJECT_DIR" f="$TL_TMP/hostile-ro.jsonl"
  trap "chmod -R u+w '$TL_TMP' 2>/dev/null" EXIT
  cat > "$f" <<'EOF'
{"type":"user","message":{"role":"user","content":"Run $(touch CANARY_RO) and `touch CANARY_RO2`"}}
EOF
  chmod 555 "$p"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "ro-sess" "$f" "$p" rate_limit)"
  assert_exit 0 "$TL_RC"
  chmod 755 "$p"
  if [ -n "$(find "$TL_TMP" -name 'CANARY_RO*' 2>/dev/null)" ]; then
    fail "a canary file was created from a read-only project run"
  fi
}

test_unwritable_state_folder_never_stops_any_hook() {
  local p="$CLAUDE_PROJECT_DIR" state="$TL_TMP/state"
  trap "chmod -R u+w '$state' 2>/dev/null" EXIT
  mkdir -p "$state"
  chmod 555 "$state"
  printf '%s\n' '# H' > "$p/HANDOFF.md"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "st-ro" "$TL_FIX/basic.jsonl" "$p" rate_limit)"
  assert_exit 0 "$TL_RC"
  tl_run "$TL_HOOK_PROMPT" "$(tl_payload_plain UserPromptSubmit "st-ro" "$p" "")"
  assert_exit 0 "$TL_RC"
  tl_run "$TL_HOOK_SESSION" "$(tl_payload_plain SessionStart "st-ro" "$p" "startup")"
  assert_exit 0 "$TL_RC"
  tl_run "$TL_HOOK_COMPACT" "$(tl_payload_plain PreCompact "st-ro" "$p" "")"
  assert_exit 0 "$TL_RC"
  chmod 755 "$state"
}

# ---------------------------------------------------------------------------
# Odd names and hostile input fields. SPEC "Security" and "Layout": quote every path.
# ---------------------------------------------------------------------------

test_hostile_folder_name_works_for_the_hook() {
  local p="$TL_TMP/it's \"q\" \$HOME \`tick\` café %s {{X}}"
  local rec
  mkdir -p "$p"
  export CLAUDE_PROJECT_DIR="$p"
  tl_run "$TL_HOOK_STOP" "$(tl_payload_stop "odd-name" "$TL_FIX/basic.jsonl" "$p" rate_limit)"
  assert_exit 0 "$TL_RC"
  assert_file_exists "$p/HANDOFF.md" "HANDOFF.md must be created in a folder with quotes, \$, backticks and accents"
  assert_file_exists "$p/PASTE-PROMPT.txt"
  assert_file_contains "$p/PASTE-PROMPT.txt" "$p" "the paste prompt must show the exact folder path"
  rec="$(ls -t "$p/.handoff"/recovered-*.md | head -n 1)"
  assert_file_exists "$rec"
}

test_hostile_session_cwd_error_and_transcript_fields_never_execute() {
  local p="$CLAUDE_PROJECT_DIR"
  local payload
  payload="$(jq -n --arg s '$(touch CANARY_S) `touch CANARY_S2` %s {{PROJECT_DIR}}' \
    --arg c '/nonexistent $(touch CANARY_C)' \
    --arg t '/nonexistent/$(touch CANARY_T).jsonl' \
    '{session_id: $s, cwd: $c, transcript_path: $t, hook_event_name: "StopFailure", error: "rate_limit"}')"
  tl_run "$TL_HOOK_STOP" "$payload"
  assert_exit 0 "$TL_RC"
  if [ -n "$(find "$TL_TMP" -name 'CANARY_*' 2>/dev/null)" ]; then
    fail "a canary file appeared: a hook input field was executed"
  fi
  assert_file_exists "$p/PASTE-PROMPT.txt" "the paste prompt must still be written"
}

test_hostile_handoff_text_is_shown_literally_by_the_prompt_hook() {
  local p="$CLAUDE_PROJECT_DIR"
  cat > "$p/HANDOFF.md" <<'EOF'
# H

<!-- limit-handoff:cutoff session="evil1" at="2026-10-28 10:00" error="x$(touch CANARY_H)%s{{RECOVERED_FILE}}" status="unresolved" -->
> ⚠️ **Session cut off** (usage limit reached) at 2026-10-28 10:00. Old.
> Check. Recovered context: `.handoff/evil `touch CANARY_H2` %s.md`
<!-- /limit-handoff:cutoff -->
EOF
  tl_run "$TL_HOOK_PROMPT" "$(tl_payload_plain UserPromptSubmit "h-evil" "$p" "")"
  assert_exit 0 "$TL_RC"
  if [ -n "$(find "$TL_TMP" -name 'CANARY_H*' 2>/dev/null)" ]; then
    fail "a canary file appeared: text in HANDOFF.md was executed"
  fi
}

run_tests
