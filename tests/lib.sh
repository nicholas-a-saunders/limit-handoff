#!/usr/bin/env bash
# tests/lib.sh - assertion helpers and a small runner. Sourced by tests/test_*.sh.
#
# Each test_* function runs in its own subshell with a fresh folder under
# tests/.tmp, a temp HOME and temp XDG folders, and a state folder inside tests/.tmp.
# The real HOME is never used. Any failed assertion exits the test with status 1.

TL_ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TL_SHIMS="$TL_ROOT/tests/shims"
TL_KIT="$TL_ROOT/bin/limit-handoff"
TL_HOOK_STOP="$TL_ROOT/hooks/stop-failure.sh"
TL_HOOK_PROMPT="$TL_ROOT/hooks/prompt-submit.sh"
TL_HOOK_SESSION="$TL_ROOT/hooks/session-start.sh"
TL_HOOK_COMPACT="$TL_ROOT/hooks/pre-compact.sh"
TL_FIX="$TL_ROOT/tests/fixtures"
TL_RUN_TMP="${HK_TEST_RUN_TMP:-$TL_ROOT/tests/.tmp}"
TL_NOJQ_BIN="${HK_TEST_NOJQ_BIN:-}"
TL_PATH_FULL="$TL_SHIMS:${PATH}"

# ---------------------------------------------------------------------------
# Assertions. Each one exits the current test with status 1 on failure.
# ---------------------------------------------------------------------------

fail() {
  echo "    FAILED: $*" >&2
  exit 1
}

assert_eq() {
  # assert_eq expected actual [message]
  if [ "$1" != "$2" ]; then
    echo "    expected: [$1]" >&2
    echo "    actual:   [$2]" >&2
    fail "${3:-values differ}"
  fi
}

assert_contains() {
  # assert_contains haystack needle [message]
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  echo "    needle:   [$2]" >&2
  echo "    haystack: [$(printf '%s' "$1" | head -c 600)]" >&2
  fail "${3:-text not found}"
}

assert_not_contains() {
  case "$1" in
    *"$2"*)
      echo "    unwanted: [$2]" >&2
      fail "${3:-unwanted text was found}" ;;
  esac
  return 0
}

assert_file_exists() {
  [ -f "$1" ] || fail "${2:-file missing: $1}"
}

assert_file_missing() {
  [ ! -e "$1" ] || fail "${2:-file should not exist: $1}"
}

assert_file_contains() {
  # assert_file_contains file needle [message]
  [ -f "$1" ] || fail "file missing: $1"
  grep -F -q -- "$2" "$1" || { echo "    needle: [$2]" >&2; echo "    file: $1" >&2; fail "${3:-text not in file}"; }
}

assert_file_not_contains() {
  [ -f "$1" ] || return 0
  if grep -F -q -- "$2" "$1"; then
    echo "    unwanted: [$2] in $1" >&2
    fail "${3:-unwanted text in file}"
  fi
}

assert_count() {
  # assert_count file needle expected [message]
  local n
  n="$(grep -F -c -- "$2" "$1" 2>/dev/null)"
  n="${n:-0}"
  assert_eq "$3" "$n" "${4:-wrong number of lines containing [$2] in $1}"
}

assert_exit() {
  # assert_exit expected actual [message]
  assert_eq "$1" "$2" "${3:-exit status differs}"
}

assert_same_file() {
  cmp -s "$1" "$2" || fail "${3:-files differ: $1 and $2}"
}

assert_json() {
  # assert_json file jq_filter expected [message]  (filter must print one raw line)
  local got
  got="$(jq -r "$2" "$1" 2>/dev/null)"
  assert_eq "$3" "$got" "${4:-json value differs for $2}"
}

# ---------------------------------------------------------------------------
# Setup helpers
# ---------------------------------------------------------------------------

# tl_setup: a clean world for one test. Call from inside the test subshell.
tl_setup() {
  local v
  for v in $(env | sed -n 's/^\(LIMIT_HANDOFF_[A-Z_]*\)=.*/\1/p'); do
    unset "$v"
  done
  unset CLAUDE_PLUGIN_DATA
  # A CLAUDE_CONFIG_DIR from the person running the tests must not change the defaults.
  unset CLAUDE_CONFIG_DIR
  # Plugin mode is the default in tests: hook messages name the command "limit-handoff".
  # A test that needs the settings-file mode (a full path) unsets this first.
  export CLAUDE_PLUGIN_ROOT="$TL_ROOT"
  # The test folders sit inside this repository (tests/.tmp). Git must not walk up into it, or
  # every test project would look like part of the kit's own repository.
  export GIT_CEILING_DIRECTORIES="$TL_TMP"
  export HOME="$TL_TMP/home"
  mkdir -p "$HOME"
  export XDG_CONFIG_HOME="$TL_TMP/xdg-config"
  export XDG_STATE_HOME="$TL_TMP/xdg-state"
  export LIMIT_HANDOFF_STATE_DIR="$TL_TMP/state"
  export CLAUDE_PROJECT_DIR="$TL_TMP/project"
  mkdir -p "$CLAUDE_PROJECT_DIR" "$TL_TMP/shimout"
  export TEST_OUT="$TL_TMP/shimout"
  export LIMIT_HANDOFF_CLIPBOARD=off
  export LIMIT_HANDOFF_NOTIFY=off
  export PATH="$TL_PATH_FULL"
  cd "$TL_TMP" || fail "cannot enter $TL_TMP"
}

