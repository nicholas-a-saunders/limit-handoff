#!/usr/bin/env bash
# lib/common.sh - shared helpers for limit-handoff.
#
# This file is sourced by every hook and by bin/limit-handoff. Never run it directly.
# Rules followed here:
#   - bash 3.2 compatible (macOS /bin/bash). No associative arrays, no mapfile.
#   - No `eval`, no `source` of transcript, HANDOFF.md or config content.
#   - Every path is quoted. User text is passed to awk/jq through environment
#     variables or arguments, never pasted into shell code.
#   - Writes are atomic (temp file in the same folder, then mv).
#   - Functions return a status; callers decide what to do. Nothing here calls exit.

HK_LIB_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HK_ROOT="$(CDPATH='' cd "$HK_LIB_DIR/.." && pwd)"
# Read by bin/limit-handoff, which sources this file. ShellCheck cannot see that read.
# shellcheck disable=SC2034
HK_VERSION="1.0.2"
HK_DEFAULT_ERRORS="rate_limit billing_error unknown overloaded server_error"
# Every StopFailure code Claude Code can send. Only these may be shown back to Claude or the user.
# prompt_too_long is not a Claude Code code. The kit makes it for catch-up (see hk_catchup).
HK_STOP_CODES="rate_limit overloaded billing_error invalid_request authentication_failed oauth_org_not_allowed account_on_hold model_not_found server_error max_output_tokens cloud_credential_error prompt_too_long unknown"
HK_CONF_KEY_RE='^LIMIT_HANDOFF_[A-Z_]+$'
# The most transcript bytes that are read for recovery (32 MB). See hk_recover_json.
HK_TAIL_BYTES=33554432

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

# hk_have_jq: succeeds when a working jq is on PATH.
hk_have_jq() {
  command -v jq >/dev/null 2>&1 && jq --version >/dev/null 2>&1
}

