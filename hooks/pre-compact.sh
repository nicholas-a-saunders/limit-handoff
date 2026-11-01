#!/usr/bin/env bash
# hooks/pre-compact.sh - PreCompact hook.
# Saves a snapshot of the recovered context before the chat is compacted.
# Prints nothing. It always exits 0. (Exit 2 would block compaction, so it is never used.)

HK_HOOK_LIB="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)"
if [ -z "$HK_HOOK_LIB" ] || [ ! -f "$HK_HOOK_LIB/common.sh" ]; then
  exit 0
fi
# shellcheck source=lib/common.sh
. "$HK_HOOK_LIB/common.sh" || exit 0

hk_pre_compact_main() {
  hk_read_input
  hk_project_dir
  local sid json rc note rel
  sid="$(hk_clean_token "${HK_SESSION:-}")"
  if [ -z "$sid" ]; then sid="unknown"; fi
  json="$(hk_recover_json "${HK_TRANSCRIPT:-}" "$(hk_prompt_count)")"
  rc=$?
  note=""
  if [ "$rc" -ne 0 ]; then
    json=""
    note="$(hk_recover_note "$rc")"
  fi
  rel="$(hk_write_recovered "$json" "$sid" "precompact" "context compaction snapshot" "${HK_TRANSCRIPT:-}" "$note" "-precompact")"
  hk_log info "pre-compact snapshot: ${rel:-not written}"
  return 0
}

hk_pre_compact_main || true
exit 0
