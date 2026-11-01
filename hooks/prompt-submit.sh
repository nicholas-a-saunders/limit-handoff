#!/usr/bin/env bash
# hooks/prompt-submit.sh - UserPromptSubmit hook.
# Prints a short reminder about HANDOFF.md. Stdout on exit 0 is added to Claude's context.
# It always exits 0.

HK_HOOK_LIB="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)"
if [ -z "$HK_HOOK_LIB" ] || [ ! -f "$HK_HOOK_LIB/common.sh" ]; then
  exit 0
fi
# shellcheck source=lib/common.sh
. "$HK_HOOK_LIB/common.sh" || exit 0

hk_prompt_submit_main() {
  hk_read_input
  hk_project_dir
  local hf block mode stale_min age seen_dir seen first name sid

  hf="$(hk_handoff_path)"
  [ -f "$hf" ] || return 0
  # A link to a place outside the project is not read (see hk_final_link_ok).
  hk_final_link_ok "$hf" || return 0

  if hk_has_unresolved_cutoff "$hf"; then
    block="$(hk_last_unresolved_block "$hf")"
    # The newest block is named. The command name depends on how the kit was installed.
    printf '%s\n' "$(hk_cutoff_message "$hf" "$block")"
    return 0
  fi

  name="$(hk_handoff_name)"
  mode="$(hk_conf LIMIT_HANDOFF_REMIND stale)"
  case "$mode" in
    off) return 0 ;;
    always)
      printf '%s exists here. Read it if you have not yet. Update it after each step so a usage-limit cut-off loses nothing.\n' "$name"
      return 0
      ;;
  esac

  # Default: "stale". Remind on the first prompt of a session, or when the file is old.
  stale_min="$(hk_int_conf LIMIT_HANDOFF_STALE_MIN 20)"
  age="$(hk_file_age_min "$hf")"
  sid="$(hk_clean_token "${HK_SESSION:-}")"
  if [ -z "$sid" ]; then sid="unknown"; fi
  seen_dir="$(hk_state_dir)/sessions"
  seen="$seen_dir/$sid.seen"
  first=0
  if [ ! -f "$seen" ]; then
    first=1
    mkdir -p "$seen_dir" 2>/dev/null && : > "$seen" 2>/dev/null
  fi
  if [ "$first" = 1 ] || [ "$age" -ge "$stale_min" ]; then
    printf '%s was last updated %s minutes ago. Read it if you have not yet. Update it after each step so a usage-limit cut-off loses nothing.\n' "$name" "$age"
  fi
  return 0
}

hk_prompt_submit_main || true
exit 0