# hk_in_list needle word...: succeeds when needle equals one of the words.
hk_in_list() {
  local needle="$1" word
  shift
  for word in "$@"; do
    if [ "$word" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

# hk_clean_token text: keeps only letters, digits, "_" and "-"; max 40 chars.
# Used for session ids and error codes that end up inside HANDOFF.md.
hk_clean_token() {
  printf '%s' "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-40
}

# hk_valid_cmd_name name: a bare command name such as pbcopy (no slashes, no spaces).
hk_valid_cmd_name() {
  local re='^[A-Za-z0-9._-]+$'
  [[ "$1" =~ $re ]]
}

# hk_now_iso / hk_now_human / hk_now_stamp: timestamps used in files.
hk_now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
hk_now_human() { date '+%Y-%m-%d %H:%M'; }
hk_now_stamp() { date '+%Y%m%d-%H%M%S'; }

# hk_file_age_min path: whole minutes since the file was last modified.
# Prints -1 when the file cannot be read.
hk_file_age_min() {
  local f="$1" mtime now
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    mtime="$(stat -f %m "$f" 2>/dev/null)"
  else
    mtime="$(stat -c %Y "$f" 2>/dev/null)"
  fi
  case "$mtime" in
    ''|*[!0-9]*) printf '%s\n' "-1"; return 1 ;;
  esac
  now="$(date +%s)"
  local age=$(( (now - mtime) / 60 ))
  if [ "$age" -lt 0 ]; then age=0; fi
  printf '%s\n' "$age"
}

# hk_file_mtime path: prints the last-modified time of a file as Unix seconds.
# Fails (prints nothing) when the time cannot be read.
hk_file_mtime() {
  local mtime
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    mtime="$(stat -f %m "$1" 2>/dev/null)"
  else
    mtime="$(stat -c %Y "$1" 2>/dev/null)"
  fi
  case "$mtime" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$mtime"
}

# hk_safe_rel path: succeeds only for a relative path that stays inside the project.
# Rejects absolute paths, trailing "/" (a folder, not a file), "." and ".." parts,
# double slashes, the ".git" and ".claude" folders, and characters outside a small safe set.
hk_safe_rel() {
  local p="$1" re='^[A-Za-z0-9._/ -]+$' lower
  [ -n "$p" ] || return 1
  case "$p" in
    /*|*/) return 1 ;;
  esac
  case "$p" in
    *//*) return 1 ;;
  esac
  case "/$p/" in
    */../*|*/./*) return 1 ;;
  esac
  # macOS folders ignore case, so ".Claude" or ".GIT" is the same folder as ".claude" or ".git".
  # The .claude and .git checks therefore use a lowercase copy of the path (bash 3.2 safe).
  lower="$(printf '%s' "/$p/" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    */.git/*|*/.claude/*) return 1 ;;
  esac
  [[ "$p" =~ $re ]] || return 1
  return 0
}

# hk_real_path path: prints the physical path, following symlinks (up to 20 hops).
# Works for paths that do not exist yet. The nearest folder that exists is resolved (links
# included), and the names that do not exist yet are added back to it. So a path under a folder
# that is still to be made is checked against the real location of the project.
# A dangling link on the way (a link to nothing) prints nothing: its target cannot be checked,
# so callers must treat an empty answer as "not inside the project".
hk_real_path() {
  local p="$1" hops=0 target dir name rest="" up
  case "$p" in -*) p="./$p" ;; esac
  while [ -L "$p" ] && [ "$hops" -lt 20 ]; do
    target="$(readlink "$p" 2>/dev/null)" || break
    [ -n "$target" ] || break
    case "$target" in
      /*) p="$target" ;;
      *) p="$(dirname "$p")/$target" ;;
    esac
    hops=$((hops + 1))
  done
  dir="$(dirname "$p")"
  name="$(basename "$p")"
  while [ ! -d "$dir" ]; do
    if [ -L "$dir" ]; then return 0; fi
    up="$(dirname "$dir")"
    if [ "$up" = "$dir" ]; then break; fi
    rest="/$(basename "$dir")$rest"
    dir="$up"
  done
  case "$dir" in
    /*) ;;
    *) dir="./$dir" ;;
  esac
  dir="$(CDPATH='' cd -P "$dir" 2>/dev/null && pwd -P)" || return 0
  if [ "$dir" = "/" ]; then dir=""; fi
  printf '%s%s/%s\n' "$dir" "$rest" "$name"
}

# hk_inside_project path: succeeds when the real location of path is inside the project folder.
# A symlink that points somewhere else makes this fail.
hk_inside_project() {
  local real base
  base="$(CDPATH='' cd -P "$HK_PROJECT_DIR" 2>/dev/null && pwd -P)" || return 1
  [ -n "$base" ] || return 1
  real="$(hk_real_path "$1")"
  case "$real" in
    "$base"/*) return 0 ;;
  esac
  return 1
}

# hk_abs_path rel: a project-relative name made absolute. Absolute names are returned as they are.
hk_abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$HK_PROJECT_DIR" "$1" ;;
  esac
}

# hk_expand_home path: turns a leading "~" into $HOME. Other paths are returned unchanged.
hk_expand_home() {
  case "$1" in
    "~") printf '%s\n' "${HOME:-}" ;;
    \~/*) printf '%s/%s\n' "${HOME:-}" "${1#\~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# hk_file_mode path: prints the permission bits in octal (for example 600). Empty when unknown.
hk_file_mode() {
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

# hk_atomic_write dest: reads stdin and replaces dest with it.
# - A symlink is followed, so the file it points to is the one that changes and the link stays.
# - The text goes to a temp file in the same folder first, then mv renames it over the target.
#   mktemp makes the temp file with a random name and O_EXCL, so a link planted at a guessable
#   temp name can never send the text to another file.
# - The permission bits of an existing file are kept (a 600 file stays 600). A new file gets the
#   usual bits for the user's umask, as if it was made with ">". A caller can set HK_NEW_MODE
#   (for example 600) for a new file that holds chat text: then only the user can read it.
# - A folder is never replaced. Returns non-zero on any failure, and leaves dest as it was.
hk_atomic_write() {
  local dest mode="" tmp
  dest="$(hk_real_path "$1")"
  if [ -z "$dest" ]; then
    return 1
  fi
  if [ -d "$dest" ]; then
    return 1
  fi
  if [ -e "$dest" ]; then
    mode="$(hk_file_mode "$dest")"
  elif [ -n "${HK_NEW_MODE:-}" ]; then
    mode="$HK_NEW_MODE"
  else
    mode="$(printf '%o' "$(( 0666 & ~$(umask) ))")"
  fi
  tmp="$(mktemp "$dest.tmp.XXXXXX" 2>/dev/null)" || return 1
  if [ -z "$tmp" ] || [ ! -f "$tmp" ] || [ -L "$tmp" ]; then
    return 1
  fi
  # The 2>/dev/null comes before the > redirect on purpose: then a failed open of the temp file
  # is silent too. (The other way round, bash reports that failure on the real stderr.)
  if ! cat 2>/dev/null > "$tmp"; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  if [ -n "$mode" ]; then
    chmod "$mode" "$tmp" 2>/dev/null
  fi
  if ! mv -f "$tmp" "$dest" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  return 0
}

# hk_lock_take file: waits for a lock on this file (a lock file inside the state folder).
# Two hooks can run at the same moment when several chats hit a limit together, so
# every read-then-write of HANDOFF.md runs under this lock.
# The lock file is made with bash's noclobber option: bash opens it with O_CREAT|O_EXCL, so
# exactly one process can make it. It holds the owner's process id. mkdir is not used: the Rust
# mkdir in Ubuntu 26.04 (uutils) lets two processes both "create" the same folder.
# A lock whose owner has ended is removed (checked about once a second). A lock that is still
# there after about 10 seconds is broken. If no lock can be made at all (the state folder is not
# writable), the caller goes on without one.
hk_lock_take() {
  local target key dir lock tries=0 holder
  HK_LOCK_FILE=""
  target="$(hk_real_path "$1")"
  key="$(printf '%s' "$target" | cksum | tr -s ' \t' '__' | tr -cd '0-9_')"
  dir="$(hk_state_dir)/locks"
  mkdir -p "$dir" 2>/dev/null || return 1
  lock="$dir/$key.lock"
  # A folder with this name is a lock left by an older version of the kit, which used mkdir.
  if [ -d "$lock" ]; then rmdir "$lock" 2>/dev/null; fi
  while ! ( set -o noclobber; printf '%s\n' "$$" > "$lock" ) 2>/dev/null; do
    tries=$((tries + 1))
    if [ $((tries % 20)) -eq 0 ]; then
      holder="$(cat "$lock" 2>/dev/null)"
      case "$holder" in ''|*[!0-9]*) holder="" ;; esac
      if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        # Only remove it when it still names the same ended process.
        if [ "$(cat "$lock" 2>/dev/null)" = "$holder" ]; then
          hk_log warn "removing a lock left by a process that has ended: $lock"
          rm -f "$lock" 2>/dev/null
        fi
        continue
      fi
    fi
    if [ "$tries" -gt 200 ]; then
      hk_log warn "breaking a lock held for more than 10 seconds: $lock"
      rm -f "$lock" 2>/dev/null
      ( set -o noclobber; printf '%s\n' "$$" > "$lock" ) 2>/dev/null || return 1
      break
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
  HK_LOCK_FILE="$lock"
  return 0
}

# hk_lock_release: removes the lock taken by hk_lock_take, if there is one and it is still ours.
# A lock that another process broke and took over is left alone.
hk_lock_release() {
  if [ -n "${HK_LOCK_FILE:-}" ] && [ "$(cat "$HK_LOCK_FILE" 2>/dev/null)" = "$$" ]; then
    rm -f "$HK_LOCK_FILE" 2>/dev/null
  fi
  HK_LOCK_FILE=""
  return 0
}

# hk_render_template file KEY=VALUE...
# Replaces {{KEY}} with VALUE in one pass, left to right. Values are never
# scanned again, so a value that contains {{OTHER}} or %s stays literal.
# Values travel through environment variables, so no quoting is needed.
hk_render_template() {
  local file="$1" kv k v
  # Lengths and cuts below are in bytes, not characters: the limit that matters is the size of one
  # environment string. awk only copies text here, so the C locale does not change the output.
  local LC_ALL=C
  shift
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    if [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      # A value over 100 KB is cut, and the cut shows in the output.
      if [ "${#v}" -gt 100000 ]; then v="${v:0:100000} [cut]"; fi
      export "HK_VAL_$k=$v"
    fi
  done
  awk '
    {
      s = $0; out = ""
      while ((i = index(s, "{{")) > 0) {
        rest = substr(s, i + 2)
        j = index(rest, "}}")
        if (j == 0) break
        key = substr(rest, 1, j - 1)
        out = out substr(s, 1, i - 1)
        if (key ~ /^[A-Z][A-Z0-9_]*$/ && (("HK_VAL_" key) in ENVIRON)) {
          out = out ENVIRON["HK_VAL_" key]
        } else {
          out = out "{{" key "}}"
        }
        s = substr(rest, j + 2)
      }
      print out s
    }' "$file"
  local status=$?
  for kv in "$@"; do
    k="${kv%%=*}"
    if [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      unset "HK_VAL_$k"
    fi
  done
  return $status
}

# ---------------------------------------------------------------------------
# Command name, versions and plugin checks
# ---------------------------------------------------------------------------

# hk_cli_hint: prints the command Claude should type to run this kit's CLI.
# When the kit runs as a plugin (CLAUDE_PLUGIN_ROOT is this same folder), bin/ is on Claude's
# Bash PATH, so the plain name works. Otherwise (a settings.json install) the full path is
# printed. A path with a space or a single quote is wrapped in single quotes, and a single
# quote inside it is written as '\'' so the shell reads it back as the same path.
hk_cli_hint() {
  local plug real_plug real_root path
  plug="${CLAUDE_PLUGIN_ROOT:-}"
  if [ -n "$plug" ]; then
    real_plug="$(hk_real_path "$plug")"
    real_root="$(hk_real_path "$HK_ROOT")"
    if [ -n "$real_plug" ] && [ "$real_plug" = "$real_root" ]; then
      printf 'limit-handoff\n'
      return 0
    fi
  fi
  path="$HK_ROOT/bin/limit-handoff"
  case "$path" in
    *" "*|*"'"*)
      printf "'%s'\n" "$(printf '%s' "$path" | sed "s/'/'\\\\''/g")" ;;
    *)
      printf '%s\n' "$path" ;;
  esac
}

# hk_version_at_least have need: succeeds when a version such as 2.1.312 is at least need.
# Both must be plain x.y.z numbers. Anything else fails.
hk_version_at_least() {
  local have="$1" need="$2" hv nv re='^([0-9]+)\.([0-9]+)\.([0-9]+)$'
  [[ "$have" =~ $re ]] || return 1
  hv=$(( 10#${BASH_REMATCH[1]} * 1000000000 + 10#${BASH_REMATCH[2]} * 1000000 + 10#${BASH_REMATCH[3]} ))
  [[ "$need" =~ $re ]] || return 1
  nv=$(( 10#${BASH_REMATCH[1]} * 1000000000 + 10#${BASH_REMATCH[2]} * 1000000 + 10#${BASH_REMATCH[3]} ))
  [ "$hv" -ge "$nv" ]
}

# hk_plugin_enabled file: succeeds when the settings file turns a limit-handoff plugin on.
# That is an "enabledPlugins" key that starts with "limit-handoff@" and has the value true.
# Reads only. A missing, unreadable or invalid file counts as not enabled.
hk_plugin_enabled() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  hk_have_jq || return 1
  jq -e '((.enabledPlugins | type) == "object")
    and (([.enabledPlugins | to_entries[]
           | select((.key | startswith("limit-handoff@")) and (.value == true))] | length) > 0)' \
    "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Logging and state
# ---------------------------------------------------------------------------

# hk_state_dir: prints the state folder (logs and per-session markers). Creates it.
# Default (SPEC Config table): $CLAUDE_PLUGIN_DATA, else $HOME/.local/state/limit-handoff.
# A leading "~" in LIMIT_HANDOFF_STATE_DIR means the home folder.
hk_state_dir() {
  local default dir
  if [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
    default="$CLAUDE_PLUGIN_DATA"
  else
    default="${HOME:-}/.local/state/limit-handoff"
  fi
  dir="$(hk_conf_trusted LIMIT_HANDOFF_STATE_DIR "$default")"
  dir="$(hk_expand_home "$dir")"
  # A new state folder is private (700): the log and the markers name projects and chats.
  if [ ! -d "$dir" ]; then ( umask 077; mkdir -p "$dir" ) 2>/dev/null; fi
  printf '%s\n' "$dir"
}

# hk_user_settings_file: the user's Claude Code settings.json. Claude Code keeps it in
# $CLAUDE_CONFIG_DIR when that is set (some people use one config folder per account), else in
# ~/.claude. Only an absolute CLAUDE_CONFIG_DIR is used.
hk_user_settings_file() {
  case "${CLAUDE_CONFIG_DIR:-}" in
    /*) printf '%s/settings.json\n' "${CLAUDE_CONFIG_DIR%/}" ;;
    *) printf '%s/.claude/settings.json\n' "${HOME:-}" ;;
  esac
}

# hk_log level message: appends one line to the state log. Never fails.
hk_log() {
  local dir msg
  dir="$(hk_state_dir)"
  msg="$(printf '%s' "${2:-}" | tr '\n\r' '  ' | hk_cut_chars 500)"
  # A new log is private (600), like the files that hold chat text.
  if [ ! -e "$dir/limit-handoff.log" ]; then ( umask 077; : >> "$dir/limit-handoff.log" ) 2>/dev/null; fi
  printf '%s %s %s\n' "$(hk_now_iso)" "${1:-info}" "$msg" >> "$dir/limit-handoff.log" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# Configuration
# Order: environment > project file > user file > default.
# Config files are read line by line as KEY=VALUE. They are never executed.
# ---------------------------------------------------------------------------

# _hk_trim text: removes spaces and tabs from both ends. Result goes in HK_TRIM (no subshell).
_hk_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  HK_TRIM="$s"
}

# _hk_conf_read_file file key: prints the value of KEY from a config file.
# The last matching line wins. Returns 1 when the key is not there.
_hk_conf_read_file() {
  local f="$1" key="$2" line val="" found=0 k
  [ -f "$f" ] && [ -r "$f" ] || return 1
  # A real config file is a few hundred bytes. One over 64 KB is skipped: it is read once per key,
  # and a huge file made the StopFailure hook take more than 10 seconds (stress test L5).
  [ "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" -le 65536 ] 2>/dev/null || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    k="${line%%=*}"
    _hk_trim "$k"
    k="$HK_TRIM"
    if [ "$k" = "$key" ]; then
      val="${line#*=}"
      found=1
    fi
  done < "$f"
  [ "$found" = 1 ] || return 1
  val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/\r$//')"
  case "$val" in
    \"*\") val="${val#\"}"; val="${val%\"}" ;;
    \'*\') val="${val#\'}"; val="${val%\'}" ;;
  esac
  printf '%s' "$val"
}

# _hk_conf_env key: prints the environment value of KEY when it is not empty.
_hk_conf_env() {
  local key="$1"
  if [ -n "${!key:-}" ]; then
    printf '%s' "${!key}"
    return 0
  fi
  return 1
}

# hk_conf KEY default: full lookup, including the project file.
hk_conf() {
  local key="$1" def="$2" val user_file
  [[ "$key" =~ $HK_CONF_KEY_RE ]] || { printf '%s\n' "$def"; return 0; }
  if val="$(_hk_conf_env "$key")"; then printf '%s\n' "$val"; return 0; fi
  if [ -n "${HK_PROJECT_DIR:-}" ] && val="$(_hk_conf_read_file "$HK_PROJECT_DIR/.claude/limit-handoff.conf" "$key")" && [ -n "$val" ]; then
    printf '%s\n' "$val"; return 0
  fi
  user_file="${XDG_CONFIG_HOME:-$HOME/.config}/limit-handoff/config"
  if val="$(_hk_conf_read_file "$user_file" "$key")" && [ -n "$val" ]; then
    printf '%s\n' "$val"; return 0
  fi
  printf '%s\n' "$def"
}

# hk_conf_trusted KEY default: like hk_conf but ignores the project file.
# Used for keys that run commands or pick where logs go. A cloned repository
# must not be able to choose those, so only the environment and the user file count.
hk_conf_trusted() {
  local key="$1" def="$2" val user_file
  [[ "$key" =~ $HK_CONF_KEY_RE ]] || { printf '%s\n' "$def"; return 0; }
  if val="$(_hk_conf_env "$key")"; then printf '%s\n' "$val"; return 0; fi
  user_file="${XDG_CONFIG_HOME:-$HOME/.config}/limit-handoff/config"
  if val="$(_hk_conf_read_file "$user_file" "$key")" && [ -n "$val" ]; then
    printf '%s\n' "$val"; return 0
  fi
  printf '%s\n' "$def"
}

# The keys hk_conf_trusted and hk_int_conf_trusted read. A project file may not set them.
HK_USER_ONLY_KEYS="LIMIT_HANDOFF_DEBOUNCE_SEC LIMIT_HANDOFF_FILE LIMIT_HANDOFF_PROMPT_FILE LIMIT_HANDOFF_RECOVER_DIR LIMIT_HANDOFF_TAIL_LINES LIMIT_HANDOFF_KEEP LIMIT_HANDOFF_FOLLOW_LINKS LIMIT_HANDOFF_CLIPBOARD LIMIT_HANDOFF_NOTIFY LIMIT_HANDOFF_STATE_DIR"

# hk_note_ignored_project_keys: logs one warning when the project file sets user-only keys, so
# the user can see why those values had no effect. Only the key names are logged.
hk_note_ignored_project_keys() {
  local f k found=""
  [ -n "${HK_PROJECT_DIR:-}" ] || return 0
  f="$HK_PROJECT_DIR/.claude/limit-handoff.conf"
  [ -f "$f" ] || return 0
  for k in $HK_USER_ONLY_KEYS; do
    if _hk_conf_read_file "$f" "$k" >/dev/null 2>&1; then found="$found $k"; fi
  done
  [ -n "$found" ] || return 0
  hk_log warn "the project file .claude/limit-handoff.conf sets$found. These keys are read only from the environment or your own config, so the project values are ignored."
  return 0
}

# hk_error_list: the StopFailure codes that make a handoff, as words split by spaces
# (LIMIT_HANDOFF_ERRORS; "|", "," and tabs also split). A value with no words in it (for example
# a single space) falls back to the default list, the same as an empty value does.
hk_error_list() {
  local norm
  norm="$(hk_conf LIMIT_HANDOFF_ERRORS "$HK_DEFAULT_ERRORS" | tr '|,\t' '   ')"
  if [ -z "$(printf '%s' "$norm" | tr -d ' ')" ]; then norm="$HK_DEFAULT_ERRORS"; fi
  printf '%s\n' "$norm"
}

# hk_bool_conf KEY default: prints 1 or 0. Accepts 1/0, on/off, yes/no, true/false.
hk_bool_conf() {
  local v
  v="$(hk_conf "$1" "$2")"
  case "$v" in
    1|on|yes|true|ON|YES|TRUE) printf '1\n' ;;
    0|off|no|false|OFF|NO|FALSE) printf '0\n' ;;
    *) printf '%s\n' "$2" ;;
  esac
}

# hk_int_conf KEY default: prints a positive whole number, or the default.
# _hk_int_clean value default: checks one number value. See hk_int_conf for the rules.
_hk_int_clean() {
  local v="$1" z
  # A value longer than 64 characters is not a sane setting. It is refused before any pattern
  # match, because bash pattern matching is slow on a very long string (a cloned repository's
  # config could hold one).
  if [ "${#v}" -gt 64 ]; then printf '%s\n' "$2"; return 0; fi
  case "$v" in
    ''|*[!0-9]*) printf '%s\n' "$2"; return 0 ;;
  esac
  # Leading zeros go, so "08" is the number 8 (bash would read 08 as an invalid octal number).
  # "000" becomes "0". A value with more than 9 digits is not a sane setting: use the default.
  z="${v%%[!0]*}"
  v="${v#"$z"}"
  [ -n "$v" ] || v=0
  if [ "${#v}" -gt 9 ]; then
    printf '%s\n' "$2"
    return 0
  fi
  printf '%s\n' "$v"
}

# hk_int_conf KEY default: a whole number setting (env, project file, user file, or default).
# Only digits count. Leading zeros are removed, and more than 9 digits uses the default.
hk_int_conf() { _hk_int_clean "$(hk_conf "$1" "$2")" "$2"; }

# hk_int_conf_trusted KEY default: like hk_int_conf, but the project file is not read.
# Used for the sizes and counts that decide what is kept or deleted on disk.
hk_int_conf_trusted() { _hk_int_clean "$(hk_conf_trusted "$1" "$2")" "$2"; }

# hk_parent_inside_project rel: succeeds when the folder part of a project-relative name is
# inside the project after links are followed. A folder that does not exist yet is fine, as
# long as the nearest folder that does exist (or the link that stands in for it) resolves
# inside the project. A dangling link counts as outside, because writing through it would
# create folders wherever the link points.
hk_parent_inside_project() {
  local rel="$1" root base d real
  root="${HK_PROJECT_DIR:-$PWD}"
  base="$(CDPATH='' cd -P "$root" 2>/dev/null && pwd -P)" || return 1
  [ -n "$base" ] || return 1
  d="$(dirname "$root/$rel")"
  while [ ! -e "$d" ] && [ ! -L "$d" ] && [ "$d" != "$root" ]; do
    d="$(dirname "$d")"
  done
  real="$(CDPATH='' cd -P "$d" 2>/dev/null && pwd -P)" || return 1
  case "$real/" in
    "$base/"*) return 0 ;;
  esac
  return 1
}

# hk_file_name KEY default: a file name from config, checked to stay in the project.
# The name must be a safe relative path, and its folder must not link outside the project.
# A bad value is logged and replaced by the default.
hk_file_name() {
  local key="$1" def="$2" val
  # Trusted only: a cloned repository must not choose which files the kit writes.
  val="$(hk_conf_trusted "$key" "$def")"
  if ! hk_safe_rel "$val"; then
    hk_log warn "$key='$val' is not a safe path inside the project; using $def"
    printf '%s\n' "$def"
  elif ! hk_parent_inside_project "$val"; then
    hk_log warn "$key='$val' goes through a folder that links outside the project; using $def"
    printf '%s\n' "$def"
  else
    printf '%s\n' "$val"
  fi
}

hk_handoff_name() { hk_file_name LIMIT_HANDOFF_FILE "HANDOFF.md"; }
hk_recover_dir_name() { hk_file_name LIMIT_HANDOFF_RECOVER_DIR ".handoff"; }

# hk_lower text: prints the text in lowercase (bash 3.2 safe).
hk_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# hk_same_target a b: succeeds when two project-relative names are the same file.
# That is the case when the names match ignoring case (macOS folders ignore case), when
# both exist and are the same file (-ef, which also covers hard links), or when the
# links resolve to the same place, even if that place does not exist yet.
hk_same_target() {
  local pa pb
  if [ "$(hk_lower "$1")" = "$(hk_lower "$2")" ]; then return 0; fi
  pa="$(hk_abs_path "$1")"
  pb="$(hk_abs_path "$2")"
  if [ -e "$pa" ] && [ -e "$pb" ] && [ "$pa" -ef "$pb" ]; then return 0; fi
  if [ "$(hk_lower "$(hk_real_path "$pa")")" = "$(hk_lower "$(hk_real_path "$pb")")" ]; then return 0; fi
  return 1
}

# hk_prompt_name: the paste prompt file. It can never be the handoff file, because that would
# overwrite the user's handoff text (see hk_same_target). In that case the next default name
# that is not the handoff file is used, and the reason is logged.
hk_prompt_name() {
  local p h cand
  p="$(hk_file_name LIMIT_HANDOFF_PROMPT_FILE "PASTE-PROMPT.txt")"
  h="$(hk_handoff_name)"
  if ! hk_same_target "$p" "$h"; then
    printf '%s\n' "$p"
    return 0
  fi
  for cand in PASTE-PROMPT.txt HANDOFF-PASTE-PROMPT.txt PASTE-PROMPT-2.txt; do
    if ! hk_same_target "$cand" "$h"; then
      hk_log warn "LIMIT_HANDOFF_PROMPT_FILE='$p' cannot be the same file as LIMIT_HANDOFF_FILE ($h); using $cand"
      printf '%s\n' "$cand"
      return 0
    fi
  done
  printf '%s\n' "PASTE-PROMPT-2.txt"
}

# hk_sha256_stdin: prints the SHA-256 of stdin as 64 hex characters. Prints nothing when no
# hashing tool exists (shasum on macOS, sha256sum on most Linux systems).
hk_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{ print $1 }'
  fi
}

# hk_write_prompt_file dest text: writes the paste prompt (text plus a newline) to dest.
# A file the kit did not write last time is not overwritten silently. It is first copied to
# "<name>.bak-<YYYYmmdd-HHMMSS>" in the same folder (a number is added when that name is
# taken), and the copy is logged. The kit remembers the SHA-256 of what it wrote for each
# real path, in <state>/prompts/<sha256 of the real path>. A file that still matches that
# hash is the kit's own file, so it is overwritten without a backup.
# Returns non-zero when nothing was written (for example: the backup failed, or dest is a folder).
# The read-check-write runs under the lock for this file, so two chats that hit a limit at the
# same moment cannot back up each other's prompt file.
hk_write_prompt_file() {
  local rc
  hk_lock_take "$1"
  _hk_write_prompt_locked "$1" "$2"
  rc=$?
  hk_lock_release
  return $rc
}

# _hk_write_prompt_locked dest text: the work of hk_write_prompt_file. Call it under the lock only.
_hk_write_prompt_locked() {
  local dest="$1" text="$2" real key rec_dir rec cur stored stamp bak n
  real="$(hk_real_path "$dest")"
  if [ -z "$real" ] || [ -d "$real" ]; then return 1; fi
  rec_dir="$(hk_state_dir)/prompts"
  key="$(printf '%s' "$real" | hk_sha256_stdin)"
  rec=""
  if [ -n "$key" ]; then rec="$rec_dir/$key"; fi

  if [ -f "$real" ]; then
    cur="$(hk_sha256_stdin < "$real")"
    stored=""
    if [ -n "$rec" ] && [ -f "$rec" ]; then stored="$(cat "$rec" 2>/dev/null)"; fi
    if [ -z "$cur" ] || [ "$cur" != "$stored" ]; then
      stamp="$(hk_now_stamp)"
      bak="$real.bak-$stamp"
      n=1
      while [ -e "$bak" ]; do
        bak="$real.bak-$stamp-$n"
        n=$((n + 1))
      done
      if ! cp -p "$real" "$bak" 2>/dev/null; then
        hk_log error "paste prompt not written: $real has content the kit did not write, and the backup to $bak failed"
        return 1
      fi
      hk_log info "backed up $real to $bak before writing the paste prompt (the file was not written by limit-handoff)"
    fi
  fi

  printf '%s\n' "$text" | HK_NEW_MODE=600 hk_atomic_write "$real" || return 1

  if [ -n "$rec" ]; then
    mkdir -p "$rec_dir" 2>/dev/null
    cur="$(hk_sha256_stdin < "$real")"
    if [ -n "$cur" ]; then
      printf '%s\n' "$cur" | hk_atomic_write "$rec" 2>/dev/null
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Hook input and project folder
# ---------------------------------------------------------------------------

HK_INPUT=""
HK_CWD=""
HK_TRANSCRIPT=""
HK_SOURCE=""
# The three variables below are read by the hooks that source this file. ShellCheck cannot see
# those reads. A directive covers only the next command, so each one sits on its own line.
# shellcheck disable=SC2034
HK_SESSION=""
# shellcheck disable=SC2034
HK_ERROR=""
# shellcheck disable=SC2034
HK_LAST_MSG=""
HK_PROJECT_DIR=""

# _hk_field key: one top-level string field from HK_INPUT (jq, or sed when jq is missing).
_hk_field() {
  local key="$1"
  if hk_have_jq; then
    printf '%s' "$HK_INPUT" | jq -r --arg k "$key" '.[$k] // empty | if type == "string" then . else empty end' 2>/dev/null
  else
    printf '%s' "$HK_INPUT" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
  fi
}

# hk_read_input: reads the hook JSON from stdin into HK_INPUT and the HK_* fields.
# HK_LAST_MSG is the hook's last_assistant_message (text only, may be empty).
# Empty when nothing usable is on stdin.
# The directive below covers the whole function. HK_SESSION, HK_ERROR and HK_LAST_MSG are read
# by the hooks that source this file, not in this file.
# shellcheck disable=SC2034
hk_read_input() {
  HK_INPUT=""
  HK_CWD=""
  HK_SESSION=""
  HK_TRANSCRIPT=""
  HK_ERROR=""
  HK_SOURCE=""
  HK_LAST_MSG=""
  HK_INPUT_OK=0
  if [ -t 0 ]; then
    return 0
  fi
  # A closed stdin is not read: inside $(...) bash would hand cat the substitution's own pipe,
  # and the read would wait until the hook timeout. The test copies fd 0 to fd 9, which fails
  # when fd 0 is closed. (bash skips "<&0" as a copy onto itself, so that test always passes.)
  if ! { true 9<&0; } 2>/dev/null; then
    return 0
  fi
  HK_INPUT="$(cat 2>/dev/null)"
  if [ -z "$HK_INPUT" ]; then
    return 0
  fi
  # HK_INPUT_OK=1 when the input is a JSON object, the only shape Claude Code sends. The hooks
  # that write files (StopFailure, PreCompact) do nothing without it, so an empty or broken input
  # (for example a hook run by hand) never writes notes into whatever folder the shell is in.
  # Without jq the check is that the text starts with "{".
  if hk_have_jq; then
    if printf '%s' "$HK_INPUT" | jq -e 'type == "object"' >/dev/null 2>&1; then HK_INPUT_OK=1; fi
  else
    case "$(printf '%s' "$HK_INPUT" | tr -d ' \t\r\n' | cut -c1)" in
      "{") HK_INPUT_OK=1 ;;
    esac
  fi
  HK_CWD="$(_hk_field cwd)"
  HK_SESSION="$(_hk_field session_id)"
  HK_TRANSCRIPT="$(_hk_field transcript_path)"
  HK_ERROR="$(_hk_field error)"
  HK_SOURCE="$(_hk_field source)"
  HK_LAST_MSG="$(_hk_field last_assistant_message)"
  return 0
}

# hk_project_dir: sets HK_PROJECT_DIR. Order: --dir forced value, CLAUDE_PROJECT_DIR,
# the hook's cwd, then the current folder. Only existing folders count.
hk_project_dir() {
  local cand
  for cand in "${HK_FORCE_DIR:-}" "${CLAUDE_PROJECT_DIR:-}" "${HK_CWD:-}" "$PWD"; do
    if [ -n "$cand" ] && [ -d "$cand" ]; then
      # A relative name gets "./" first, so a folder named "-x" or "-" is never read by cd as
      # an option (or as "the previous folder").
      case "$cand" in
        /*) ;;
        *) cand="./$cand" ;;
      esac
      HK_PROJECT_DIR="$(CDPATH='' cd "$cand" && pwd)"
      return 0
    fi
  done
  HK_PROJECT_DIR="$PWD"
  return 0
}

# hk_handoff_path / hk_prompt_path: absolute paths inside the project.
hk_handoff_path() { printf '%s/%s\n' "$HK_PROJECT_DIR" "$(hk_handoff_name)"; }
hk_prompt_path() { printf '%s/%s\n' "$HK_PROJECT_DIR" "$(hk_prompt_name)"; }

# ---------------------------------------------------------------------------
# Clipboard and notifications (best effort, never fatal)
# ---------------------------------------------------------------------------

# hk_clipboard_off: succeeds when the user turned the clipboard off (off, 0, no, false or none).
# Read from the environment and the user file only, like the rest of the clipboard setting.
hk_clipboard_off() {
  case "$(hk_conf_trusted LIMIT_HANDOFF_CLIPBOARD auto)" in
    off|0|no|false|none) return 0 ;;
  esac
  return 1
}

# hk_copy_clipboard text: returns 0 when a clipboard tool accepted the text.
hk_copy_clipboard() {
  local text="$1" mode cmd
  if hk_clipboard_off; then return 1; fi
  mode="$(hk_conf_trusted LIMIT_HANDOFF_CLIPBOARD auto)"
  case "$mode" in
    off|0|no|false|none) return 1 ;;
    auto|"") ;;
    *)
      # A named tool is used only when it is a bare command name found on PATH.
      # A bad name never falls back to auto: that could run a different tool
      # (for example the real pbcopy) than the one the user set. Say why in the log.
      if ! hk_valid_cmd_name "$mode"; then
        hk_log warn "clipboard not used: LIMIT_HANDOFF_CLIPBOARD must be auto, off, or a bare command name such as pbcopy (no slashes or spaces). Got: $mode"
        return 1
      fi
      if ! command -v "$mode" >/dev/null 2>&1; then
        hk_log warn "clipboard not used: '$mode' (LIMIT_HANDOFF_CLIPBOARD) is not found on your PATH"
        return 1
      fi
      printf '%s' "$text" | "$mode" >/dev/null 2>&1
      return $?
      ;;
  esac
  for cmd in pbcopy wl-copy xclip xsel clip.exe; do
    if command -v "$cmd" >/dev/null 2>&1; then
      case "$cmd" in
        xclip) printf '%s' "$text" | xclip -selection clipboard >/dev/null 2>&1 ;;
        xsel) printf '%s' "$text" | xsel --clipboard --input >/dev/null 2>&1 ;;
        *) printf '%s' "$text" | "$cmd" >/dev/null 2>&1 ;;
      esac
      if [ $? -eq 0 ]; then
        return 0
      fi
    fi
  done
  return 1
}

# hk_notify title body: shows a desktop notification when a tool exists.
# The text is passed as arguments, never pasted into AppleScript source.
hk_notify() {
  local title="$1" body="$2" mode
  mode="$(hk_conf_trusted LIMIT_HANDOFF_NOTIFY auto)"
  case "$mode" in
    off|0|no|false|none) return 1 ;;
  esac
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$body" >/dev/null 2>&1
    return $?
  fi
  if command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$title" -message "$body" >/dev/null 2>&1
    return $?
  fi
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'on run argv' \
      -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' "$title" "$body" >/dev/null 2>&1
    return $?
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Reasons and cut-off blocks
# ---------------------------------------------------------------------------

# hk_reason_for error_code: the plain-English reason used in every message.
# Only a known StopFailure code is shown as it is. Any other text is replaced by
# "unknown API error", because the text may come from a file that someone else wrote.
hk_reason_for() {
  case "$1" in
    # Claude Code uses rate_limit for account usage limits and for short API rate limits. Without
    # limit details the two cannot be told apart, so the plain text names both (see hk_base_reason).
    rate_limit) printf '%s\n' "rate or usage limit reached" ;;
    billing_error) printf '%s\n' "billing/credit limit" ;;
    overloaded) printf '%s\n' "API overloaded" ;;
    server_error) printf '%s\n' "API server error" ;;
    prompt_too_long) printf '%s\n' "context limit (prompt too long)" ;;
    unknown|"") printf '%s\n' "unknown API error" ;;
    *)
      if hk_in_list "$1" $HK_STOP_CODES; then
        printf '%s\n' "$1"
      else
        printf '%s\n' "unknown API error"
      fi
      ;;
  esac
}

# hk_base_reason error_code detail: the reason before the limit details. A rate_limit stop with
# limit details (a limit type, a reset time, or "session limit" in the message) is an account
# usage limit, so it says "usage limit reached". Without details it keeps the plain text.
hk_base_reason() {
  if [ "$1" = "rate_limit" ] && [ -n "${2:-}" ]; then
    printf '%s\n' "usage limit reached"
  else
    hk_reason_for "$1"
  fi
}

# hk_known_code text: prints the text when it is a known StopFailure code, else "unknown".
# A code must be lowercase letters and "_" only (max 40 characters) and be on the known list.
hk_known_code() {
  local re='^[a-z_]{1,40}$'
  if [[ "$1" =~ $re ]] && hk_in_list "$1" $HK_STOP_CODES; then
    printf '%s\n' "$1"
  else
    printf '%s\n' "unknown"
  fi
}

# hk_block_session_ok text: succeeds for a session id that is safe to show (letters, digits,
# "_", "-", "." only, 1 to 80 characters).
hk_block_session_ok() {
  local re='^[A-Za-z0-9_.-]{1,80}$'
  [[ "$1" =~ $re ]]
}

# hk_shown_path_ok rel: succeeds for a project-relative path that is safe to print in hook output:
# letters, digits, "_", ".", "/" and "-" only, no "..", no ".git" or ".claude" folder, and it
# stays inside the project after links are followed.
hk_shown_path_ok() {
  local p="$1" re='^\.?[A-Za-z0-9_./-]+$'
  [[ "$p" =~ $re ]] || return 1
  hk_safe_rel "$p" || return 1
  hk_inside_project "$(hk_abs_path "$p")"
}

# hk_cutoff_block session iso error reason human_time recovered_rel [limit_type] [resets_epoch]
# Prints the cut-off block exactly as the spec describes it. The two optional values add
# limit="..." and resets="..." after error="..." (only when they pass their strict checks).
# Without them the header is the same as before.
hk_cutoff_block() {
  local lre='^[a-z0-9_]{1,40}$' rre='^[0-9]{9,11}$' extra=""
  if [[ "${7:-}" =~ $lre ]]; then extra=" limit=\"$7\""; fi
  if [[ "${8:-}" =~ $rre ]]; then extra="$extra resets=\"$8\""; fi
  printf '<!-- limit-handoff:cutoff session="%s" at="%s" error="%s"%s status="unresolved" -->\n' "$1" "$2" "$3" "$extra"
  printf '> ⚠️ **Session cut off** (%s) at %s. The steps above may be slightly behind.\n' "$4" "$5"
  # An empty 6th value means no recovered file was written. The block says so, and no path is shown.
  if [ -n "$6" ]; then
    printf '> Check the files for a half-finished step before continuing. Recovered context: `%s`\n' "$6"
  else
    printf '> Check the files for a half-finished step before continuing. Recovered context: not written (see the log)\n'
  fi
  printf '<!-- /limit-handoff:cutoff -->\n'
}

# HK_AWK_FENCE: an awk function that every reader and writer of HANDOFF.md uses, so text inside
# a fenced code block (``` or ~~~) is never read as a cut-off block or a heading. A user may keep
# an example block in a fence. hk_fence(line) returns 1 for a fence line and for every line
# inside a fence, 0 otherwise. It keeps its state in HKF (open or not) and HKFC (the fence char).
# Rules: up to 3 leading spaces, then 3 or more ` or ~. A fence closes on a line of the same
# char with nothing else but spaces. No regex intervals: mawk and old BSD awk lack them.
# shellcheck disable=SC2016
HK_AWK_FENCE='
function hk_fence(line,   n, t, c, r) {
  match(line, /^ */); n = RLENGTH; t = substr(line, n + 1)
  c = substr(t, 1, 1)
  if (n <= 3 && (substr(t, 1, 3) == "```" || substr(t, 1, 3) == "~~~")) {
    if (!HKF) { HKF = 1; HKFC = c; return 1 }
    if (c == HKFC) {
      r = t
      while (substr(r, 1, 1) == c) r = substr(r, 2)
      gsub(/[ \t\r]/, "", r)
      if (r == "") { HKF = 0; return 1 }
    }
    return 1
  }
  return HKF ? 1 : 0
}
'

