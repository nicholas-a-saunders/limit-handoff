#!/bin/bash
# Tests for the limit details (feature B): which limit was hit and when it resets.
# Covers the transcript "limit" key, the optional limit= and resets= attributes on the
# cut-off block, the detail in the reason (block, paste prompt, recovered file, notification
# and the prompt and session hooks), and the rule that transcript or message text is never
# printed. Only synthetic fixtures are used (tests/fixtures/limit_*.jsonl).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Epoch 1893519600 is Tue 01 Jan 2030 17:40 UTC. It is in the future on purpose: a reset time that
# has passed is written as "the reset time has passed" (see hk_limit_text), which these tests do not check.
FIVE_EPOCH=1893519600
FIVE_UTC="Tue 01 Jan 17:40 UTC"
# Epoch 1894006800 is Mon 07 Jan 2030 09:00 UTC (in the future, so no "reset time has passed" wording).
WEEK_EPOCH=1894006800
WEEK_UTC="Mon 07 Jan 09:00 UTC"

# load_common: loads lib/common.sh into this test shell (the same way test_common.sh does).
load_common() {
  . "$TL_ROOT/lib/common.sh"
  HK_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
}

# recover_json file: the recovered JSON of a transcript, built the same way the hooks build it.
recover_json() {
  /bin/bash -c '. "$1/lib/common.sh"; HK_PROJECT_DIR="$CLAUDE_PROJECT_DIR"; hk_recover_json "$2" 5' \
    _ "$TL_ROOT" "$1"
}

project() {
  [ -n "$CLAUDE_PROJECT_DIR" ] || fail "CLAUDE_PROJECT_DIR is empty; refusing to continue"
  printf "%s\n" "$CLAUDE_PROJECT_DIR"
}

recovered_for() {
  # recovered_for project session8: prints the newest recovered file for that session.
  ls -t "$1/.handoff"/recovered-*"$2"*.md 2>/dev/null | head -n 1
}

# run_stop sid transcript cwd error: a StopFailure payload with no last message.
run_stop() {
  local payload
  payload="$(tl_payload_stop "$1" "$2" "$3" "$4")"
  tl_run "$TL_HOOK_STOP" "$payload"
}

# run_stop_msg sid transcript cwd error last_message: a StopFailure payload with the hook's
# last_assistant_message text.
run_stop_msg() {
  local payload
  payload="$(jq -n --arg s "$1" --arg t "$2" --arg c "$3" --arg e "$4" --arg m "$5" \
    '{session_id: $s, transcript_path: $t, cwd: $c, hook_event_name: "StopFailure", error: $e, last_assistant_message: $m}')"
  tl_run "$TL_HOOK_STOP" "$payload"
}

# ---------------------------------------------------------------------------
# Transcript: the limit key
# ---------------------------------------------------------------------------

test_transcript_limit_key_has_type_reset_and_error() {
  local out
  out="$(recover_json "$(tl_fixture limit_five_hour.jsonl)")"
  assert_eq "rate_limit" "$(printf '%s' "$out" | jq -r '.limit.error')" "error code of the limit line"
  assert_eq "five_hour" "$(printf '%s' "$out" | jq -r '.limit.type')" "limit type"
  assert_eq "$FIVE_EPOCH" "$(printf '%s' "$out" | jq -r '.limit.resets_at')" "reset time as epoch seconds"
  assert_eq "You've hit your session limit · resets 5:40pm (Europe/London)" \
    "$(printf '%s' "$out" | jq -r '.limit.text')" "first text block of the limit line"
}

test_transcript_limit_reads_the_rate_limit_info_form() {
  local out
  out="$(recover_json "$(tl_fixture limit_seven_day.jsonl)")"
  assert_eq "seven_day" "$(printf '%s' "$out" | jq -r '.limit.type')" "type from apiErrorParams.rate_limit_info"
  assert_eq "$WEEK_EPOCH" "$(printf '%s' "$out" | jq -r '.limit.resets_at')" "reset from apiErrorParams.rate_limit_info"
}

