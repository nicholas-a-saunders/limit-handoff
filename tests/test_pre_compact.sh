#!/bin/bash
# Tests for hooks/pre-compact.sh (PreCompact snapshot).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

compact_run() {
  local payload
  payload="$(jq -n --arg s "$1" --arg t "$2" --arg c "$CLAUDE_PROJECT_DIR" \
    '{session_id: $s, transcript_path: $t, cwd: $c, hook_event_name: "PreCompact", trigger: "auto"}')"
  tl_run "$TL_HOOK_COMPACT" "$payload"
}

test_writes_precompact_snapshot_and_prints_nothing() {
  compact_run "pc-session-1" "$(tl_fixture basic.jsonl)"
  assert_exit 0 "$TL_RC"
  assert_eq "" "$TL_OUT" "PreCompact must print nothing"
  local snap; snap="$(ls "$CLAUDE_PROJECT_DIR/.handoff"/recovered-*-precompact.md 2>/dev/null | head -n 1)"
  assert_file_exists "$snap" "snapshot file missing"
  assert_file_contains "$snap" "Build the login page for the demo app"
  assert_file_missing "$CLAUDE_PROJECT_DIR/HANDOFF.md" "PreCompact must not create HANDOFF.md"
  assert_file_missing "$CLAUDE_PROJECT_DIR/.handoff/LATEST.md" "PreCompact must not replace LATEST.md"
}

test_snapshot_without_jq_still_written() {
  local payload
  payload="$(jq -n --arg s "pc-nojq" --arg t "$(tl_fixture basic.jsonl)" --arg c "$CLAUDE_PROJECT_DIR" \
    '{session_id: $s, transcript_path: $t, cwd: $c, hook_event_name: "PreCompact"}')"
  tl_use_nojq
  tl_run "$TL_HOOK_COMPACT" "$payload"
  assert_exit 0 "$TL_RC"
  local snap; snap="$(ls "$CLAUDE_PROJECT_DIR/.handoff"/recovered-*-precompact.md 2>/dev/null | head -n 1)"
  assert_file_exists "$snap"
  assert_file_contains "$snap" "jq is not installed"
}

test_exits_zero_on_garbage() {
  tl_run "$TL_HOOK_COMPACT" "{{{"
  assert_exit 0 "$TL_RC"
}

run_tests