# hk_unfenced_view file: prints the file with every fenced line (and fence line) replaced by an
# empty line. Line numbers stay the same. Readers that only look for markers use this view.
hk_unfenced_view() {
  [ -f "$1" ] || return 0
  awk "$HK_AWK_FENCE"'{ if (hk_fence($0)) print ""; else print }' "$1" 2>/dev/null
}

# hk_cut_chars max [mark]: reads one line of text on stdin and cuts it to max characters. A
# multi-byte UTF-8 character is never cut in half: cut -c counts bytes on GNU/Linux and in the C
# locale, so a broken last character is removed afterwards. When text was cut and mark is given,
# mark (for example "…") is added at the end, and the text is cut shorter by the bytes of mark,
# so the result is never longer than max (in bytes or in characters).
hk_cut_chars() {
  local max="$1" mark="${2:-}" s out mb
  s="$(cat)"
  if [ -n "$mark" ] && [ "$(printf '%s' "$s" | cut -c1-"$max")" != "$s" ]; then
    mb="$(printf '%s' "$mark" | wc -c | tr -d ' ')"
    max=$((max - mb))
  fi
  out="$(printf '%s\n' "$s" | cut -c1-"$max" | LC_ALL=C sed \
    -e $'s/[\xf0-\xff][\x80-\xbf][\x80-\xbf]$//' \
    -e $'s/[\xe0-\xff][\x80-\xbf]$//' \
    -e $'s/[\xc0-\xff]$//')"
  if [ -n "$mark" ] && [ "$out" != "$s" ]; then out="$out$mark"; fi
  printf '%s\n' "$out"
}