test_transcript_sidechain_limit_line_gives_null_limit() {
  local out
  out="$(recover_json "$(tl_fixture limit_sidechain_only.jsonl)")"
  assert_eq "null" "$(printf '%s' "$out" | jq -c '.limit')" "a subagent copy (isSidechain true) is ignored"
}

test_transcript_no_limit_line_gives_null_limit() {
  local out
  out="$(recover_json "$(tl_fixture basic.jsonl)")"
  assert_eq "null" "$(printf '%s' "$out" | jq -c '.limit')" "no limit line means null"
}

test_transcript_synthetic_error_line_is_never_the_last_reply() {
  local out
  out="$(recover_json "$(tl_fixture limit_five_hour.jsonl)")"
  assert_eq "Working on the invoice totals now." "$(printf '%s' "$out" | jq -r '.last_assistant_text')" \
    "the error text must not become the last assistant text"
  out="$(recover_json "$(tl_fixture limit_hostile.jsonl)")"
  assert_eq "Real reply before the limit" "$(printf '%s' "$out" | jq -r '.last_assistant_text')" \
    "the real reply wins over a hostile error line"
}

test_transcript_last_limit_line_wins() {
  local tr="$TL_TMP/two-limits.jsonl" out
  jq -c -n '{type:"assistant", isApiErrorMessage:true, error:"rate_limit", isSidechain:false, quotaLimits:{rateLimitType:"five_hour", resetsAt:1893519600}, message:{role:"assistant", content:[{type:"text", text:"first"}]}}' > "$tr"
  jq -c -n '{type:"assistant", isApiErrorMessage:true, error:"rate_limit", isSidechain:false, quotaLimits:{rateLimitType:"seven_day", resetsAt:1894006800}, message:{role:"assistant", content:[{type:"text", text:"second"}]}}' >> "$tr"
  out="$(recover_json "$tr")"
  assert_eq "seven_day" "$(printf '%s' "$out" | jq -r '.limit.type')" "the newest limit line is used"
}

test_transcript_non_number_reset_becomes_null() {
  local tr="$TL_TMP/bad-reset.jsonl" out
  jq -c -n '{type:"assistant", isApiErrorMessage:true, error:"rate_limit", isSidechain:false, quotaLimits:{rateLimitType:"five_hour", resetsAt:"soon"}, message:{role:"assistant", content:[{type:"text", text:"x"}]}}' > "$tr"
  out="$(recover_json "$tr")"
  assert_eq "null" "$(printf '%s' "$out" | jq -c '.limit.resets_at')" "a reset time that is not a number is dropped"
  assert_eq "five_hour" "$(printf '%s' "$out" | jq -r '.limit.type')" "the type is still kept"
}

# ---------------------------------------------------------------------------
# Labels, times and text (lib/common.sh)
# ---------------------------------------------------------------------------

test_limit_labels_known_and_generic() {
  load_common
  assert_eq "5-hour limit" "$(hk_limit_label five_hour)"
  assert_eq "weekly limit" "$(hk_limit_label seven_day)"
  assert_eq "weekly Opus limit" "$(hk_limit_label seven_day_opus)"
  assert_eq "weekly Sonnet limit" "$(hk_limit_label seven_day_sonnet)"
  assert_eq "daily cap limit" "$(hk_limit_label daily_cap)" "underscores become spaces"
  assert_eq "" "$(hk_limit_label 'Five Hour')" "capitals and spaces are refused"
  assert_eq "" "$(hk_limit_label 'x$(touch CANARY)')" "shell text is refused"
  assert_eq "" "$(hk_limit_label '')" "empty gives nothing"
  assert_eq "" "$(hk_limit_label '_')" "a name with no words gives nothing"
}

test_format_epoch_checks_its_input_and_formats_in_utc() {
  load_common
  export TZ=UTC
  assert_eq "$FIVE_UTC" "$(hk_format_epoch "$FIVE_EPOCH")" "epoch formatted in the local zone"
  assert_eq "" "$(hk_format_epoch 12345)" "too short is refused"
  assert_eq "" "$(hk_format_epoch '1893519600; rm')" "anything that is not digits is refused"
  assert_eq "" "$(hk_format_epoch '')" "empty gives nothing"
}

