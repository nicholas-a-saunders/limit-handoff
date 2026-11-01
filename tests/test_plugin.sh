#!/bin/bash
# Static checks: plugin files, executable bits, bash 3.2 rules, no eval, no personal paths.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_plugin_manifest_is_valid_json() {
  jq empty "$TL_ROOT/.claude-plugin/plugin.json" || fail "plugin.json is not valid JSON"
  assert_eq "limit-handoff" "$(jq -r '.name' "$TL_ROOT/.claude-plugin/plugin.json")"
}

test_plugin_manifest_has_the_release_fields() {
  local f="$TL_ROOT/.claude-plugin/plugin.json"
  assert_eq "$(tl_hk_version)" "$(jq -r '.version' "$f")" "plugin.json version must equal HK_VERSION in lib/common.sh (batch B #40)"
  assert_json "$f" '.displayName' "Limit Handoff" "display name"
  assert_json "$f" '.license' "MIT" "license"
  assert_json "$f" '.author.name' "Nicholas Saunders" "author name"
  assert_json "$f" '.author.url' "https://github.com/nicholas-a-saunders" "author url"
  assert_json "$f" '.homepage' "https://github.com/nicholas-a-saunders/limit-handoff" "homepage"
  assert_json "$f" '.repository' "https://github.com/nicholas-a-saunders/limit-handoff" "repository"
  assert_json "$f" '.keywords | index("claude-code") != null' "true" "keywords include claude-code"
}

test_version_is_the_same_in_plugin_json_and_hk_version() {
  # The release workflow checks the tag against plugin.json, and the CLI prints HK_VERSION.
  local v
  v="$(tl_hk_version)"
  [ -n "$v" ] || fail "HK_VERSION not found in lib/common.sh"
  assert_eq "$v" "$(jq -r '.version' "$TL_ROOT/.claude-plugin/plugin.json")" "plugin.json and HK_VERSION differ"
  assert_file_contains "$TL_ROOT/.github/workflows/release.yml" 'lib/common.sh' "release.yml must also check HK_VERSION"
  assert_file_contains "$TL_ROOT/CONTRIBUTING.md" 'HK_VERSION' "CONTRIBUTING must say where the version is set"
}

test_marketplace_manifest_is_valid_and_matches_the_plugin() {
  local m="$TL_ROOT/.claude-plugin/marketplace.json" p="$TL_ROOT/.claude-plugin/plugin.json"
  jq empty "$m" || fail "marketplace.json is not valid JSON"
  assert_json "$m" '.name' "limit-handoff" "marketplace name"
  assert_json "$m" '.plugins | length' "1" "one plugin listed"
  assert_json "$m" '.plugins[0].name' "$(jq -r '.name' "$p")" "listed plugin name matches plugin.json"
  assert_json "$m" '.plugins[0].source' "./" "source is the repository root"
  assert_json "$m" '.description' "$(jq -r '.description' "$p")" "marketplace description matches plugin.json"
  assert_json "$m" '.plugins[0].description' "$(jq -r '.description' "$p")" "listed description matches plugin.json"
}

test_hooks_json_is_valid_and_points_at_real_scripts() {
  local f="$TL_ROOT/hooks/hooks.json" cmd rel path n=0
  jq empty "$f" || fail "hooks.json is not valid JSON"
  for cmd in $(jq -r '.hooks[][].hooks[].command' "$f" | sed 's/"//g'); do
    rel="${cmd#\$\{CLAUDE_PLUGIN_ROOT\}/}"
    path="$TL_ROOT/$rel"
    [ -f "$path" ] || fail "hooks.json refers to a missing script: $rel"
    [ -x "$path" ] || fail "hook script is not executable: $rel"
    n=$((n + 1))
  done
  assert_eq "4" "$n" "four plugin hooks expected"
  assert_eq "rate_limit|billing_error|unknown" "$(jq -r '.hooks.StopFailure[0].matcher' "$f")"
}

test_every_shipped_script_is_executable() {
  local f
  for f in bin/limit-handoff hooks/stop-failure.sh hooks/prompt-submit.sh hooks/session-start.sh hooks/pre-compact.sh tests/run.sh; do
    [ -x "$TL_ROOT/$f" ] || fail "not executable: $f"
  done
}