# hk_has_unresolved_cutoff file: succeeds when the file has an unresolved cut-off block
# (outside fenced code blocks).
hk_has_unresolved_cutoff() {
  [ -f "$1" ] && hk_unfenced_view "$1" | grep -q '^<!-- limit-handoff:cutoff .*status="unresolved"'
}

# hk_has_session_block file session: succeeds when the file has a cut-off block (any state) for
# this session, outside fenced code blocks.
hk_has_session_block() {
  [ -f "$1" ] && hk_unfenced_view "$1" | grep -F -q "<!-- limit-handoff:cutoff session=\"$2\""
}

# hk_last_unresolved_block file: prints the newest unresolved cut-off block. Newest means the
# latest at= time (ISO UTC text sorts in time order). A block with no usable time sorts lowest.
# When two blocks have the same time, the one lower in the file wins.
hk_last_unresolved_block() {
  [ -f "$1" ] || return 0
  hk_unfenced_view "$1" | awk '
    /^<!-- limit-handoff:cutoff / {
      cur = $0; inb = 1; keep = ($0 ~ /status="unresolved"/)
      at = ""
      if (match($0, /at="[^"]*"/)) { at = substr($0, RSTART + 4, RLENGTH - 5) }
      if (at !~ /^[0-9]+-[0-9]+-[0-9]+T[0-9:]+Z$/) { at = "" }
      next
    }
    inb && /^<!-- \/limit-handoff:cutoff -->/ {
      cur = cur "\n" $0
      if (keep && (!have || at >= bestat)) { best = cur; bestat = at; have = 1 }
      inb = 0; next
    }
    inb { cur = cur "\n" $0; next }
    END { if (have) { print best } }
  '
}

# hk_upsert_cutoff file session block: replaces this session's block in place,
# or appends it when there is none. Blocks from other sessions are untouched.
#
# A block is ours from its header line up to its end marker. If another block's header
# or a markdown heading shows up before that end marker, our block was never closed.
# An unclosed block is then written back exactly as it was, so nothing is dropped.
# The new file goes through hk_atomic_write, so a symlinked HANDOFF.md keeps its link.
hk_upsert_cutoff() {
  local file="$1" sid="$2" block="$3" out rc
  out="$(HK_CUT_PREFIX="<!-- limit-handoff:cutoff session=\"$sid\" " \
  HK_CUT_END="<!-- /limit-handoff:cutoff -->" \
  HK_CUT_BLOCK="$block" \
  awk "$HK_AWK_FENCE"'
    BEGIN {
      st = 0; n = 0; replaced = 0
      pfx = ENVIRON["HK_CUT_PREFIX"]; endm = ENVIRON["HK_CUT_END"]; blk = ENVIRON["HK_CUT_BLOCK"]
      hdr = "<!-- limit-handoff:cutoff "
    }
    function flush(   i) { for (i = 1; i <= n; i++) print buf[i]; n = 0; st = 0 }
    {
      line = $0
      # A fenced code block is copied as it is. A block of ours that is still open when a fence
      # starts was never closed, so it is written back unchanged (flush).
      if (hk_fence(line)) {
        if (st == 1) flush()
        print line
        next
      }
      again = 1
      while (again) {
        again = 0
        if (st == 0) {
          if (index(line, pfx) == 1) { st = 1; n = 1; buf[1] = line }
          else { print line }
        } else if (index(line, endm) == 1) {
          if (!replaced) { print blk; replaced = 1 }
          n = 0; st = 0
        } else if (index(line, hdr) == 1 || line ~ /^#+ /) {
          flush(); again = 1
        } else {
          n++; buf[n] = line
        }
      }
    }
    END {
      if (st == 1) flush()
      if (!replaced) { print ""; print blk }
    }
  ' "$file" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  printf '%s\n' "$out" | hk_atomic_write "$file"
}

# hk_first_next_step file: prints the next step from the "## Next steps" section.
# It is the first list item (strips "1. ", "- ", "* " and the checkbox "[ ]" or "[~]").
# Rule for finished items: a "[x]" item is always skipped, so a finished step is never handed
# out as the next one. The first item that is not "[x]" is used (an open box, a "[~]" box or
# a plain item). Empty when there is no item, or when every item is "[x]" (then the paste
# prompt asks Claude to work out the next step instead).
hk_first_next_step() {
  [ -f "$1" ] || return 0
  hk_unfenced_view "$1" | awk '
    /^## +Next steps/ { insec = 1; next }
    insec && /^## / { insec = 0 }
    insec {
      line = $0
      if (line ~ /^[[:space:]]*([0-9]+[.)]|[-*+])[[:space:]]+/) {
        sub(/^[[:space:]]*([0-9]+[.)]|[-*+])[[:space:]]+/, "", line)
        state = ""
        if (line ~ /^\[[xX]\]/) state = "x"
        else if (line ~ /^\[ \]/) state = "box"
        sub(/^\[[ xX~]\][[:space:]]*/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line != "") { n++; txt[n] = line; st[n] = state }
      }
    }
    END {
      if (n == 0) exit
      pick = 0
      for (i = 1; i <= n && pick == 0; i++) {
        if (st[i] != "x") pick = i
      }
      if (pick > 0) print txt[pick]
    }
  ' | tr -d '\001-\037\177' | hk_cut_chars 300 '…'
}

# hk_block_at_human, hk_block_recovered, hk_block_error, hk_block_session: read one value out of
# a block's text. A block in HANDOFF.md is committed text that anyone can edit, so each value is
# checked before it is used. These are the readers the hooks use to build their output:
#   - the error code is a known StopFailure code, otherwise "unknown";
#   - the time is a date and time (YYYY-MM-DD HH:MM), otherwise empty (the caller omits it);
#   - the recovered file is a safe path inside the project, otherwise empty;
#   - the session id is letters, digits, "_", "-" and "." (max 80), otherwise "unknown".
hk_block_at_human() {
  local t re='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$'
  t="$(printf '%s\n' "$1" | sed -n 's/.*) at \([0-9-]* [0-9:]*\)\..*/\1/p' | head -n 1)"
  if [[ "$t" =~ $re ]]; then printf '%s\n' "$t"; fi
}
hk_block_recovered() {
  local p
  p="$(printf '%s\n' "$1" | sed -n 's/.*Recovered context: `\([^`]*\)`.*/\1/p' | head -n 1)"
  if hk_shown_path_ok "$p"; then printf '%s\n' "$p"; fi
}