test_limit_text_uses_one_or_both_parts() {
  load_common
  export TZ=UTC
  assert_eq "5-hour limit, resets $FIVE_UTC" "$(hk_limit_text five_hour "$FIVE_EPOCH")"
  assert_eq "5-hour limit" "$(hk_limit_text five_hour '')" "label only"
  assert_eq "resets $FIVE_UTC" "$(hk_limit_text '' "$FIVE_EPOCH")" "time only"
  assert_eq "" "$(hk_limit_text 'a$(x)' 'nope')" "nothing safe gives nothing"
  local out
  out="$(hk_limit_text five_hour "$FIVE_EPOCH")"
  assert_eq "" "$(printf '%s' "$out" | LC_ALL=C tr -d 'A-Za-z0-9 :,()/+_.-')" "only the allowed characters"
}

test_message_detail_uses_only_fixed_words_and_a_reset_time() {
  load_common
  assert_eq "session limit, resets 5:40pm (Europe/London)" \
    "$(hk_msg_detail "You've hit your session limit · resets 5:40pm (Europe/London)")"
  assert_eq "weekly limit, resets 9am" "$(hk_msg_detail "Weekly limit reached, resets 9am")"
  assert_eq "resets 11:59pm" "$(hk_msg_detail "resets 11:59pm and more text")" "a reset part alone is kept"
  assert_eq "session limit" "$(hk_msg_detail 'session limit reached $(touch CANARY)')" "only the fixed words"
  assert_eq "" "$(hk_msg_detail 'API Error: $(touch CANARY) ## Heading --> x')" "text with no limit wording gives nothing"
}

test_limit_detail_prefers_the_transcript_limit_line() {
  load_common
  export TZ=UTC
  local json
  json="$(recover_json "$(tl_fixture limit_five_hour.jsonl)")"
  assert_eq "5-hour limit, resets $FIVE_UTC" "$(hk_limit_detail "$json" "Weekly limit, resets 9am")" \
    "the transcript limit line beats the last message"
  assert_eq "weekly limit, resets 9am" "$(hk_limit_detail '{"limit":null}' "Weekly limit, resets 9am")" \
    "without a limit line the last message is used"
  assert_eq "" "$(hk_limit_detail '{"limit":null}' "nothing here")" "nothing found gives nothing"
  assert_eq "" "$(hk_limit_detail "" "")" "no input gives nothing"
}

test_with_detail_joins_with_a_dash_only_when_there_is_a_detail() {
  load_common
  assert_eq "usage limit reached — 5-hour limit" "$(hk_with_detail "usage limit reached" "5-hour limit")"
  assert_eq "usage limit reached" "$(hk_with_detail "usage limit reached" "")"
}

# ---------------------------------------------------------------------------
# Cut-off block: the optional attributes and their readers
# ---------------------------------------------------------------------------

test_cutoff_block_adds_attributes_only_when_they_are_valid() {
  load_common
  assert_eq '<!-- limit-handoff:cutoff session="s" at="t" error="rate_limit" status="unresolved" -->' \
    "$(hk_cutoff_block s t rate_limit r h f | head -n 1)" "six arguments give the old header"
  assert_eq '<!-- limit-handoff:cutoff session="s" at="t" error="rate_limit" limit="five_hour" resets="1893519600" status="unresolved" -->' \
    "$(hk_cutoff_block s t rate_limit r h f five_hour 1893519600 | head -n 1)" "both attributes"
  assert_eq '<!-- limit-handoff:cutoff session="s" at="t" error="rate_limit" resets="1893519600" status="unresolved" -->' \
    "$(hk_cutoff_block s t rate_limit r h f '' 1893519600 | head -n 1)" "reset only"
  assert_eq '<!-- limit-handoff:cutoff session="s" at="t" error="rate_limit" status="unresolved" -->' \
    "$(hk_cutoff_block s t rate_limit r h f 'bad"x' 'nope' | head -n 1)" "unsafe values are left out"
}

