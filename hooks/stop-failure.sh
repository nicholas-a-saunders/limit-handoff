#!/usr/bin/env bash
# hooks/stop-failure.sh - StopFailure hook for Claude Code.
#
# When a session stops on a usage, rate or billing limit, this hook:
#   1. writes .handoff/recovered-<time>-<session>.md from the end of the transcript,
#   2. adds or updates a cut-off block in HANDOFF.md (or creates HANDOFF.md),
#   3. writes PASTE-PROMPT.txt, copies it to the clipboard and shows a notification.
# A repeat for the same chat within LIMIT_HANDOFF_DEBOUNCE_SEC is ignored. When the session
# start runs the catch-up (LIMIT_HANDOFF_CATCHUP_RUN=1, see hk_catchup), there is no clipboard
# copy and no notification.
#
# Claude Code ignores this hook's output and exit code. It only makes side effects.
# It always exits 0. It never stops half way because of an error.
# Steps 2 and 3 change HANDOFF.md, so they run under a lock. Several chats can hit a
# limit at the same moment, and each one must keep its own block.

HK_HOOK_LIB="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)"
if [ -z "$HK_HOOK_LIB" ] || [ ! -f "$HK_HOOK_LIB/common.sh" ]; then
  exit 0
fi
# shellcheck source=lib/common.sh
. "$HK_HOOK_LIB/common.sh" || exit 0