# hk_read_first_text block: the words that tell Claude what to read first, for the reminders.
# The recovered file is named only when the block gives a strict path (hk_block_recovered).
# A block that says the file was not written gets no recovered-file part. Otherwise the words
# say "the recovered context file named in the cut-off block", never the .handoff folder.
hk_read_first_text() {
  local rec hf
  hf="$(hk_handoff_name)"
  rec="$(hk_block_recovered "$1")"
  if [ -n "$rec" ]; then
    printf 'Read %s and %s before anything else' "$hf" "$rec"
  elif printf '%s\n' "$1" | grep -q 'Recovered context: not written'; then
    printf 'Read %s before anything else' "$hf"
  else
    printf 'Read %s and the recovered context file named in the cut-off block before anything else' "$hf"
  fi
}
hk_block_error() {
  local raw
  raw="$(printf '%s\n' "$1" | head -n 1 | sed -n 's/.* error="\([^"]*\)".*/\1/p')"
  hk_known_code "$raw"
}
hk_block_session() {
  local s
  s="$(printf '%s\n' "$1" | head -n 1 | sed -n 's/.* session="\([^"]*\)".*/\1/p')"
  if hk_block_session_ok "$s"; then printf '%s\n' "$s"; else printf '%s\n' "unknown"; fi
}

# hk_block_limit block: the limit type on the header line (limit="..."), if it is a safe name
# (lowercase letters, digits and "_", 1 to 40 characters). Empty for an old block without it.
hk_block_limit() {
  local t re='^[a-z0-9_]{1,40}$'
  t="$(printf '%s\n' "$1" | head -n 1 | sed -n 's/.* limit="\([^"]*\)".*/\1/p')"
  if [[ "$t" =~ $re ]]; then printf '%s\n' "$t"; fi
}

# hk_block_resets block: the reset time on the header line (resets="..."), if it is an epoch
# time of 9 to 11 digits. Empty for an old block without it.
hk_block_resets() {
  local r re='^[0-9]{9,11}$'
  r="$(printf '%s\n' "$1" | head -n 1 | sed -n 's/.* resets="\([^"]*\)".*/\1/p')"
  if [[ "$r" =~ $re ]]; then printf '%s\n' "$r"; fi
}

# hk_block_detail block: the limit details of a cut-off block, in the same words as
# hk_limit_detail. It is built only from the checked type and reset time. Empty when neither is safe.
hk_block_detail() {
  hk_limit_text "$(hk_block_limit "$1")" "$(hk_block_resets "$1")"
}

# ---------------------------------------------------------------------------
# Limit details: which limit was hit, and when it resets
# Only fixed words and checked values are ever printed. The text of the limit line or of the
# hook's last message is never copied into the output.
# ---------------------------------------------------------------------------

# hk_limit_label type: the plain-English name of a limit type. Known types have fixed names.
# Another type made of lowercase letters, digits and "_" becomes its words plus " limit"
# (for example daily_cap gives "daily cap limit"). Anything else gives nothing.
hk_limit_label() {
  local t="$1" re='^[a-z0-9_]{1,40}$'
  case "$t" in
    five_hour) printf '%s\n' "5-hour limit" ;;
    seven_day) printf '%s\n' "weekly limit" ;;
    seven_day_opus) printf '%s\n' "weekly Opus limit" ;;
    seven_day_sonnet) printf '%s\n' "weekly Sonnet limit" ;;
    *)
      if [[ "$t" =~ $re ]]; then
        _hk_trim "${t//_/ }"
        if [ -n "$HK_TRIM" ]; then printf '%s limit\n' "$HK_TRIM"; fi
      fi
      ;;
  esac
}

# hk_format_epoch epoch: a Unix time as "Fri 30 Oct 17:40 GMT", in the local time zone.
# GNU date (-d @N) is tried first, then BSD date (-r N). Prints nothing for a value that is not
# 9 to 11 digits, or when no date tool can format it. LC_ALL=C keeps the names in English.
hk_format_epoch() {
  local e="$1" re='^[0-9]{9,11}$' out=""
  [[ "$e" =~ $re ]] || return 0
  out="$(LC_ALL=C date -d "@$e" '+%a %d %b %H:%M %Z' 2>/dev/null)" || out=""
  if [ -z "$out" ]; then
    out="$(LC_ALL=C date -r "$e" '+%a %d %b %H:%M %Z' 2>/dev/null)" || out=""
  fi
  printf '%s\n' "$out" | LC_ALL=C tr -cd 'A-Za-z0-9 :,()/+_.-' | cut -c1-40
}

# hk_limit_text type epoch: "<label>, resets <time>". When the reset time has already passed,
# it says "the reset time has passed (<time>)". When one part is missing, only the other is used.
# Empty when neither part is known. Kept to the allowed characters, at most 100.
hk_limit_text() {
  local label when out="" past=0
  label="$(hk_limit_label "$1")"
  when="$(hk_format_epoch "$2")"
  case "$2" in
    ''|*[!0-9]*) ;;
    *) if [ -n "$when" ] && [ "$2" -lt "$(date +%s)" ]; then past=1; fi ;;
  esac
  if [ -n "$when" ]; then
    if [ "$past" = 1 ]; then when="the reset time has passed ($when)"; else when="resets $when"; fi
  fi
  if [ -n "$label" ] && [ -n "$when" ]; then
    out="$label, $when"
  elif [ -n "$label" ]; then
    out="$label"
  elif [ -n "$when" ]; then
    out="$when"
  fi
  printf '%s\n' "$out" | LC_ALL=C tr -cd 'A-Za-z0-9 :,()/+_.-' | cut -c1-100
}

# hk_limit_type json: the limit type of the recovered JSON (.limit.type), if it is a safe name.
hk_limit_type() {
  local t re='^[a-z0-9_]{1,40}$'
  [ -n "${1:-}" ] || return 0
  t="$(printf '%s' "$1" | jq -r '.limit.type // empty | if type == "string" then . else empty end' 2>/dev/null)"
  if [[ "$t" =~ $re ]]; then printf '%s\n' "$t"; fi
}

# hk_limit_resets json: the reset time of the recovered JSON (.limit.resets_at), if it is a
# number of 9 to 11 digits. Empty otherwise.
hk_limit_resets() {
  local r re='^[0-9]{9,11}$'
  [ -n "${1:-}" ] || return 0
  r="$(printf '%s' "$1" | jq -r '.limit.resets_at // empty | if type == "number" then tostring else empty end' 2>/dev/null)"
  if [[ "$r" =~ $re ]]; then printf '%s\n' "$r"; fi
}

# hk_msg_detail text: the limit wording in the hook's last message, when there is one. Only two
# things are taken: the fixed words "session limit" or "weekly limit", and a reset part that
# matches "resets 5:40pm (Europe/London)" exactly. Everything else in the text is ignored.
hk_msg_detail() {
  local text="$1" low parts="" when="" out="" re='resets ([0-9]{1,2}(:[0-9]{2})?(am|pm)( \([A-Za-z_/+-]{1,40}\))?)'
  low="$(hk_lower "$text")"
  case "$low" in
    *"session limit"*) parts="session limit" ;;
    *"weekly limit"*) parts="weekly limit" ;;
  esac
  if [[ "$text" =~ $re ]]; then when="resets ${BASH_REMATCH[1]}"; fi
  if [ -n "$parts" ] && [ -n "$when" ]; then
    out="$parts, $when"
  elif [ -n "$parts" ]; then
    out="$parts"
  else
    out="$when"
  fi
  printf '%s\n' "$out" | LC_ALL=C tr -cd 'A-Za-z0-9 :,()/+_.-' | cut -c1-100
}

# hk_limit_detail json last_msg: the limit details for a reason, such as
# "5-hour limit, resets Fri 30 Oct 17:40 GMT". The recovered JSON comes first. When it gives
# nothing, the hook's last message is tried (hk_msg_detail). Empty when neither gives anything.
hk_limit_detail() {
  local json="$1" msg="${2:-}" out=""
  if [ -n "$json" ]; then
    out="$(hk_limit_text "$(hk_limit_type "$json")" "$(hk_limit_resets "$json")")"
  fi
  if [ -z "$out" ] && [ -n "$msg" ]; then
    out="$(hk_msg_detail "$msg")"
  fi
  printf '%s\n' "$out"
}

# hk_with_detail reason detail: "<reason> — <detail>" when there is a detail, else the reason alone.
hk_with_detail() {
  if [ -n "${2:-}" ]; then
    printf '%s — %s\n' "$1" "$2"
  else
    printf '%s\n' "$1"
  fi
}

# ---------------------------------------------------------------------------
# Transcript recovery
# ---------------------------------------------------------------------------

# hk_recover_json transcript nprompts
# Prints the recovered-context JSON (see lib/transcript.jq).
# Exit codes: 0 ok, 2 jq missing, 3 transcript not readable, 1 jq failed.
hk_recover_json() {
  local file="$1" np="$2" tail_lines out
  hk_have_jq || return 2
  # Only a plain file is read. A named pipe (FIFO) or a folder would block or fail.
  if [ -z "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then return 3; fi
  case "$np" in ''|*[!0-9]*) np=5 ;; esac
  tail_lines="$(hk_int_conf_trusted LIMIT_HANDOFF_TAIL_LINES 4000)"
  # Lines first, then bytes: tail -n on a file reads back from the end, so only the last lines
  # are read (reading 32 MB first was slow). tail -c then keeps at most HK_TAIL_BYTES, so a few
  # huge lines cannot fill memory. The first line may start in the middle of a line. That piece is
  # not valid JSON, so the filter skips it.
  out="$(tail -n "$tail_lines" "$file" 2>/dev/null | tail -c "$HK_TAIL_BYTES" | jq -n -R -c --argjson np "$np" -f "$HK_LIB_DIR/transcript.jq" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
  return 0
}

# hk_recover_note rc: the sentence that explains why recovery failed.
hk_recover_note() {
  case "$1" in
    2) printf '%s\n' "jq is not installed, so the recent transcript could not be read. Install jq for full recovery." ;;
    3) printf '%s\n' "The transcript file could not be read (missing, empty path or no permission)." ;;
    *) printf '%s\n' "The transcript could not be parsed." ;;
  esac
}

# hk_prompt_count: how many last prompts to recover (LIMIT_HANDOFF_PROMPTS, default 5).
hk_prompt_count() { hk_int_conf LIMIT_HANDOFF_PROMPTS 5; }

# ---------------------------------------------------------------------------
# Repository state from git
# A handoff can say a change was made when it was not. So the recovered file also gets facts
# from git: the branch, the last commit, a short diff summary and the changed file names.
# Git runs only read-only commands, with settings that stop the repository from running programs.
# ---------------------------------------------------------------------------

# hk_git_line text max: one line of plain text from git. Control characters are removed, a
# backtick becomes an apostrophe (so text cannot open a code span), and the text is cut to max.
hk_git_line() {
  printf '%s' "$1" | tr -d '\001-\037\177' | tr '`' "'" | hk_cut_chars "$2"
}

# hk_redact_line text: prints text with token-shaped strings replaced by [redacted]. It uses the
# same rules as the transcript (the "redact" part of lib/transcript.jq, between its marker
# comments), so there is one list of rules. Without jq, or when the rules cannot be read, it
# prints nothing: text that cannot be checked is left out.
hk_redact_line() {
  if [ -z "${HK_REDACT_DEF:-}" ]; then
    HK_REDACT_DEF="$(sed -n '/^# >>> redact/,/^# <<< redact/p' "$HK_LIB_DIR/transcript.jq" 2>/dev/null)"
  fi
  if [ -z "$HK_REDACT_DEF" ] || ! hk_have_jq; then
    return 0
  fi
  jq -nr --arg s "$1" "$HK_REDACT_DEF"$'\n''$s | redact' 2>/dev/null
}

# _hk_git dir args...: runs one git command in dir and prints its output. Errors are dropped.
# stdin is /dev/null, and the environment stops optional locks, prompts and the pager.
# HK_GIT_ARGS (the -c settings) is set by hk_git_state before the first call.
_hk_git() {
  local dir="$1"
  shift
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat \
    git -C "$dir" "${HK_GIT_ARGS[@]}" "$@" < /dev/null 2>/dev/null
}