test_block_readers_accept_only_checked_values() {
  load_common
  local b long
  b='<!-- limit-handoff:cutoff session="s" at="t" error="rate_limit" limit="five_hour" resets="1893519600" status="unresolved" -->'
  assert_eq "five_hour" "$(hk_block_limit "$b")"
  assert_eq "1893519600" "$(hk_block_resets "$b")"
  b='<!-- limit-handoff:cutoff session="s" at="t" error="rate_limit" limit="Five Hour" resets="12" status="unresolved" -->'
  assert_eq "" "$(hk_block_limit "$b")" "a limit with a space and capitals is refused"
  assert_eq "" "$(hk_block_resets "$b")" "a short reset time is refused"
  b='<!-- limit-handoff:cutoff session="s" at="t" error="rate_limit" limit="$(touch CANARY)" resets="1893519600x" status="unresolved" -->'
  assert_eq "" "$(hk_block_limit "$b")" "shell text in a limit is refused"
  assert_eq "" "$(hk_block_resets "$b")" "text after a reset time is refused"
  long="$(printf 'a%.0s' $(seq 1 41))"
  b="<!-- limit-handoff:cutoff session=\"s\" at=\"t\" error=\"rate_limit\" limit=\"$long\" status=\"unresolved\" -->"
  assert_eq "" "$(hk_block_limit "$b")" "a 41 character limit is refused"
  assert_eq "rate_limit" "$(hk_block_error "$b")" "the error is still read"
}

test_old_block_without_attributes_still_parses() {
  load_common
  local p block
  p="$(project)"
  printf '%s\n' '# H' '<!-- limit-handoff:cutoff session="old-one" at="2026-10-29 10:00" error="rate_limit" status="unresolved" -->' \
    '> ⚠️ **Session cut off** (usage limit reached) at 2026-10-29 10:00. The steps above may be slightly behind.' \
    '<!-- /limit-handoff:cutoff -->' > "$p/HANDOFF.md"
  block="$(hk_last_unresolved_block "$p/HANDOFF.md")"
  assert_eq "" "$(hk_block_limit "$block")" "no limit attribute"
  assert_eq "" "$(hk_block_resets "$block")" "no resets attribute"
  assert_eq "" "$(hk_block_detail "$block")" "no detail"
  assert_eq "rate_limit" "$(hk_block_error "$block")"
  assert_eq "2026-10-29 10:00" "$(hk_block_at_human "$block")"
  assert_eq "old-one" "$(hk_block_session "$block")"
}

test_upsert_keeps_attributes_on_the_block() {
  load_common
  local f="$TL_TMP/up.md"
  printf '%s\n' '# T' '<!-- limit-handoff:cutoff session="A" at="t1" error="rate_limit" status="unresolved" -->' 'old' '<!-- /limit-handoff:cutoff -->' > "$f"
  hk_upsert_cutoff "$f" "A" "$(hk_cutoff_block A t2 rate_limit "usage limit reached" "now" "r.md" five_hour 1893519600)" || fail "upsert failed"
  assert_count "$f" 'session="A"' 1 "still one block"
  assert_file_contains "$f" 'limit="five_hour" resets="1893519600" status="unresolved"'
  assert_file_not_contains "$f" 'at="t1"' "the old block is replaced"
}

# ---------------------------------------------------------------------------
# Hooks: the detail in the reason, the paste prompt, the recovered file and the notification
# ---------------------------------------------------------------------------