hk_stop_failure_main() {
  hk_read_input
  # Claude Code always sends a JSON object. Empty or broken input writes nothing (see hk_read_input).
  if [ "${HK_INPUT_OK:-0}" != 1 ]; then
    hk_log info "StopFailure input is empty or not a JSON object; nothing written"
    return 0
  fi
  hk_project_dir

  local raw err sid reason base_reason allowed norm json rc note rec_rel rec_abs hf
  local next_step block paste derived prompt_file detail ltype lepoch lead catchup has_hf hf_ok shown_prompt
  local block_iso block_human lim_iso lim_epoch lim_human hf_written saved prompt_ok state_prompt sent

  # 1 when this run came from catch-up (session start), not from Claude Code. See hk_catchup.
  catchup=0
  if [ "${LIMIT_HANDOFF_CATCHUP_RUN:-}" = "1" ]; then catchup=1; fi

  raw="${HK_ERROR:-}"
  err="$(hk_clean_token "$raw")"
  if [ -z "$err" ]; then err="unknown"; fi
  # prompt_too_long is made by the kit for catch-up only. It is never matched against
  # LIMIT_HANDOFF_ERRORS. A StopFailure from Claude Code with that code is skipped.
  if [ "$err" = "prompt_too_long" ]; then
    if [ "$catchup" != "1" ]; then
      hk_log info "StopFailure with error 'prompt_too_long' is only used by catch-up; nothing written"
      return 0
    fi
  # SPEC: only a non-empty error code that is not in the list is skipped.
  # A missing error code is handled as "unknown" (docs/DECISIONS.md #3).
  elif [ -n "$raw" ]; then
    allowed="$(hk_conf LIMIT_HANDOFF_ERRORS "$HK_DEFAULT_ERRORS")"
    norm=" $(printf '%s' "$allowed" | tr '|,\t' '   ') "
    case "$norm" in
      *" $err "*) ;;
      *)
        hk_log info "StopFailure with error '$err' is not in LIMIT_HANDOFF_ERRORS; nothing written"
        return 0
        ;;
    esac
  fi

  sid="$(hk_clean_token "${HK_SESSION:-}")"
  if [ -z "$sid" ]; then sid="unknown"; fi
  # Claude Code can send several StopFailure events for one limit (bug #91419). The first one is
  # handled and marked. A repeat within LIMIT_HANDOFF_DEBOUNCE_SEC seconds is ignored. The marker
  # is written before the slow work below.
  if ! hk_claim_stop "$sid"; then
    hk_log info "duplicate StopFailure for $sid ignored"
    return 0
  fi
  hk_log info "StopFailure error=$err session=$sid project=$HK_PROJECT_DIR"
  hk_note_ignored_project_keys

  # 1. Recovered context from the end of the transcript.
  json="$(hk_recover_json "${HK_TRANSCRIPT:-}" "$(hk_prompt_count)")"
  rc=$?
  note=""
  if [ "$rc" -ne 0 ]; then
    json=""
    note="$(hk_recover_note "$rc")"
    hk_log warn "recovery incomplete (rc=$rc): $note"
  fi

  # The limit details: which limit, and when it resets. The transcript's limit line comes
  # first, then the hook's last message. Both are checked (see hk_limit_detail).
  ltype="$(hk_limit_type "$json")"
  lepoch="$(hk_limit_resets "$json")"
  detail="$(hk_limit_detail "$json" "${HK_LAST_MSG:-}")"
  # The details decide the wording: a rate_limit with details is an account usage limit.
  base_reason="$(hk_base_reason "$err" "$detail")"
  reason="$(hk_with_detail "$base_reason" "$detail")"
  if [ -n "$detail" ]; then hk_log info "limit details: $detail"; fi

  rec_rel="$(hk_write_recovered "$json" "$sid" "$err" "$reason" "${HK_TRANSCRIPT:-}" "$note" "" "$detail")"
  # Empty when no copy could be written. Then the block and the paste prompt say so, and no file is named.
  rec_abs=""
  if [ -z "$rec_rel" ]; then
    hk_log error "could not write the recovered context file in $HK_PROJECT_DIR"
  else
    rec_abs="$(hk_abs_path "$rec_rel")"
  fi

  hf="$(hk_handoff_path)"
  # The block shows the time of the limit line in the transcript. Without one, the time now is used.
  block_iso="$(hk_now_iso)"
  block_human="$(hk_now_human)"
  lim_iso="$(hk_limit_at "$json")"
  if [ -n "$lim_iso" ]; then
    lim_epoch="$(hk_iso_epoch "$lim_iso")"
    lim_human="$(hk_epoch_human "$lim_epoch")"
    if [ -n "$lim_epoch" ] && [ -n "$lim_human" ]; then
      block_iso="$lim_iso"
      block_human="$lim_human"
    fi
  fi
  block="$(hk_cutoff_block "$sid" "$block_iso" "$err" "$reason" "$block_human" "$rec_rel" "$ltype" "$lepoch")"

  # 2 and 3. Read the next step and update HANDOFF.md, all under one lock.
  hk_lock_take "$hf"

  # hf_ok: 0 when HANDOFF.md is a link to a place outside the project. Then it is neither read
  # nor written (see hk_final_link_ok).
  hf_ok=1
  if ! hk_final_link_ok "$hf"; then hf_ok=0; fi

  # has_hf: 1 when HANDOFF.md exists now or is made below, so the paste prompt may name it.
  # When the create fails, it goes back to 0 and the paste prompt is built again (see below).
  # With no known next step, the paste prompt asks the new chat to work it out (hk_paste_text).
  has_hf=0
  next_step=""
  if [ "$hf_ok" != 1 ]; then
    :
  elif [ -f "$hf" ]; then
    has_hf=1
    next_step="$(hk_first_next_step "$hf")"
  elif [ "$(hk_bool_conf LIMIT_HANDOFF_CREATE_IF_MISSING 1)" = "1" ]; then
    has_hf=1
    derived="$(hk_derive_next_step "$json")"
    next_step="$derived"
  fi
  paste="$(hk_paste_text "$next_step" "$rec_abs" "$reason" stop "$has_hf" "$sid")"
  # hf_written: 1 when the handoff for this chat is saved (or there is nothing to save). 0 when the
  # write failed, so the started marker is removed and a later catch-up may retry this chat.
  hf_written=1
  if [ "$hf_ok" != 1 ]; then
    paste="$paste $(hk_handoff_name) was not read or changed: it is a link to a place outside the project."
    hk_log error "$(hk_handoff_name) was not updated: it is a link to a place outside the project"
  elif [ -f "$hf" ]; then
    if hk_upsert_cutoff "$hf" "$sid" "$block"; then
      hk_log info "cut-off block written to $hf"
    else
      hk_log error "could not update $hf"
      hf_written=0
    fi
  elif [ "$(hk_bool_conf LIMIT_HANDOFF_CREATE_IF_MISSING 1)" = "1" ]; then
    if hk_create_handoff "$hf" "$json" "$reason" "$block" "$paste" "$block_human" "$rec_rel"; then
      hk_log info "created $hf from the transcript"
    else
      hk_log error "could not create $hf"
      hf_written=0
      # There is no HANDOFF.md after all, so the paste prompt must not tell the new chat to read it.
      has_hf=0
      paste="$(hk_paste_text "$next_step" "$rec_abs" "$reason" stop 0 "$sid")"
    fi
  else
    hk_log info "HANDOFF.md is missing and LIMIT_HANDOFF_CREATE_IF_MISSING=0; not created"
  fi
  if [ "$hf_written" != 1 ]; then
    hk_unmark_started "$sid"
  fi

  hk_lock_release

  # 4. Paste prompt file, clipboard and notification.
  # The title has the plain reason. The limit details go first in the body, so they are not said twice.
  lead=""
  if [ -n "$detail" ]; then lead="$detail. "; fi
  prompt_file="$(hk_prompt_path)"
  shown_prompt="$(basename "$HK_PROJECT_DIR")/$(hk_prompt_name)"
  if ! hk_final_link_ok "$prompt_file"; then
    # A committed link is not followed: the paste prompt goes to the state folder instead.
    prompt_file="$(hk_state_dir)/$(hk_prompt_name)"
    shown_prompt="$prompt_file"
  fi
  prompt_ok=0
  if hk_write_prompt_file "$prompt_file" "$paste"; then
    hk_log info "paste prompt written to $prompt_file"
    prompt_ok=1
  else
    hk_log error "could not write $prompt_file"
    # Second choice: the state folder (outside the project), so the paste prompt is not lost.
    state_prompt="$(hk_state_dir)/$(hk_prompt_name)"
    if [ "$prompt_file" != "$state_prompt" ] && mkdir -p "$(hk_state_dir)" 2>/dev/null \
      && hk_write_prompt_file "$state_prompt" "$paste"; then
      hk_log info "paste prompt written to $state_prompt instead"
      prompt_file="$state_prompt"
      shown_prompt="$state_prompt"
      prompt_ok=1
    fi
  fi
  # The done marker is written once the handoff is saved, so a catch-up skips this chat from now on.
  if [ "$hf_written" = 1 ]; then
    hk_mark_done "$sid"
  fi
  # A catch-up run is started when a new chat opens, so the user is already there.
  # No clipboard copy and no notification.
  if [ "$catchup" = "1" ]; then
    hk_log info "catch-up handoff for $sid"
    return 0
  fi
  # The notification body is built from what was really done: the handoff (saved, not saved, or
  # none made), the paste prompt file (saved, or not) and the clipboard (copied, or not).
  saved="Handoff saved"
  if [ "$hf_ok" != 1 ]; then
    saved="$(hk_handoff_name) not updated (it is a link outside the project)"
  elif [ "$hf_written" != 1 ]; then
    saved="Handoff NOT saved (see the log)"
  elif [ "$has_hf" != 1 ]; then
    saved="No $(hk_handoff_name) was written, so the paste prompt is all you have"
  fi
  if hk_copy_clipboard "$paste"; then
    hk_log info "paste prompt copied to the clipboard"
    sent="paste prompt copied"
    if [ "$prompt_ok" = 1 ]; then sent="paste prompt copied (also in $shown_prompt)"; fi
    hk_notify "Claude Code stopped: $base_reason" "${lead}${saved}; ${sent}. Paste it into a new chat."
  elif [ "$prompt_ok" = 1 ]; then
    hk_log info "clipboard not used; prompt is in $prompt_file"
    hk_notify "Claude Code stopped: $base_reason" "${lead}${saved}; paste prompt saved to $shown_prompt. Paste it into a new chat."
  else
    hk_log error "the paste prompt was not copied or saved"
    hk_notify "Claude Code stopped: $base_reason" "${lead}${saved}; the paste prompt could not be saved (see the log)."
  fi
  return 0
}