# hk_git_state dir: prints a markdown section with facts from git about the repository in dir.
# Prints nothing when LIMIT_HANDOFF_GIT is 0, git is not on PATH, or dir is not inside a work
# tree. The repository's own config cannot make git run anything: fsmonitor is off, external
# diff and textconv are off (--no-ext-diff, --no-textconv), and every filter driver in the config
# (clean, smudge, process) is replaced by an empty program. A driver name with unusual characters
# makes the whole section go away. Paths in the output are relative to the repository root.
hk_git_state() {
  local dir="$1" inside key name drivers status_out sline branch entries count shown extra
  local last hash subj lastline diffsum changes branchtext longest n i fence
  [ "$(hk_bool_conf LIMIT_HANDOFF_GIT 1)" = "1" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  [ -n "$dir" ] && [ -d "$dir" ] || return 0

  HK_GIT_ARGS=(-c core.fsmonitor=false -c core.untrackedCache=false -c core.pager=cat -c color.ui=false -c status.showUntrackedFiles=normal)
  inside="$(_hk_git "$dir" rev-parse --is-inside-work-tree)"
  [ "$inside" = "true" ] || return 0

  # Filter drivers are read from the config (reading config runs nothing), then switched off.
  drivers="$(_hk_git "$dir" config --name-only --get-regexp '^filter\.')"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    name="${key#filter.}"
    name="${name%.*}"
    case "$name" in
      ''|*[!A-Za-z0-9._-]*) return 0 ;;
    esac
    HK_GIT_ARGS=("${HK_GIT_ARGS[@]}" -c "filter.$name.clean=" -c "filter.$name.smudge=" -c "filter.$name.process=" -c "filter.$name.required=false")
  done <<< "$drivers"

  # The first line of porcelain output is the branch line. The rest are the changed files.
  status_out="$(_hk_git "$dir" status --porcelain=v1 --branch)"
  [ -n "$status_out" ] || return 0
  sline="$(printf '%s\n' "$status_out" | sed -n '1p')"
  branch=""
  case "$sline" in
    "## "*) branch="${sline#"## "}" ;;
  esac
  entries="$(printf '%s\n' "$status_out" | sed '1d' | tr -d '\001-\011\013-\037\177')"
  count=0
  if [ -n "$entries" ]; then count="$(printf '%s\n' "$entries" | grep -c '')"; fi
  shown="$entries"
  extra=""
  if [ "$count" -gt 30 ]; then
    shown="$(printf '%s\n' "$entries" | sed -n '1,30p')"
    extra="... and $((count - 30)) more"
  fi

  if [ -n "$(_hk_git "$dir" rev-parse --verify -q HEAD)" ]; then
    last="$(_hk_git "$dir" log -1 --no-show-signature --format='%h %s')"
    hash="${last%% *}"
    subj=""
    case "$last" in
      *" "*) subj="${last#* }" ;;
    esac
    lastline="$(hk_git_line "$hash" 40)"
    # A commit subject can hold a pasted key, so it gets the same redaction as chat text.
    if [ -n "$subj" ]; then subj="$(hk_redact_line "$subj")"; fi
    if [ -n "$subj" ]; then lastline="$lastline $(hk_git_line "$subj" 120)"; fi
    if [ -z "$lastline" ]; then lastline="(unknown)"; fi
    diffsum="$(_hk_git "$dir" diff --no-ext-diff --no-textconv --no-color --stat HEAD | tail -n 1)"
    diffsum="$(printf '%s' "$diffsum" | sed 's/^[[:space:]]*//')"
    diffsum="$(hk_git_line "$diffsum" 200)"
    # Status lists files but the diff is empty: only new (untracked) files, which git does not diff.
    if [ -n "$diffsum" ]; then
      changes="$diffsum"
    elif [ -n "$entries" ]; then
      changes="no line changes against the last commit; see the file list below (new untracked files are not diffed)"
    else
      changes="no changes against the last commit"
    fi
  else
    lastline="(no commits yet)"
    changes="no diff summary, because there are no commits yet"
  fi
  branchtext="$(hk_git_line "$branch" 200)"
  if [ -z "$branchtext" ]; then branchtext="(unknown)"; fi

  # The code fence is one backtick longer than the longest run of backticks in the file names,
  # and at least four long. Same rule as fence_for in hk_render_recovered.
  longest="$(printf '%s' "$shown" | tr -c '`' '\n' | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
  longest="${longest:-0}"
  n=$((longest + 1))
  if [ "$n" -lt 4 ]; then n=4; fi
  fence=""
  i=0
  while [ "$i" -lt "$n" ]; do
    fence="$fence\`"
    i=$((i + 1))
  done

  printf '%s\n' "## Repository state (from git, when this file was made)"
  printf '\n'
  printf '%s\n' "- Branch: $branchtext"
  printf '%s\n' "- Last commit: $lastline"
  printf '%s\n' "- Changes: $changes"
  printf '\n'
  if [ "$count" -eq 0 ]; then
    printf '%s\n' "_The working tree is clean: no changed or untracked files._"
  else
    printf '%s\n' "$fence"
    printf '%s\n' "$shown"
    if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
    printf '%s\n' "$fence"
  fi
  return 0
}