test_five_hour_limit_shows_in_block_prompt_recovered_file_and_notification() {
  local p rec; p="$(project)"
  export TZ=UTC
  tl_use_notify
  run_stop "five-sess" "$(tl_fixture limit_five_hour.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "error=\"rate_limit\" limit=\"five_hour\" resets=\"$FIVE_EPOCH\" status=\"unresolved\"" "block attributes"
  assert_file_contains "$p/HANDOFF.md" "(usage limit reached — 5-hour limit, resets $FIVE_UTC)" "cut-off line"
  assert_file_contains "$p/PASTE-PROMPT.txt" "My last chat stopped (usage limit reached — 5-hour limit, resets $FIVE_UTC)." "paste prompt reason"
  rec="$(recovered_for "$p" "five-se")"
  assert_file_exists "$rec"
  assert_file_contains "$rec" "- Limit: 5-hour limit, resets $FIVE_UTC" "recovered file limit line"
  assert_file_contains "$rec" "- Why this was made: usage limit reached — 5-hour limit, resets $FIVE_UTC (code \`rate_limit\`)" "recovered file reason"
  assert_eq "Claude Code stopped: usage limit reached" "$(sed -n 1p "$TEST_OUT/notify.txt")" "title has the plain reason"
  assert_eq "5-hour limit, resets $FIVE_UTC. Handoff saved; paste prompt saved to project/PASTE-PROMPT.txt. Paste it into a new chat." \
    "$(sed -n 2p "$TEST_OUT/notify.txt")" "body starts with the detail"
}

test_notification_body_when_the_clipboard_got_the_prompt() {
  local p; p="$(project)"
  export TZ=UTC
  tl_use_clipboard
  tl_use_notify
  run_stop "copy-sess" "$(tl_fixture limit_five_hour.jsonl)" "$p" "rate_limit"
  assert_file_exists "$TEST_OUT/clipboard.txt" "the clipboard shim was called"
  assert_eq "5-hour limit, resets $FIVE_UTC. Handoff saved; paste prompt copied (also in project/PASTE-PROMPT.txt). Paste it into a new chat." \
    "$(sed -n 2p "$TEST_OUT/notify.txt")" "copied wording"
}

test_seven_day_limit_uses_the_weekly_label() {
  local p; p="$(project)"
  export TZ=UTC
  run_stop "week-sess" "$(tl_fixture limit_seven_day.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "limit=\"seven_day\" resets=\"$WEEK_EPOCH\"" "block attributes"
  assert_file_contains "$p/HANDOFF.md" "(usage limit reached — weekly limit, resets $WEEK_UTC)" "weekly wording"
  assert_file_contains "$p/PASTE-PROMPT.txt" "weekly limit, resets $WEEK_UTC" "paste prompt"
}

test_generic_limit_type_gets_a_safe_label() {
  local p tr; p="$(project)"
  export TZ=UTC
  tr="$TL_TMP/daily.jsonl"
  jq -c -n --argjson r "$FIVE_EPOCH" '{type:"assistant", isApiErrorMessage:true, error:"rate_limit", isSidechain:false, quotaLimits:{rateLimitType:"daily_cap", resetsAt:$r}, message:{role:"assistant", content:[{type:"text", text:"limit"}]}}' > "$tr"
  run_stop "daily-sess" "$tr" "$p" "rate_limit"
  assert_file_contains "$p/HANDOFF.md" 'limit="daily_cap"' "generic type is written"
  assert_file_contains "$p/HANDOFF.md" "daily cap limit, resets $FIVE_UTC" "generic label"
}

test_unsafe_limit_type_is_left_out_but_reset_is_kept() {
  local p tr; p="$(project)"
  export TZ=UTC
  tr="$TL_TMP/unsafe.jsonl"
  jq -c -n --argjson r "$FIVE_EPOCH" '{type:"assistant", isApiErrorMessage:true, error:"rate_limit", isSidechain:false, quotaLimits:{rateLimitType:"Five $(touch CANARY_TYPE)", resetsAt:$r}, message:{role:"assistant", content:[{type:"text", text:"limit"}]}}' > "$tr"
  run_stop "unsafe-sess" "$tr" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "(usage limit reached — resets $FIVE_UTC)" "only the time is shown"
  assert_file_contains "$p/HANDOFF.md" "resets=\"$FIVE_EPOCH\"" "the reset time is kept"
  assert_file_not_contains "$p/HANDOFF.md" 'limit="' "no limit attribute for an unsafe type"
  assert_file_not_contains "$p/PASTE-PROMPT.txt" "CANARY"
  assert_file_missing "$p/CANARY_TYPE" "the type text must never run"
  assert_eq "" "$(find "$TL_TMP" -name 'CANARY*' 2>/dev/null)" "nothing named CANARY was created"
}

