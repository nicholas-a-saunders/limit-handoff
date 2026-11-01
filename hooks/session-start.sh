#!/usr/bin/env bash
# hooks/session-start.sh - SessionStart hook.
# Tells a new or resumed session to read HANDOFF.md. Stdout is added to Claude's context.
# It also runs the catch-up for a chat that ended on a limit with no handoff (hk_catchup).
# It always exits 0.

HK_HOOK_LIB="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)"
if [ -z "$HK_HOOK_LIB" ] || [ ! -f "$HK_HOOK_LIB/common.sh" ]; then
  exit 0
fi
# shellcheck source=lib/common.sh
. "$HK_HOOK_LIB/common.sh" || exit 0

hk_session_start_main() {
  hk_read_input
  hk_project_dir
  local hf src age stale_min block step

  hf="$(hk_handoff_path)"
  src="${HK_SOURCE:-startup}"

  # Catch-up: a chat that ended on a limit with no handoff gets one now. It runs before the
  # checks below, because it may create HANDOFF.md. It prints its own line for each handoff.
  hk_catchup

  [ -f "$hf" ] || return 0
  # A link to a place outside the project is not read (see hk_final_link_ok).
  hk_final_link_ok "$hf" || return 0

  if [ "$src" = "compact" ]; then
    printf 'This session was compacted. Re-read %s before continuing.\n' "$(hk_handoff_name)"
  fi

  if hk_has_unresolved_cutoff "$hf"; then
    block="$(hk_last_unresolved_block "$hf")"
    # The newest block is named. The command name depends on how the kit was installed.
    printf '%s\n' "$(hk_cutoff_message "$hf" "$block")"
    step="$(hk_first_next_step "$hf")"
    if [ -n "$step" ]; then
      printf 'First next step: %s\n' "$step"
    fi
    return 0
  fi

  if [ "$src" = "startup" ] || [ "$src" = "resume" ]; then
    age="$(hk_file_age_min "$hf")"
    stale_min="$(hk_int_conf LIMIT_HANDOFF_STALE_MIN 20)"
    if [ "$age" -ge 0 ] && [ "$age" -lt "$stale_min" ]; then
      printf 'This project has %s (updated %s min ago). Read it before starting.\n' "$(hk_handoff_name)" "$age"
    fi
  fi
  return 0
}

hk_session_start_main || true
exit 0