# hk_render_recovered json session error reason transcript note [detail] [repo]
# Prints the recovered-context markdown. The json may be empty. The optional detail is the
# limit details line (hk_limit_detail); it is only written when it is not empty. The optional
# repo text is the section from hk_git_state; when it is empty nothing is added.
hk_render_recovered() {
  local json="$1" when
  when="$(hk_now_human)"
  [ -n "$json" ] || json='{}'
  printf '%s' "$json" | jq -r \
    --arg session "$2" --arg error "$3" --arg reason "$4" \
    --arg transcript "$5" --arg note "$6" --arg when "$when" --arg detail "${7:-}" \
    --arg repo "${8:-}" '
    def qt: split("\n") | map("> " + .) | join("\n");
    def one: gsub("\n"; " ");
    def ticks($n): [range(0; $n) | "`"] | join("");
    # A code block must use a fence longer than any run of backticks inside it,
    # so a command cannot close its own block early. At least four backticks.
    def fence_for($s): ([ $s | scan("`+") | length ] | max // 0) as $m
      | ticks(if $m + 1 > 4 then $m + 1 else 4 end);
    [
      "# Recovered context",
      "",
      "This file was made by limit-handoff so a new chat can continue the work. It is the last part of the chat, not the full transcript.",
      "",
      "- Session: `" + $session + "`",
      "- Why this was made: " + $reason + " (code `" + $error + "`)",
      (if $detail == "" then empty else "- Limit: " + $detail end),
      "- Made at: " + $when,
      "- Transcript read: `" + $transcript + "`",
      (if $note == "" then empty else "- Note: " + $note end),
      "",
      "## Last things you asked",
      "",
      (if ((.last_prompts // []) | length) == 0
        then "_No user messages were found in the recent transcript._"
        else ((.last_prompts // []) | to_entries
              | map("**Message " + ((.key + 1) | tostring) + "**\n\n" + (.value | qt))
              | join("\n\n")) end),
      "",
      "## Task list at cut-off",
      "",
      (if ((.tasks // []) | length) == 0
        then "_No task list was found in the recent transcript._"
        else ((.tasks // []) | map(
                "- [" + (if .status == "completed" then "x" elif .status == "in_progress" then "~" else " " end)
                + "] " + ((.content // "") | one)) | join("\n")) end),
      "",
      "## Files touched (most recent first)",
      "",
      (if ((.files_touched // []) | length) == 0
        then "_No file edits were found in the recent transcript._"
        else ((.files_touched // []) | map("- `" + . + "`") | join("\n")) end),
      "",
      (if $repo == "" then empty else (($repo | rtrimstr("\n")), "") end),
      "## Last commands",
      "",
      (if ((.last_commands // []) | length) == 0
        then "_No shell commands were found in the recent transcript._"
        else ((.last_commands // []) | map(
                (if (.description // "") == "" then "" else "- " + (.description | one) + "\n\n" end)
                + (fence_for(.command // "") as $f
                   | $f + "bash\n" + (.command // "") + "\n" + $f)) | join("\n\n")) end),
      "",
      "## Last assistant message",
      "",
      (if (.last_assistant_text // null) == null
        then "_No assistant text was found in the recent transcript._"
        else (.last_assistant_text | qt) end),
      ""
    ] | join("\n")
  ' 2>/dev/null
}

# hk_derive_next_step json: first unfinished task (in progress first, then pending).
hk_derive_next_step() {
  local json="$1"
  [ -n "$json" ] || return 0
  printf '%s' "$json" | jq -r '
    ((.tasks // []) | ([.[] | select(.status == "in_progress")] + [.[] | select(.status == "pending")]))
    | (.[0].content // empty) | gsub("\n"; " ")' 2>/dev/null
}

# hk_paste_text next_step recovered_abs reason [mode] [has_hf] [session]
# Prints the paste prompt from templates/paste-prompt.txt. session (a stop's own chat) is left out
# when other unresolved cut-offs are counted.
hk_paste_text() {
  local next="$1" rec="$2" reason="$3" mode="${4:-stop}" has_hf="${5:-1}"
  local hf why read_part next_part keep_part
  hf="$(hk_handoff_path)"
  if [ "$mode" = "manual" ]; then
    why="I am moving this work to a new chat on purpose."
    # A manual handoff has no transcript, so its recovered file holds no messages to point to.
    rec=""
  else
    why="My last chat stopped ($reason)."
  fi
  # Only name HANDOFF.md when it exists (or is made for this stop). Only name the recovered
  # file when there is one.
  if [ "$has_hf" = 1 ] && [ -n "$rec" ]; then
    read_part="First read $hf fully — it has the goal, what is done, decisions, and the exact next steps. Then read $rec for the last messages before the cut-off."
  elif [ "$has_hf" = 1 ]; then
    read_part="First read $hf fully — it has the goal, what is done, decisions, and the exact next steps."
    if [ "$mode" != "manual" ]; then read_part="$read_part There is no recovered file for this stop. Use $(hk_handoff_name)."; fi
  elif [ -n "$rec" ] && [ "$mode" != "manual" ]; then
    read_part="Read $rec for the last messages before the cut-off."
  else
    read_part="There is no $(hk_handoff_name) or recovered file for this stop."
  fi
  # No known next step: say so, and ask for the next step before any change.
  if [ -n "$next" ]; then
    next_part="Check the files for any half-finished step, then start with: $next."
  elif [ -n "$rec" ]; then
    next_part="Read the recovered file, work out the next step, and tell me what it is before you change any file."
  else
    next_part="Work out the next step from the project files, and tell me what it is before you change any file."
  fi
  # Unresolved cut-offs from other chats are named too, so none is missed. A stop builds this
  # prompt before its own block is written, and its own session is left out of the count anyway.
  local open_n
  if [ "$has_hf" = 1 ] && [ -f "$hf" ]; then
    open_n="$(hk_unfenced_view "$hf" | HK_PASTE_SID="${6:-}" awk '
      BEGIN { s = ENVIRON["HK_PASTE_SID"]; n = 0 }
      /^<!-- limit-handoff:cutoff / && /status="unresolved"/ {
        if (s == "" || index($0, "session=\"" s "\"") == 0) n++
      }
      END { print n + 0 }' 2>/dev/null)"
    case "$open_n" in ''|*[!0-9]*) open_n=0 ;; esac
    if [ "$open_n" -ge 1 ]; then
      read_part="$read_part It also has unresolved cut-offs from earlier chats ($open_n): read the recovered file each one names."
    fi
  fi
  keep_part=""
  if [ "$has_hf" = 1 ]; then keep_part=" Keep $(hk_handoff_name) updated as you work."; fi
  hk_render_template "$HK_ROOT/templates/paste-prompt.txt" \
    "PROJECT_DIR=$HK_PROJECT_DIR" \
    "WHY=$why" \
    "READ=$read_part" \
    "NEXT=$next_part" \
    "KEEP=$keep_part"
}

# hk_final_link_ok path: succeeds when the kit may write to path (or read it). A path that is not
# a link is always fine. A link is followed only when its real target is inside the project, or
# when the user turned on LIMIT_HANDOFF_FOLLOW_LINKS=1 in their own settings (environment or user
# file, never the project file). A link committed in a cloned repository can point at any file the
# user can write, so by default it is refused and a warning is logged.
hk_final_link_ok() {
  local p="$1" real base
  [ -L "$p" ] || return 0
  real="$(hk_real_path "$p")"
  base="$(CDPATH='' cd -P "${HK_PROJECT_DIR:-$PWD}" 2>/dev/null && pwd -P)"
  if [ -n "$real" ] && [ -n "$base" ]; then
    case "$real" in
      # Git's and Claude Code's own files are inside the project, but the kit must never write
      # its text into them (a link to .claude/settings.json would break that file). This is
      # refused even with LIMIT_HANDOFF_FOLLOW_LINKS=1.
      "$base"/.git|"$base"/.git/*|"$base"/.claude|"$base"/.claude/*)
        hk_log warn "$p is a link into .git or .claude, so it is never used"
        return 1 ;;
      "$base"/*) return 0 ;;
    esac
  fi
  if [ "$(hk_conf_trusted LIMIT_HANDOFF_FOLLOW_LINKS 0)" = "1" ]; then return 0; fi
  hk_log warn "$p is a link to a place outside the project (or into .git or .claude), so it is not used (LIMIT_HANDOFF_FOLLOW_LINKS=1 in your own settings allows it)"
  return 1
}

# hk_ensure_recover_gitignore dir [made]: creates dir/.gitignore so the recovered chat text stays out of git.
# It is written only when the folder has no entry with that name at all (a link counts too), so
# an existing .gitignore is never changed.
#   - A folder the kit owns gets two lines: a comment and "*". The kit owns it when it holds only
#     kit files (recovered-*.md and LATEST.md), or when it is empty and the kit just made it
#     (made=1) or it has the default name .handoff.
#   - Any other folder is the user's own (it holds their files, or it is an empty folder they made).
#     "*" would hide their files, so it gets rules that name only the kit's files instead:
#     the comment, "recovered-*.md", "LATEST.md" and ".gitignore". So the chat text still stays out
#     of git (README: ".handoff/ is kept out of git automatically").
# No lock is taken here: two hooks that race write the same lines, and a lock could be nested
# inside another lock. Returns non-zero when the file is not written.
hk_ensure_recover_gitignore() {
  local gi="$1/.gitignore" made="${2:-0}" f base kit=0 user=0
  local head="# Created by limit-handoff: recovered chat text stays out of git."
  if [ -e "$gi" ] || [ -L "$gi" ]; then
    return 0
  fi
  # Every entry counts, dot names included (".x" and "..x" both).
  for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
    base="${f##*/}"
    case "$base" in
      recovered-*.md|LATEST.md) kit=1 ;;
      *) user=1 ;;
    esac
  done
  if [ "$user" = 0 ] && { [ "$kit" = 1 ] || [ "$made" = 1 ] || [ "${1##*/}" = ".handoff" ]; }; then
    printf '%s\n%s\n' "$head" "*" | hk_atomic_write "$gi"
    return $?
  fi
  printf '%s\n%s\n%s\n%s\n' "$head" "recovered-*.md" "LATEST.md" ".gitignore" | hk_atomic_write "$gi"
}

# hk_prune_recovered dir keep [keep_name]: deletes the oldest recovered files in dir so that at
# most keep of them remain for each kind: the normal files and the -precompact snapshots have their
# own count. Only regular files whose names match the recovered file pattern are counted or
# deleted. A link with such a name, LATEST.md, .gitignore and every other file are left alone.
# keep_name (the file just written) is never deleted, and it counts as one of the keep.
# A file that an unresolved cut-off block in HANDOFF.md names is never deleted either.
# keep 0 turns pruning off. The stamp in each name sorts by time, so the oldest come first.
# Each deletion is rm -f on one exact path. Always returns 0.
hk_prune_recovered() {
  local dir="$1" keep="$2" keep_name="${3:-}" re f base kind kn list sorted total allowed excess n protected
  re='^recovered-[0-9]{8}-[0-9]{6}-[A-Za-z0-9_-]{1,8}(-precompact)?\.md$'
  case "$keep" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "${#keep}" -gt 9 ]; then keep=999999999; fi
  if [ "$keep" -eq 0 ]; then return 0; fi
  protected="$(hk_unresolved_recovered_names "$(hk_handoff_path)")"
  kn=normal
  case "$keep_name" in
    *-precompact.md) kn=precompact ;;
  esac
  for kind in normal precompact; do
    list=""
    for f in "$dir"/recovered-*.md; do
      base="${f##*/}"
      if [ -L "$f" ] || [ ! -f "$f" ]; then continue; fi
      if ! [[ "$base" =~ $re ]]; then continue; fi
      if [ "$base" = "$keep_name" ]; then continue; fi
      case "$base" in
        *-precompact.md) if [ "$kind" != precompact ]; then continue; fi ;;
        *) if [ "$kind" != normal ]; then continue; fi ;;
      esac
      if printf '%s\n' "$protected" | grep -F -x -q -- "$base"; then continue; fi
      list="$list$base"$'\n'
    done
    sorted="$(printf '%s' "$list" | LC_ALL=C sort)"
    total=0
    while IFS= read -r base; do
      if [ -n "$base" ]; then total=$((total + 1)); fi
    done <<< "$sorted"
    allowed=$keep
    if [ -n "$keep_name" ] && [ "$kind" = "$kn" ]; then allowed=$((keep - 1)); fi
    excess=$((total - allowed))
    if [ "$excess" -le 0 ]; then continue; fi
    n=0
    while IFS= read -r base; do
      if [ -z "$base" ]; then continue; fi
      if [ "$n" -ge "$excess" ]; then break; fi
      rm -f -- "${dir:?}/${base:?}"
      n=$((n + 1))
    done <<< "$sorted"
    if [ "$kind" = precompact ]; then
      hk_log info "removed $n old precompact snapshot(s) from $dir (LIMIT_HANDOFF_KEEP=$keep)"
    else
      hk_log info "removed $n old recovered file(s) from $dir (LIMIT_HANDOFF_KEEP=$keep)"
    fi
  done
  return 0
}

# hk_store_recovered dir file_name md in_project latest [made]: writes one recovered file into dir.
# made=1 says the kit has just created dir (see hk_ensure_recover_gitignore).
# A folder inside the project gets its .gitignore first (in_project=1). latest=1 also refreshes
# LATEST.md in the same folder. Returns non-zero when the recovered file was not written.
hk_store_recovered() {
  local dir="$1" name="$2" md="$3" in_project="$4" latest="$5" made="${6:-0}"
  if [ "$in_project" = 1 ]; then
    if ! hk_final_link_ok "$dir/$name"; then return 1; fi
    hk_ensure_recover_gitignore "$dir" "$made" 2>/dev/null
  fi
  printf '%s\n' "$md" | HK_NEW_MODE=600 hk_atomic_write "$dir/$name" || return 1
  if [ "$latest" = 1 ]; then
    if [ "$in_project" != 1 ] || hk_final_link_ok "$dir/LATEST.md"; then
      printf '%s\n' "$md" | HK_NEW_MODE=600 hk_atomic_write "$dir/LATEST.md" 2>/dev/null
    fi
  fi
  return 0
}

# hk_write_recovered json session error reason transcript note tag [detail]
# Writes .handoff/recovered-<stamp>-<session8><tag>.md and refreshes LATEST.md.
# First choice: the folder inside the project. It is used when it is a folder inside the project
# and the write works. Second choice: the state folder, outside the project (the kit may write
# there). The second choice is also used when the first one fails for any reason.
# Prints the path of the new file: project-relative when it is inside the project, absolute
# otherwise. Prints nothing and returns non-zero when no copy could be written. The caller then
# tells the user that there is no recovered file for this stop.
# The optional detail is the limit details line (see hk_limit_detail). The file also gets the
# repository section from hk_git_state for the project folder (nothing when there is none).
hk_write_recovered() {
  local json="$1" sid="$2" err="$3" reason="$4" transcript="$5" note="$6" tag="$7" detail="${8:-}"
  local rec_name file_name md s8 stamp dir latest git_part made tries
  rec_name="$(hk_recover_dir_name)"
  s8="$(printf '%s' "$sid" | cut -c1-8)"
  stamp="$(hk_now_stamp)"
  file_name="recovered-$stamp-$s8$tag.md"
  # Two stops in the same second with the same first 8 characters of the session id (for example
  # two simulate runs) would get the same name, and the second would overwrite the first. Wait for
  # the next second instead, at most 3 times.
  tries=0
  while [ "$tries" -lt 3 ] && { [ -e "$HK_PROJECT_DIR/$rec_name/$file_name" ] \
    || [ -e "$(hk_state_dir)/recovered/$file_name" ]; }; do
    sleep 1
    stamp="$(hk_now_stamp)"
    file_name="recovered-$stamp-$s8$tag.md"
    tries=$((tries + 1))
  done
  latest=0
  if [ -z "$tag" ]; then latest=1; fi
  # The git section is left out during a catch-up run: it would show the repository as it is now,
  # not as it was at the limit, and the catch-up runs when the session starts.
  git_part=""
  if [ "${LIMIT_HANDOFF_CATCHUP_RUN:-}" != "1" ]; then git_part="$(hk_git_state "$HK_PROJECT_DIR")"; fi
  md="$(hk_render_recovered "$json" "$sid" "$err" "$reason" "$transcript" "$note" "$detail" "$git_part")"
  # Plain text only: the values are never run, so no backticks or $( ) here.
  if [ -z "$md" ]; then
    md="# Recovered context

- Session: $sid
- Why this was made: $reason (code $err)
- Made at: $(hk_now_human)
- Transcript: $transcript
- Note: ${note:-The recent messages could not be rendered.}

The recent messages are not in this file."
  fi
  dir="$HK_PROJECT_DIR/$rec_name"
  made=0
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then made=1; fi
  if mkdir -p "$dir" 2>/dev/null && hk_inside_project "$dir" \
    && hk_store_recovered "$dir" "$file_name" "$md" 1 "$latest" "$made"; then
    # Keep the folder short: prune after the write. The file just written is protected by name.
    hk_prune_recovered "$dir" "$(hk_int_conf_trusted LIMIT_HANDOFF_KEEP 30)" "$file_name"
    printf '%s\n' "$rec_name/$file_name"
    return 0
  fi
  hk_log warn "$rec_name could not be used in the project; the recovered file goes to the state folder"
  dir="$(hk_state_dir)/recovered"
  if mkdir -p "$dir" 2>/dev/null && hk_store_recovered "$dir" "$file_name" "$md" 0 "$latest"; then
    hk_prune_recovered "$dir" "$(hk_int_conf_trusted LIMIT_HANDOFF_KEEP 30)" "$file_name"
    printf '%s\n' "$dir/$file_name"
    return 0
  fi
  hk_log error "no recovered file could be written for session $sid"
  return 1
}

# ---------------------------------------------------------------------------
# De-duplication and catch-up
# StopFailure is not always run (Claude Code bugs, a force-quit app), and it can run several
# times for one limit. So each chat has a "handled" marker, and the next session start checks
# the newest chats for a limit that ended them with no handoff.
# ---------------------------------------------------------------------------

# hk_handled_path key: the marker file for a chat. The key is the cleaned session id.
hk_handled_path() {
  printf '%s/handled/%s\n' "$(hk_state_dir)" "$1"
}

# hk_debounce_sec: LIMIT_HANDOFF_DEBOUNCE_SEC (default 120), from the environment or the user's own
# config only (a project file could use a huge value to silence every later handoff). At most 3600.
hk_debounce_sec() {
  local d
  d="$(hk_int_conf_trusted LIMIT_HANDOFF_DEBOUNCE_SEC 120)"
  if [ "${#d}" -gt 4 ] || [ "$d" -gt 3600 ]; then d=3600; fi
  printf '%s\n' "$d"
}

# hk_claim_stop key: records that a StopFailure for this chat is being handled now.
# Returns 1 when a StopFailure for the same chat was handled less than LIMIT_HANDOFF_DEBOUNCE_SEC
# seconds ago (a duplicate). Returns 0 otherwise, and writes the current time into the marker.
# The check and the write run under a lock, so two hooks at the same moment cannot both pass.
hk_claim_stop() {
  local key="$1" marker deb now old age rc=0
  marker="$(hk_handled_path "$key")"
  deb="$(hk_debounce_sec)"
  now="$(date +%s)"
  mkdir -p "$(dirname "$marker")" 2>/dev/null
  hk_lock_take "$marker"
  old="$(cat "$marker" 2>/dev/null)"
  if [[ "$old" =~ ^[0-9]{1,12}$ ]]; then
    age=$((now - old))
    if [ "$age" -ge 0 ] && [ "$age" -lt "$deb" ]; then rc=1; fi
  fi
  if [ "$rc" -eq 0 ]; then
    printf '%s\n' "$now" | hk_atomic_write "$marker" 2>/dev/null
  fi
  hk_lock_release
  return $rc
}

# hk_handled_done_path key: the marker that says the handoff for this chat is finished.
hk_handled_done_path() {
  printf '%s.done\n' "$(hk_handled_path "$1")"
}

# hk_checked_path key: the file that remembers a chat catch-up found with no limit at its end.
hk_checked_path() {
  printf '%s/checked/%s\n' "$(hk_state_dir)" "$1"
}

# hk_handled_state key: "done" when the handoff for this chat is finished. "busy" when a
# StopFailure for it started less than LIMIT_HANDOFF_DEBOUNCE_SEC ago and has not finished (it
# may still be running). "stale" when it started but never finished (the hook was stopped half
# way), so a catch-up may retry it. "none" when there is no marker at all.
hk_handled_state() {
  local key="$1" started deb now m
  if [ -e "$(hk_handled_done_path "$key")" ]; then printf 'done\n'; return 0; fi
  started="$(hk_handled_path "$key")"
  if [ ! -e "$started" ]; then printf 'none\n'; return 0; fi
  deb="$(hk_debounce_sec)"
  now="$(date +%s)"
  m="$(hk_file_mtime "$started")" || m=0
  if [ $((now - m)) -lt "$deb" ]; then printf 'busy\n'; else printf 'stale\n'; fi
}

# hk_mark_done key: writes the done marker for this chat. Written after its handoff is saved.
hk_mark_done() {
  printf '%s\n' "$(date +%s)" | hk_atomic_write "$(hk_handled_done_path "$1")" 2>/dev/null
}

# hk_unmark_started key: removes the started marker, so a later catch-up may retry this chat.
hk_unmark_started() {
  rm -f -- "$(hk_handled_path "$1")" 2>/dev/null
}

# hk_iso_epoch iso: the Unix time of a "YYYY-MM-DDTHH:MM:SSZ" time (UTC). Empty when it fails.
# BSD date (macOS) is tried with -j, then GNU date (Ubuntu) with -d.
hk_iso_epoch() {
  local out=""
  out="$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s' 2>/dev/null)" || out=""
  if [ -z "$out" ]; then out="$(date -u -d "$1" '+%s' 2>/dev/null)" || out=""; fi
  case "$out" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s\n' "$out"
}

# hk_epoch_human epoch: "YYYY-MM-DD HH:MM" in the local time zone, the form the cut-off block uses.
# GNU date (-d @N) is tried first, then BSD date (-r N). Empty when it fails.
hk_epoch_human() {
  local out=""
  case "$1" in
    ''|*[!0-9]*) return 0 ;;
  esac
  out="$(LC_ALL=C date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null)" || out=""
  if [ -z "$out" ]; then out="$(LC_ALL=C date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null)" || out=""; fi
  printf '%s\n' "$out"
}

# hk_limit_at json: the time of the limit line (UTC, "YYYY-MM-DDTHH:MM:SSZ") from the recovered
# JSON. Fractions of a second are dropped. Empty when there is no usable time.
hk_limit_at() {
  local t re='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$'
  [ -n "${1:-}" ] || return 0
  t="$(printf '%s' "$1" | jq -r '.limit.at // empty | if type == "string" then . else empty end' 2>/dev/null)"
  if [[ "$t" =~ $re ]]; then printf '%s\n' "$t" | sed 's/\.[0-9]*Z$/Z/'; fi
}

# hk_unresolved_count file: how many unresolved cut-off blocks the file has.
hk_unresolved_count() {
  if [ ! -f "$1" ]; then printf '0\n'; return 0; fi
  hk_unfenced_view "$1" | grep -c '^<!-- limit-handoff:cutoff .*status="unresolved"' 2>/dev/null || true
}

# hk_unresolved_recovered_names file: the file names of the recovered files that unresolved
# cut-off blocks point to. Pruning never deletes these.
hk_unresolved_recovered_names() {
  [ -f "$1" ] || return 0
  awk '
    /^<!-- limit-handoff:cutoff / { inb = ($0 ~ /status="unresolved"/); next }
    /^<!-- \/limit-handoff:cutoff -->/ { inb = 0; next }
    inb && /Recovered context: `/ {
      s = $0
      sub(/.*Recovered context: `/, "", s)
      sub(/`.*/, "", s)
      n = split(s, parts, "/")
      print parts[n]
    }
  ' "$1"
}

# hk_cutoff_message hf block: the reminder for an unresolved cut-off, as one line. It names the
# newest block. With more than one unresolved block, it says how many chats were cut off, lists
# their session ids, and says to resolve each one by id. The one-block wording is the same as before.
hk_cutoff_message() {
  local hf="$1" block="$2" n at reason read_text sid ids
  n="$(hk_unresolved_count "$hf")"
  at="$(hk_block_at_human "$block")"
  reason="$(hk_block_detail "$block")"
  reason="$(hk_with_detail "$(hk_base_reason "$(hk_block_error "$block")" "$reason")" "$reason")"
  read_text="$(hk_read_first_text "$block")"
  sid="$(hk_block_session "$block")"
  if [ "${n:-0}" -gt 1 ]; then
    # The session ids of all unresolved blocks. Only safe ids are shown (letters, digits, _ and -).
    ids="$(hk_unfenced_view "$hf" | awk '/^<!-- limit-handoff:cutoff / && /status="unresolved"/ {
        if (match($0, /session="[^"]*"/)) print substr($0, RSTART + 9, RLENGTH - 10) }' \
      | grep -E '^[A-Za-z0-9_-]{1,80}$' | awk '!seen[$0]++' | head -n 10 | tr '\n' ' ' | sed 's/ $//; s/ /, /g')"
    printf '%s chats were cut off (sessions: %s). The newest is session %s (%s, %s). %s, check for a half-finished step, then run `%s resolve --session <id>` for each chat once it is recovered.' \
      "$n" "${ids:-unknown}" "$sid" "${at:-time unknown}" "$reason" "$read_text" "$(hk_cli_hint)"
  else
    printf '%s has an unresolved cut-off from a previous session (%s, %s). %s, check for a half-finished step, then run `%s resolve` (or delete the cut-off block) once recovered.' \
      "$(hk_handoff_name)" "${at:-time unknown}" "$reason" "$read_text" "$(hk_cli_hint)"
  fi
}

# hk_last_limit_code file norm proj projp: prints the limit code when the last turn of the chat in
# file is a limit error for this project (see lib/lastturn.jq). Prints nothing otherwise.
# Reads at most 300 lines. norm is the list of allowed codes with a space before and after.
# The code is checked again here: lowercase letters and "_" only, and either in the list or
# prompt_too_long.
hk_last_limit_code() {
  local file="$1" norm="$2" proj="$3" projp="$4" out code re='^[a-z_]{1,40}$'
  # Lines first, then bytes, as in hk_recover_json: huge lines cannot fill memory.
  out="$(tail -n 300 "$file" 2>/dev/null | tail -c "$HK_TAIL_BYTES" | jq -n -R -c \
    --arg allowed "$norm" --arg proj "$proj" --arg projp "$projp" \
    -f "$HK_LIB_DIR/lastturn.jq" 2>/dev/null)" || return 0
  code="$(printf '%s' "$out" | jq -r '.code // empty | if type == "string" then . else empty end' 2>/dev/null)"
  if ! [[ "$code" =~ $re ]]; then return 0; fi
  if [ "$code" = "prompt_too_long" ]; then printf '%s\n' "$code"; return 0; fi
  case "$norm" in
    *" $code "*) printf '%s\n' "$code" ;;
  esac
  return 0
}

# hk_catchup: called by session-start.sh before its own checks.
# For a startup, resume or clear (or no source), when LIMIT_HANDOFF_CATCHUP is on and jq exists,
# it looks at the newest chats in the transcript's folder. A chat qualifies when it ended on a limit
# with no handoff (see hk_last_limit_code). For each one, the StopFailure hook is run again in
# "catch-up" mode: no clipboard, no notification. Then one line is printed per handoff written.
# Rules:
#   - Only plain *.jsonl files directly in that folder. No subfolders, no links.
#   - Only chats modified within LIMIT_HANDOFF_CATCHUP_HOURS (default 48).
#   - The current chat is skipped on startup, and included on resume.
#   - A chat is skipped when its handoff is done (done marker), when a StopFailure for it is still
#     running (started less than LIMIT_HANDOFF_DEBOUNCE_SEC ago), or when its block is already in
#     HANDOFF.md in any state. A chat whose start was never finished is retried.
#   - A chat that does not end on a limit is remembered (checked/<session>) with its file time, so
#     it is not read again until the file changes.
#   - At most 3 chats are read, so the start of a session stays fast. The chats handed off are run
#     oldest first, so the newest chat writes PASTE-PROMPT.txt and LATEST.md last.
#   - No new chat is started after 10 seconds. The session start has a 20 second budget.
# It never fails. Session-start goes on either way.
hk_catchup() {
  local src dir cur_name hours mins hf projp norm allowed listing f name sid key code payload n m
  local re='^[A-Za-z0-9_-]{1,80}$' start chosen left sd deb now have stfmt stspec c sm
  src="${HK_SOURCE:-}"
  case "$src" in
    ''|startup|resume|clear) ;;
    *) return 0 ;;
  esac
  [ "$(hk_bool_conf LIMIT_HANDOFF_CATCHUP 1)" = "1" ] || return 0
  hk_have_jq || return 0
  [ -n "${HK_TRANSCRIPT:-}" ] || return 0
  dir="$(dirname "$HK_TRANSCRIPT")"
  [ -d "$dir" ] || return 0
  case "$dir" in -*) dir="./$dir" ;; esac
  cur_name="${HK_TRANSCRIPT##*/}"
  hours="$(hk_int_conf LIMIT_HANDOFF_CATCHUP_HOURS 48)"
  if [ "${#hours}" -gt 6 ]; then hours=100000; fi
  mins=$((hours * 60))
  hf="$(hk_handoff_path)"
  start="$SECONDS"
  # hk_atomic_write needs the folder to exist, so the marker folders are made first.
  mkdir -p "$(hk_state_dir)/checked" "$(hk_state_dir)/handled" 2>/dev/null

  # Values read once, not once per file: a busy project can have hundreds of recent chats, and
  # the session start has a 20 second budget (stress test M3: 1000 chats took 25 s before).
  sd="$(hk_state_dir)"
  deb="$(hk_debounce_sec)"
  now="$(date +%s)"
  # The session ids that already have a block in HANDOFF.md (any state, outside code fences).
  have=""
  if [ -f "$hf" ]; then
    have="$(hk_unfenced_view "$hf" | sed -n 's/^<!-- limit-handoff:cutoff session="\([A-Za-z0-9_-]*\)".*/\1/p')"
  fi
  have=$'\n'"$have"$'\n'
  # One stat call gives the times of all files: BSD stat on macOS, GNU stat on Linux.
  if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then stfmt="-f"; stspec='%m %N'; else stfmt="-c"; stspec='%Y %n'; fi

  # Candidates, as "mtime session" lines, newest first. find keeps only plain files (no links)
  # that are inside the window. A name that is not a safe session id is skipped. The checks below
  # are plain file tests (no subshell per file), so a long list stays fast.
  listing="$(find "$dir" -maxdepth 1 -type f -name '*.jsonl' -mmin "-$mins" -print0 2>/dev/null \
    | xargs -0 stat "$stfmt" "$stspec" 2>/dev/null \
    | while read -r m f; do
        if [ $((SECONDS - start)) -ge 8 ]; then break; fi
        [[ "$m" =~ ^[0-9]+$ ]] || continue
        name="${f##*/}"
        sid="${name%.jsonl}"
        [[ "$sid" =~ $re ]] || continue
        if [ "$src" != "resume" ] && [ "$name" = "$cur_name" ]; then continue; fi
        # The same key as hk_clean_token: the id is already only safe characters, so it is cut to 40.
        key="${sid:0:40}"
        # Done: the handoff is saved. Busy: a StopFailure for it started less than the debounce ago.
        if [ -e "$sd/handled/$key.done" ]; then continue; fi
        if [ -e "$sd/handled/$key" ]; then
          sm="$(hk_file_mtime "$sd/handled/$key")" || sm=0
          if [ $((now - sm)) -lt "$deb" ]; then continue; fi
        fi
        # Its block is already in HANDOFF.md (in any state): the handoff exists. The done marker is
        # put back (the state folder may have been reset). It does not affect the debounce.
        if [[ "$have" == *$'\n'"$key"$'\n'* ]]; then
          hk_mark_done "$key"
          continue
        fi
        c=""
        if [ -f "$sd/checked/$key" ]; then read -r c < "$sd/checked/$key"; fi
        if [ "$c" = "$m" ]; then continue; fi
        printf '%s %s\n' "$m" "$sid"
      done | sort -rn)"

  norm=" $(hk_error_list) "
  projp="$(CDPATH='' cd -P "$HK_PROJECT_DIR" 2>/dev/null && pwd -P)"
  n=0
  chosen=""
  # Each line of the listing is "mtime session". Only safe session ids get this far (the regex above),
  # so each line is one number and one plain id. The lines come in through a here-string, not a
  # pipe, so this loop runs in this shell and the count n is kept.
  while read -r m sid; do
    [ -n "$sid" ] || continue
    if [ "$n" -ge 3 ]; then break; fi
    if [ $((SECONDS - start)) -ge 10 ]; then break; fi
    n=$((n + 1))
    f="$dir/$sid.jsonl"
    key="$(hk_clean_token "$sid")"
    code="$(hk_last_limit_code "$f" "$norm" "$HK_PROJECT_DIR" "$projp")"
    if [ -z "$code" ]; then
      printf '%s\n' "$m" | hk_atomic_write "$(hk_checked_path "$key")" 2>/dev/null
      continue
    fi
    chosen="$chosen$m $sid $code"$'\n'
  done <<<"$listing"

  # Oldest first: the newest chat is written last, so its paste prompt is the one that stays.
  chosen="$(printf '%s' "$chosen" | awk 'NF { a[++k] = $0 } END { for (i = k; i >= 1; i--) print a[i] }')"
  # The time budget never skips the last (newest) chat: older chats are dropped first, and they
  # are tried again at the next session start.
  left="$(printf '%s\n' "$chosen" | grep -c .)"
  while read -r _ sid code; do
    [ -n "$sid" ] || continue
    left=$((left - 1))
    if [ "$left" -gt 0 ] && [ $((SECONDS - start)) -ge 10 ]; then continue; fi
    f="$dir/$sid.jsonl"
    key="$(hk_clean_token "$sid")"
    # The payload is built by jq, never by joining strings. The hook reads it like a real StopFailure.
    payload="$(jq -n --arg s "$sid" --arg t "$f" --arg c "$HK_PROJECT_DIR" --arg e "$code" \
      '{session_id: $s, transcript_path: $t, cwd: $c, hook_event_name: "StopFailure", error: $e}' 2>/dev/null)"
    if [ -z "$payload" ]; then continue; fi
    printf '%s\n' "$payload" | LIMIT_HANDOFF_CATCHUP_RUN=1 /bin/bash "$HK_ROOT/hooks/stop-failure.sh" >/dev/null 2>&1
    # Print the line only when the block for this chat is really in HANDOFF.md.
    if hk_has_session_block "$hf" "$key"; then
      if [ "$code" = "rate_limit" ]; then
        printf 'limit-handoff wrote a handoff for the previous chat (%s). It hit a rate or usage limit and had no handoff.\n' \
          "$(printf '%s' "$key" | cut -c1-8)"
      else
        printf 'limit-handoff wrote a handoff for the previous chat (%s). It stopped (%s) and had no handoff.\n' \
          "$(printf '%s' "$key" | cut -c1-8)" "$(hk_reason_for "$code")"
      fi
    fi
  done <<<"$chosen"
  return 0
}