# tl_use_clipboard / tl_use_notify: turn on the shims for this test.
tl_use_clipboard() { export LIMIT_HANDOFF_CLIPBOARD=auto; }
tl_use_notify() { export LIMIT_HANDOFF_NOTIFY=auto; }

# tl_ensure_nojq: builds the no-jq folder of links if run.sh has not already.
tl_ensure_nojq() {
  local base="${TL_NOJQ_BIN:-$TL_ROOT/tests/.tmp/nojq-bin}" d f n
  if [ ! -d "$base" ]; then
    mkdir -p "$base"
    for d in /bin /usr/bin; do
      for f in "$d"/*; do
        n="${f##*/}"
        case "$n" in
          jq|pbcopy|osascript|notify-send|wl-copy|xclip|xsel|terminal-notifier|clip.exe) continue ;;
        esac
        if [ -x "$f" ] && [ ! -d "$f" ] && [ ! -e "$base/$n" ]; then ln -s "$f" "$base/$n" 2>/dev/null; fi
      done
    done
  fi
  TL_NOJQ_BIN="$base"
}

# tl_use_nojq: a PATH with every system tool except jq and clipboard/notify tools.
tl_use_nojq() {
  tl_ensure_nojq
  export PATH="$TL_SHIMS:$TL_NOJQ_BIN"
}

# tl_payload_stop session transcript cwd error
tl_payload_stop() {
  jq -n --arg s "$1" --arg t "$2" --arg c "$3" --arg e "$4" \
    '{session_id: $s, transcript_path: $t, cwd: $c, hook_event_name: "StopFailure"}
     + (if $e == "" then {} else {error: $e} end)'
}

# tl_payload_plain event session cwd source
tl_payload_plain() {
  jq -n --arg ev "$1" --arg s "$2" --arg c "$3" --arg src "$4" \
    '{session_id: $s, cwd: $c, hook_event_name: $ev}
     + (if $src == "" then {} else {source: $src} end)'
}

# tl_run script payload: runs a hook with the payload on stdin.
# Sets TL_RC, TL_OUT (stdout) and TL_ERR (stderr).
tl_run() {
  local script="$1" payload="$2"
  printf '%s' "$payload" | /bin/bash "$script" > "$TL_TMP/run.out" 2> "$TL_TMP/run.err"
  TL_RC=$?
  TL_OUT="$(cat "$TL_TMP/run.out")"
  TL_ERR="$(cat "$TL_TMP/run.err")"
}

# tl_kit args...: runs the command line tool. Sets TL_RC, TL_OUT, TL_ERR.
tl_kit() {
  /bin/bash "$TL_KIT" "$@" > "$TL_TMP/kit.out" 2> "$TL_TMP/kit.err"
  TL_RC=$?
  TL_OUT="$(cat "$TL_TMP/kit.out")"
  TL_ERR="$(cat "$TL_TMP/kit.err")"
}

# tl_make_project: a project folder whose name has a space in it. Sets TL_PROJ and
# exports CLAUDE_PROJECT_DIR in the current shell (do not call it inside $( )).
tl_make_project() {
  TL_PROJ="$TL_TMP/my project"
  mkdir -p "$TL_PROJ"
  export CLAUDE_PROJECT_DIR="$TL_PROJ"
}

# tl_fixture name: prints the path of a fixture transcript.
tl_fixture() { printf '%s\n' "$TL_FIX/$1"; }

# tl_write file: writes stdin to a file (creates folders).
tl_write() {
  mkdir -p "$(dirname "$1")"
  cat > "$1"
}

# tl_time_limit seconds: the time limit for a speed test. Shared CI machines can be several times
# slower than a laptop, so CI sets HK_TEST_TIME_SCALE (a whole number, default 1), and every speed
# limit is multiplied by it. Local runs keep the limit from the spec.
tl_time_limit() {
  local scale="${HK_TEST_TIME_SCALE:-1}"
  case "$scale" in ''|*[!0-9]*|0) scale=1 ;; esac
  perl -e "print $1 * $scale"
}

# tl_hk_version: the HK_VERSION value in lib/common.sh. The file is read as text, not sourced.
tl_hk_version() {
  sed -n 's/^HK_VERSION="\([^"]*\)".*/\1/p' "$TL_ROOT/lib/common.sh" | head -n 1
}

# tl_file_mode file: prints the permission bits in octal (600, 644, ...). BSD stat (macOS) and
# GNU stat (Ubuntu) take different flags, so this branches on the OS like hk_file_mode does.
tl_file_mode() {
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

# run_tests: runs every test_* function of the current file, prints PASS/FAIL,
# and records "pass fail" in the run results file.
run_tests() {
  local fn out rc pass=0 failc=0 names
  names="$(declare -F | awk '{print $3}' | grep '^test_')"
  for fn in $names; do
    TL_TMP="$TL_RUN_TMP/t-$fn"
    rm -rf "$TL_TMP"
    mkdir -p "$TL_TMP"
    out="$( ( tl_setup; "$fn" ) 2>&1 )"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      pass=$((pass + 1))
      echo "  PASS $fn"
    else
      failc=$((failc + 1))
      echo "  FAIL $fn"
      printf '%s\n' "$out" | sed 's/^/      /'
    fi
    rm -rf "$TL_TMP"
  done
  echo "  $(basename "$0"): $pass passed, $failc failed"
  mkdir -p "$TL_RUN_TMP"
  echo "$pass $failc" >> "$TL_RUN_TMP/results"
  [ "$failc" -eq 0 ]
}
