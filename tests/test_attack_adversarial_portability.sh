#!/bin/bash
# Adversarial tests: inputs chosen to break the kit.
# Area: static checks. bash 3.2 rules, no eval, no data used as a printf format, hooks exit 0.
# Rules come from docs/SPEC.md (Hard constraints).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The shipped code that runs on a user's Mac.
ADV_SHIPPED="bin/limit-handoff lib/common.sh hooks/stop-failure.sh hooks/prompt-submit.sh hooks/session-start.sh hooks/pre-compact.sh tests/run.sh tests/lib.sh tests/shims/pbcopy tests/shims/osascript tests/shims/wl-copy tests/shims/notify-send"

# adv_code_hits pattern file...: matches of an extended regex on code lines (comments skipped).
adv_code_hits() {
  local pat="$1" f
  shift
  for f in "$@"; do
    grep -nE -- "$pat" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$(basename "$f"):|"
  done
}

test_no_bash4_only_constructs_in_shipped_code() {
  local pat hits files=""
  pat='mapfile|readarray|declare -[An]|local -[An]|[$][{][A-Za-z_][A-Za-z0-9_]*(,,|[\^][\^]|,|[\^])[}]|&>>|[|]&|;;&|;&|[[] -v |wait -n|coproc|EPOCHSECONDS|EPOCHREALTIME|SRANDOM|[$][{][A-Za-z_]+@[QEPAa][}]|read[^|;]* -t [0-9]*[.][0-9]|printf[^|;]*%[(]'
  for f in $ADV_SHIPPED; do files="$files $TL_ROOT/$f"; done
  hits="$(adv_code_hits "$pat" $files)"
  [ -z "$hits" ] || fail "bash 4+ only construct found (macOS /bin/bash is 3.2): $hits"
}

test_every_shell_file_parses_under_bin_bash() {
  local f bad=""
  for f in $ADV_SHIPPED "$TL_ROOT"/tests/test_*.sh; do
    case "$f" in
      /*) ;;
      *) f="$TL_ROOT/$f" ;;
    esac
    if ! /bin/bash -n "$f" 2>/dev/null; then bad="$bad $f"; fi
  done
  [ -z "$bad" ] || fail "these files do not parse under /bin/bash:$bad"
}

test_no_eval_in_shipped_code() {
  local hits files=""
  for f in $ADV_SHIPPED; do files="$files $TL_ROOT/$f"; done
  hits="$(adv_code_hits '(^|[^A-Za-z_])eval[[:space:]]' $files)"
  [ -z "$hits" ] || fail "eval found in shipped code: $hits"
}

test_hooks_never_use_set_e() {
  local hits
  hits="$(adv_code_hits '^[[:space:]]*set[[:space:]]+-[A-Za-z]*e' "$TL_ROOT"/hooks/*.sh "$TL_ROOT/lib/common.sh")"
  [ -z "$hits" ] || fail "set -e in a hook (a hook must never stop half way): $hits"
}

test_no_data_is_used_as_a_printf_format() {
  local hits
  hits="$(adv_code_hits 'printf[[:space:]]+("[$]|[$]|'"'"'[$])' "$TL_ROOT"/hooks/*.sh "$TL_ROOT/lib/common.sh" "$TL_ROOT/bin/limit-handoff")"
  [ -z "$hits" ] || fail "a variable is used as a printf format string (text such as %s would be misread): $hits"
}

test_every_hook_ends_with_exit_zero_and_uses_the_bash_shebang() {
  local h last
  for h in "$TL_ROOT"/hooks/*.sh; do
    last="$(grep -v '^[[:space:]]*$' "$h" | tail -n 1)"
    assert_eq "exit 0" "$last" "$(basename "$h") must end with exit 0"
    assert_eq "#!/usr/bin/env bash" "$(head -n 1 "$h")" "$(basename "$h") must use the bash shebang from SPEC"
  done
}

run_tests
