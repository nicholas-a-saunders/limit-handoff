#!/bin/bash
# tests/run.sh - runs every tests/test_*.sh file.
#
#   /bin/bash tests/run.sh
#
# Pure bash and jq. No network. The real HOME is never used: every test gets a
# temp HOME, temp XDG folders and a temp state folder inside tests/.tmp.
# tests/.tmp is removed when the run ends.

ROOT="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_TMP="$ROOT/tests/.tmp"
rm -rf "$RUN_TMP"
mkdir -p "$RUN_TMP"
trap 'rm -rf "$RUN_TMP"' EXIT

# A PATH with system tools but no jq and no clipboard or notification tools.
# Used by the tests that check the hooks still work when jq is missing.
NOJQ="$RUN_TMP/nojq-bin"
mkdir -p "$NOJQ"
for d in /bin /usr/bin; do
  for f in "$d"/*; do
    n="${f##*/}"
    case "$n" in
      jq|pbcopy|osascript|notify-send|wl-copy|xclip|xsel|terminal-notifier|clip.exe) continue ;;
    esac
    if [ -x "$f" ] && [ ! -d "$f" ] && [ ! -e "$NOJQ/$n" ]; then
      ln -s "$f" "$NOJQ/$n" 2>/dev/null
    fi
  done
done

if ! command -v jq >/dev/null 2>&1; then
  echo "tests need jq on PATH" >&2
  exit 1
fi

export HK_TEST_RUN_TMP="$RUN_TMP"
# Test folders are inside this repository. Git must not find the repository from them.
export GIT_CEILING_DIRECTORIES="$RUN_TMP"
export HK_TEST_NOJQ_BIN="$NOJQ"

status=0
for t in "$ROOT"/tests/test_*.sh; do
  echo "== $(basename "$t")"
  /bin/bash "$t" || status=1
done

pass=0; failc=0
if [ -f "$RUN_TMP/results" ]; then
  while read -r p f; do
    pass=$((pass + p))
    failc=$((failc + f))
  done < "$RUN_TMP/results"
fi
echo ""
echo "TOTAL: $pass passed, $failc failed"
if [ "$status" -ne 0 ] || [ "$failc" -ne 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
exit 0