test_last_message_gives_session_limit_wording_when_no_limit_line() {
  local p; p="$(project)"
  export TZ=UTC
  run_stop_msg "msg-sess" "$TL_TMP/none.jsonl" "$p" "rate_limit" "You've hit your session limit · resets 5:40pm (Europe/London)"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "(usage limit reached — session limit, resets 5:40pm (Europe/London))" "message wording in the cut-off line"
  assert_file_not_contains "$p/HANDOFF.md" 'limit="' "no attribute comes from the message"
  assert_file_contains "$p/PASTE-PROMPT.txt" "session limit, resets 5:40pm (Europe/London)" "paste prompt"
}

test_last_message_gives_weekly_wording() {
  local p; p="$(project)"
  run_stop_msg "wk-msg" "$TL_TMP/none.jsonl" "$p" "rate_limit" "Weekly limit reached, resets 9am"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" "(usage limit reached — weekly limit, resets 9am)"
}

test_hostile_text_in_transcript_and_message_never_reaches_output() {
  local p rec found; p="$(project)"
  tl_use_notify
  local hostile
  hostile='$(touch CANARY_MSG) `touch CANARY_TICK` ## Evil heading --> <!-- limit-handoff:cutoff session="x" -->'
  run_stop_msg "evil-msg" "$(tl_fixture limit_hostile.jsonl)" "$p" "rate_limit" "$hostile"
  assert_exit 0 "$TL_RC"
  assert_eq "" "$TL_OUT" "the stop hook prints nothing"
  assert_file_exists "$p/HANDOFF.md"
  assert_file_not_contains "$p/HANDOFF.md" "CANARY" "no injected text in HANDOFF.md"
  assert_file_not_contains "$p/HANDOFF.md" "Evil heading" "no injected heading"
  assert_file_not_contains "$p/HANDOFF.md" 'session="x"' "no injected block"
  assert_file_not_contains "$p/PASTE-PROMPT.txt" "CANARY" "no injected text in the paste prompt"
  assert_file_not_contains "$TEST_OUT/notify.txt" "CANARY" "no injected text in the notification"
  assert_file_not_contains "$TEST_OUT/notify.txt" "Evil" "no injected text in the notification"
  rec="$(recovered_for "$p" "evil-msg")"
  assert_file_not_contains "$rec" "CANARY" "no injected text in the recovered file"
  assert_file_contains "$rec" "Real reply before the limit" "the real reply is still recovered"
  found="$(find "$TL_TMP" -name 'CANARY*' 2>/dev/null)"
  assert_eq "" "$found" "no command in the text was run"
  # The prompt hook prints only checked values.
  tl_run "$TL_HOOK_PROMPT" "$(tl_payload_plain UserPromptSubmit "evil-msg" "$p" "")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "usage limit reached" "the prompt hook still reports the cut-off"
  assert_not_contains "$TL_OUT" "CANARY" "prompt hook output is clean"
  assert_not_contains "$TL_OUT" "Evil" "prompt hook output is clean"
}

test_hostile_block_attributes_are_never_printed() {
  local p; p="$(project)"
  printf '%s\n' '# H' '<!-- limit-handoff:cutoff session="h1" at="2026-10-29 10:00" error="rate_limit" limit="$(touch CANARY_ATTR)" resets="$(touch CANARY_ATTR)x" status="unresolved" -->' \
    '> ⚠️ **Session cut off** (usage limit reached) at 2026-10-29 10:00. The steps above may be slightly behind.' \
    '<!-- /limit-handoff:cutoff -->' > "$p/HANDOFF.md"
  tl_run "$TL_HOOK_PROMPT" "$(tl_payload_plain UserPromptSubmit "h1" "$p" "")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "(2026-10-29 10:00, usage limit reached)" "the reason has no detail from unsafe attributes"
  assert_not_contains "$TL_OUT" "CANARY" "nothing unsafe is printed"
  assert_not_contains "$TL_OUT" "touch" "nothing unsafe is printed"
  tl_run "$TL_HOOK_SESSION" "$(tl_payload_plain SessionStart "h1" "$p" "startup")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "(2026-10-29 10:00, usage limit reached)" "session start has the same plain reason"
  assert_not_contains "$TL_OUT" "CANARY" "session start output is clean"
}

