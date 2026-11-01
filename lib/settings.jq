# lib/settings.jq - reads and edits a Claude Code settings.json for limit-handoff.
#
# Inputs (passed by bin/limit-handoff):
#   $mode    "install" | "uninstall" | "count" | "events"
#   $root    absolute path of this kit (used to build the hook commands)
#   $errors  the StopFailure matcher, for example "rate_limit|billing_error|unknown"
#   $sel     JSON list of hook ids to install, for example ["stop-failure"]
#
# Only entries that look like limit-handoff hooks are changed. Everything else is kept.
# A kit entry is a hook whose command ends in /hooks/<kit script>.sh AND either
# carries the "# limit-handoff" marker (every install writes it) or has a folder named
# exactly "limit-handoff" in its path. A folder that only contains the word "handoff"
# (for example /work/handoff/hooks/session-start.sh) belongs to the user and is kept.
# A command that is not text (a number, a list) is never a kit entry, and never an error.

def is_kit:
  if type != "object" then false
  else
    (if (.command | type) == "string" then .command else "" end) as $c
    | ($c | test("/hooks/(stop-failure|prompt-submit|session-start|pre-compact)\\.sh'?( # limit-handoff)?$"))
      and (($c | test(" # limit-handoff$")) or ($c | test("/limit-handoff/hooks/")))
  end;

# Shell-quote a path with single quotes, so spaces are safe.
def shq: "'" + (gsub("'"; "'\\''")) + "'";

def table: [
  {id: "stop-failure",  event: "StopFailure",      script: "stop-failure.sh",  timeout: 30},
  {id: "prompt-submit", event: "UserPromptSubmit", script: "prompt-submit.sh", timeout: 5},
  {id: "session-start", event: "SessionStart",     script: "session-start.sh", timeout: 20},
  {id: "pre-compact",   event: "PreCompact",       script: "pre-compact.sh",   timeout: 30}
];

def group_for($t):
  (if $t.id == "stop-failure" then {matcher: $errors} else {} end)
  + {hooks: [ {type: "command",
               command: ((($root + "/hooks/" + $t.script) | shq) + " # limit-handoff"),
               timeout: $t.timeout} ]};

# Remove kit hooks from one group. A group that loses all its hooks is dropped.
def strip_group:
  if (type != "object") or ((.hooks | type) != "array") then .
  else
    (.hooks | length) as $n
    | .hooks |= map(select(is_kit | not))
    | if ($n > 0 and (.hooks | length) == 0) then empty else . end
  end;

# Remove kit hooks from one event. An event list that becomes empty is deleted.
def clean_event($ev):
  if ((.hooks | type) == "object") and ((.hooks[$ev] | type) == "array") then
    (.hooks[$ev] | length) as $before
    | (.hooks[$ev] | map(strip_group)) as $after
    | if (($after | length) == 0) and ($before > 0) then del(.hooks[$ev])
      else .hooks[$ev] = $after end
  else . end;

. as $orig
| if $mode == "count" then
    [ .. | objects | select(has("command")) | select(is_kit) ] | length
  elif $mode == "bad" then
    [ .. | objects | select(has("command")) | select((.command | type) != "string") ] | length
  elif $mode == "events" then
    [ (if (.hooks | type) == "object" then .hooks else {} end) | to_entries[]
      | .key as $k
      | (if (.value | type) == "array" then .value else [] end)[]
      | select(type == "object")
      | (if (.hooks | type) == "array" then .hooks else [] end)[]
      | select(is_kit)
      | $k ] | unique | .[]
  else
    reduce ["StopFailure", "UserPromptSubmit", "SessionStart", "PreCompact"][] as $ev (.; clean_event($ev))
    | (if ((.hooks | type) == "object") and ((.hooks | length) == 0)
          and ((($orig.hooks | type) == "object") and (($orig.hooks | length) > 0))
       then del(.hooks) else . end)
    | reduce ([ table[] | select(.id | IN($sel[])) ][]) as $t (.;
        .hooks = (if (.hooks | type) == "object" then .hooks else {} end)
        | .hooks[$t.event] = ((if (.hooks[$t.event] | type) == "array" then .hooks[$t.event] else [] end)
                              + [group_for($t)]))
  end