# hk_create_handoff file json reason block paste [when] [recovered]
# when is the cut-off time shown in the Status line (the limit line's time; default now).
# recovered is the recovered file's path; empty means none was written, so none is pointed to.
# Builds HANDOFF.md from the recovered JSON when it does not exist yet.
# Text that came from the transcript is put in as plain text: line breaks in the goal are
# joined, and every "#" is escaped (\#). So a prompt can never start a heading such as
# "## Next steps" in the new file.
hk_create_handoff() {
  local file="$1" json="$2" reason="$3" block="$4" paste="$5" when="${6:-}" rec="${7:-}"
  local goal done_list next status name body recent first
  [ -n "$json" ] || json='{}'
  name="$(basename "$HK_PROJECT_DIR")"
  [ -n "$when" ] || when="$(hk_now_human)"
  # The first step when no task is open. It names the recovered file only when there is one.
  if [ -n "$rec" ]; then
    first="1. Read the recovered context file named in the cut-off block, then confirm the goal with the user"
    recent="_The recent messages are not copied here. They are in the recovered context file named in the cut-off block._"
  else
    first="1. Work out the next step from the project files, then confirm the goal with the user"
    recent="_The recent messages are not copied here, and no recovered context file was written for this stop._"
  fi

  goal="$(printf '%s' "$json" | jq -r '
    def md1: gsub("\n"; " ") | gsub("#"; "\\#");
    (.first_prompt // "(The first request was not found in the recent transcript. Ask the user for the goal.)") | md1' 2>/dev/null)"
  [ -n "$goal" ] || goal="(The first request was not found in the recent transcript. Ask the user for the goal.)"

  status="cut off ($reason) at $when — auto-created by limit-handoff from the transcript; verify before trusting. Made from chat text by limit-handoff. Check it before you commit it."

  done_list="$(printf '%s' "$json" | jq -r '
    def md1: gsub("\n"; " ") | gsub("#"; "\\#");
    ([ (.tasks // [])[] | select(.status == "completed") | "- Done: " + ((.content // "") | md1) ]
     + [ (.files_touched // [])[] | "- Changed file: `" + . + "`" ])
    | if length == 0 then ["- Nothing was recorded in the recent transcript."] else . end
    | join("\n")' 2>/dev/null)"

  next="$(printf '%s' "$json" | jq -r --arg first "$first" '
    def md1: gsub("\n"; " ") | gsub("#"; "\\#");
    ((.tasks // []) | ([.[] | select(.status == "in_progress")] + [.[] | select(.status == "pending")]))
    | if length == 0 then [$first]
      else to_entries | map((.key + 1 | tostring) + ". " + ((.value.content // "") | md1)) end
    | join("\n")' 2>/dev/null)"

  # The recent messages are not copied into this file (they can hold secrets). They stay in the
  # recovered context file, which the cut-off block names (see "recent" above).

  # Defaults go in before the render, so an empty list still shows a line.
  [ -n "$done_list" ] || done_list="- Nothing was recorded in the recent transcript."
  [ -n "$next" ] || next="$first"
  body="$(hk_render_template "$HK_ROOT/templates/HANDOFF.template.md" \
    "TASK_NAME=$name" \
    "UPDATED=$when by limit-handoff (auto-created)" \
    "GOAL=$goal" \
    "STATUS=$status" \
    "DONE=$done_list" \
    "NEXT_STEPS=$next" \
    "RECENT=$recent" \
    "PASTE_PROMPT=$paste")" || return 1
  mkdir -p "$(dirname "$file")" 2>/dev/null
  { printf '%s\n\n%s\n' "$body" "$block"; } | hk_atomic_write "$file"
}

hk_stop_failure_main || true
exit 0