test_prompt_and_session_hooks_show_the_detail() {
  local p; p="$(project)"
  export TZ=UTC
  run_stop "ps-sess" "$(tl_fixture limit_five_hour.jsonl)" "$p" "rate_limit"
  tl_run "$TL_HOOK_PROMPT" "$(tl_payload_plain UserPromptSubmit "ps-sess" "$p" "")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "usage limit reached — 5-hour limit, resets $FIVE_UTC)" "prompt hook shows the detail"
  tl_run "$TL_HOOK_SESSION" "$(tl_payload_plain SessionStart "ps-sess" "$p" "startup")"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "usage limit reached — 5-hour limit, resets $FIVE_UTC)" "session start shows the detail"
}

test_no_limit_means_plain_wording_everywhere() {
  local p rec; p="$(project)"
  tl_use_notify
  run_stop "plain-sess" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  rec="$(recovered_for "$p" "plain-se")"
  assert_file_not_contains "$rec" "- Limit:" "no limit line without a limit"
  assert_file_contains "$p/HANDOFF.md" "(usage limit reached)" "plain cut-off line"
  assert_eq "Claude Code stopped: usage limit reached" "$(sed -n 1p "$TEST_OUT/notify.txt")"
  assert_eq "Handoff saved; paste prompt saved to project/PASTE-PROMPT.txt. Paste it into a new chat." \
    "$(sed -n 2p "$TEST_OUT/notify.txt")" "no detail at the start of the body"
}

# ---------------------------------------------------------------------------
# CLI: an old block with and without the new attributes
# ---------------------------------------------------------------------------

test_resolve_keeps_the_limit_attributes() {
  local p; p="$(project)"
  export TZ=UTC
  run_stop "res-sess" "$(tl_fixture limit_five_hour.jsonl)" "$p" "rate_limit"
  assert_exit 0 "$TL_RC"
  tl_kit resolve --dir "$p"
  assert_exit 0 "$TL_RC" "resolve must succeed"
  assert_file_contains "$p/HANDOFF.md" "limit=\"five_hour\" resets=\"$FIVE_EPOCH\" status=\"resolved\"" "attributes kept, status changed"
  assert_file_not_contains "$p/HANDOFF.md" 'status="unresolved"' "no unresolved block is left"
  tl_run "$TL_HOOK_PROMPT" "$(tl_payload_plain UserPromptSubmit "res-sess" "$p" "")"
  assert_not_contains "$TL_OUT" "unresolved cut-off" "the prompt hook no longer warns"
}

test_status_and_resolve_work_on_old_block() {
  local p; p="$(project)"
  printf '%s\n' '# H' '<!-- limit-handoff:cutoff session="old-two" at="2026-10-29 10:00" error="rate_limit" status="unresolved" -->' \
    '> ⚠️ **Session cut off** (usage limit reached) at 2026-10-29 10:00.' '<!-- /limit-handoff:cutoff -->' > "$p/HANDOFF.md"
  tl_kit status --dir "$p"
  assert_exit 0 "$TL_RC"
  assert_contains "$TL_OUT" "Unresolved cut-offs: 1" "status counts the old block"
  tl_kit resolve --dir "$p"
  assert_exit 0 "$TL_RC"
  assert_file_contains "$p/HANDOFF.md" 'status="resolved"' "old block resolved"
}

test_plain_run_logs_no_limit_details() {
  local p; p="$(project)"
  run_stop "log-plain" "$(tl_fixture basic.jsonl)" "$p" "rate_limit"
  assert_file_not_contains "$LIMIT_HANDOFF_STATE_DIR/limit-handoff.log" "limit details:" "no detail logged without a detail"
}

run_tests
