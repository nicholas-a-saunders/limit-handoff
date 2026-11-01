#!/bin/bash
# test_attack_spec_next_step.sh - adversarial SPEC conformance tests for next-step parsing
# (hk_first_next_step in lib/common.sh).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# first_step text_file: prints the first next step, using the shipped function.
first_step() {
  /bin/bash -c '. "$1/lib/common.sh"; hk_first_next_step "$2"' _ "$TL_ROOT" "$1"
}

# SPEC (next-step parsing): "first list item under a heading matching ^## Next steps until next ## ;
# strip leading `1. ` / `- ` / `* ` / checkbox". Passing regression guard for each form.
test_attack_spec_next_step_strips_every_listed_marker_form() {
  local f="$TL_TMP/forms.md" got
  printf '%s\n' '## Next steps' '1. Numbered dot' > "$f"; assert_eq "Numbered dot" "$(first_step "$f")"
  printf '%s\n' '## Next steps' '- Dash item' > "$f"; assert_eq "Dash item" "$(first_step "$f")"
  printf '%s\n' '## Next steps' '* Star item' > "$f"; assert_eq "Star item" "$(first_step "$f")"
  printf '%s\n' '## Next steps' '- [ ] Open box' > "$f"; assert_eq "Open box" "$(first_step "$f")"
  printf '%s\n' '## Next steps' '2. [~] Half done box' > "$f"; assert_eq "Half done box" "$(first_step "$f")"
  printf '%s\n' '## Next steps' '-   [ ]   Spaced box' > "$f"; assert_eq "Spaced box" "$(first_step "$f")"
}

# SPEC (next-step parsing): "until next ## ". A list item under a later heading must not be returned.
# Passing regression guard.
test_attack_spec_next_step_stops_at_the_next_level_two_heading() {
  local f="$TL_TMP/stop.md"
  printf '%s\n' '## Goal' '- Not a step' '## Next steps' 'Some prose only.' '## Done so far' '- Done item' > "$f"
  assert_eq "" "$(first_step "$f")" "prose and items outside the section are not steps"
}

# SPEC (next-step parsing): no section gives an empty result, so the caller uses its fallback.
# Passing regression guard.
test_attack_spec_next_step_empty_when_there_is_no_section() {
  local f="$TL_TMP/nosec.md"
  printf '%s\n' '# Title' '- A bullet' '1. A number' > "$f"
  assert_eq "" "$(first_step "$f")"
  assert_eq "" "$(first_step "$TL_TMP/does-not-exist.md")" "a missing file gives an empty result"
}

# SPEC (next-step parsing): an empty item is skipped, not returned. Passing regression guard.
test_attack_spec_next_step_skips_empty_items() {
  local f="$TL_TMP/empty.md"
  printf '%s\n' '## Next steps' '1. ' '2. Real step' > "$f"
  assert_eq "Real step" "$(first_step "$f")"
}

# SPEC (next-step parsing): a line such as "1.5 GB of logs" is not a list item. Passing regression guard.
test_attack_spec_next_step_ignores_decimal_numbers_in_prose() {
  local f="$TL_TMP/decimal.md"
  printf '%s\n' '## Next steps' '1.5 GB of logs to check' '2. Real step' > "$f"
  assert_eq "Real step" "$(first_step "$f")"
}

# SPEC (next-step parsing): Windows line endings must not leave a carriage return in the step.
# Passing regression guard.
test_attack_spec_next_step_handles_crlf_line_endings() {
  local f="$TL_TMP/crlf.md"
  printf '## Next steps\r\n1. Write tests\r\n' > "$f"
  assert_eq "Write tests" "$(first_step "$f")"
}

# SPEC (next-step parsing): indented numbered items still count. Passing regression guard.
test_attack_spec_next_step_accepts_indented_items() {
  local f="$TL_TMP/indent.md"
  printf '%s\n' '## Next steps' '   2. Indented step' > "$f"
  assert_eq "Indented step" "$(first_step "$f")"
}

# SPEC (next-step parsing): "strip ... checkbox". A finished checkbox item is not a next step, and the
# paste prompt says "Do not redo finished steps". The literal rule takes the first item, so this is a
# sensible-reading check. Severity: minor (spec says "first list item"; reviewer to decide).
test_attack_spec_next_step_skips_checked_items() {
  local f="$TL_TMP/checked.md"
  printf '%s\n' '## Next steps' '1. [x] Already done' '2. [ ] Real next step' > "$f"
  assert_eq "Real next step" "$(first_step "$f")" "a checked item must not be the next step"
}

run_tests