test_required_files_exist() {
  local f
  for f in lib/common.sh lib/transcript.jq lib/settings.jq templates/HANDOFF.template.md templates/paste-prompt.txt \
           templates/claude-md-snippet.md skills/handoff/SKILL.md config/limit-handoff.conf.example \
           tests/run.sh tests/lib.sh README.md LICENSE CHANGELOG.md; do
    [ -f "$TL_ROOT/$f" ] || fail "missing file: $f"
  done
}

test_license_is_mit_with_owner() {
  assert_file_contains "$TL_ROOT/LICENSE" "MIT License"
  assert_file_contains "$TL_ROOT/LICENSE" "2026 Nicholas Saunders"
}

test_config_example_lines_use_known_keys() {
  local line key bad=0
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key="${line%%=*}"
    key="${key#\# }"
    case "$key" in
      LIMIT_HANDOFF_*) ;;
      *) echo "    unknown line: $line" >&2; bad=1 ;;
    esac
  done < <(grep -v '^[[:space:]]*#' "$TL_ROOT/config/limit-handoff.conf.example" | grep -v '^$')
  assert_eq "0" "$bad" "every config line must be a LIMIT_HANDOFF_ key"
}

test_no_eval_in_shipped_code() {
  local hits
  hits="$(grep -n -E '(^|[^A-Za-z_#`-])eval[[:space:]]' "$TL_ROOT"/lib/*.sh "$TL_ROOT"/bin/limit-handoff "$TL_ROOT"/hooks/*.sh | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
  assert_eq "" "$hits" "eval must not be used"
}

test_bash32_compatible_syntax_only() {
  local hits pat
  for pat in 'declare -A' 'mapfile' 'readarray' '\$\{[A-Za-z_]*,,\}' '\$\{[A-Za-z_]*\^\^\}' '\|&' '&>>' 'local -n' 'declare -n' 'coproc' '\$\(\(\(' 'printf -v'; do
    hits="$(grep -n -E -- "$pat" "$TL_ROOT"/lib/*.sh "$TL_ROOT"/bin/limit-handoff "$TL_ROOT"/hooks/*.sh "$TL_ROOT"/tests/lib.sh "$TL_ROOT"/tests/run.sh 2>/dev/null | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' || true)"
    assert_eq "" "$hits" "bash 4+ syntax found: $pat"
  done
  local f
  for f in lib/common.sh bin/limit-handoff hooks/stop-failure.sh hooks/prompt-submit.sh hooks/session-start.sh hooks/pre-compact.sh; do
    /bin/bash -n "$TL_ROOT/$f" || fail "syntax error in $f"
  done
}

test_no_personal_paths_in_shipped_files() {
  local hits
  # Any home-folder path (macOS /Users/<name>, Linux /home/<name>) is personal. Also the
  # private script path the kit was first written as.
  hits="$(grep -R -l -E '/Users/[A-Za-z]|/home/[a-z]|\.claude/scripts/limit-handoff' \
    "$TL_ROOT/bin" "$TL_ROOT/lib" "$TL_ROOT/hooks" "$TL_ROOT/templates" "$TL_ROOT/skills" "$TL_ROOT/.claude-plugin" "$TL_ROOT/config" "$TL_ROOT/examples" 2>/dev/null || true)"
  assert_eq "" "$hits" "shipped files must not contain personal paths"
}

test_skill_frontmatter_present() {
  local f="$TL_ROOT/skills/handoff/SKILL.md"
  assert_file_contains "$f" "name: handoff"
  assert_file_contains "$f" "description:"
}

test_claude_md_snippet_mentions_resolve() {
  assert_file_contains "$TL_ROOT/templates/claude-md-snippet.md" "limit-handoff resolve"
}

test_gitignore_rules_for_kit_output_only_match_at_the_top() {
  # macOS disks ignore letter case, so a bare "PASTE-PROMPT.txt" rule also hides
  # templates/paste-prompt.txt, which the kit needs. Those rules must start with "/".
  local bad
  bad="$(grep -n -i -E '^(PASTE-PROMPT|\.handoff)' "$TL_ROOT/.gitignore")"
  assert_eq "" "$bad" "kit output rules in .gitignore must be anchored with a leading /"
  assert_file_exists "$TL_ROOT/templates/paste-prompt.txt"
}

run_tests
