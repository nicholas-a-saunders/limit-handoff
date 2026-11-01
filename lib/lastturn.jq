# lib/lastturn.jq - checks whether the last real turn of one chat is a limit error.
#
# Run it like this (the shell passes the last 300 lines of one transcript):
#   tail -n 300 session.jsonl | jq -n -R -c --arg allowed " rate_limit unknown " \
#     --arg proj "/path/to/project" --arg projp "/real/path/to/project" -f lib/lastturn.jq
#
# Output: {"code": "...", "cwd": "..."}. The code is "" when the chat does not end on a limit.
#   - Only main-chain lines count. A subagent copy (isSidechain true) is skipped.
#   - A turn is an assistant line, or a real user prompt (typed text, not a tool result, not meta).
#   - The last turn must be a synthetic limit line (isApiErrorMessage true).
#   - Its error must be in $allowed, or its text must start with "Prompt is too long"
#     (then the code is prompt_too_long).
#   - Its cwd must be the project folder or a folder inside it. A line with no cwd does not count
#     (real limit lines carry one), so a chat without a folder is never handed off by catch-up.
# Nothing in the transcript is run. Text is only read and compared.

# A text block of a message: {"type": "text", "text": "..."}.
def is_text_block: type == "object" and .type == "text" and ((.text | type) == "string");

# The content of a line's message (a string or a list of blocks), or null.
def msg_content: if (.message | type) == "object" then .message.content else null end;

# The first text of a line's message, or "".
def first_text:
  msg_content as $c
  | if ($c | type) == "string" then $c
    elif ($c | type) == "array" then ([ $c[] | select(is_text_block) | .text ] | .[0] // "")
    else "" end;

# A real user prompt: typed text that is not a tool result and not meta.
def is_prompt:
  .type == "user"
  and ((.isMeta // false) != true)
  and (msg_content as $c
       | if ($c | type) == "string" then ($c | test("\\S"))
         elif ($c | type) == "array" then
           ((any($c[]?; type == "object" and .type == "tool_result")) | not)
           and (any($c[]?; is_text_block and (.text | test("\\S"))))
         else false end);

# A main-chain turn: an assistant line, or a real user prompt.
def is_turn: ((.isSidechain // false) != true) and ((.type == "assistant") or is_prompt);

# The folder check. No cwd, or the cwd is the project folder (logical or real path) or inside it.
def cwd_ok:
  (.cwd) as $c
  | if ($c | type) != "string" or $c == "" then false
    else any([$proj, $projp][]; . as $p
              | (type == "string") and (length > 0) and (($c == $p) or ($c | startswith($p + "/")))) end;

# The limit code of a limit line, or "" when it does not count.
def limit_code($allowed):
  (if (.error | type) == "string" then .error else "" end) as $e
  | first_text as $t
  | if $e != "" and ($allowed | split(" ") | any(. == $e)) then $e
    elif ($t | sub("^\\s+"; "") | startswith("Prompt is too long")) then "prompt_too_long"
    else "" end;

[ inputs | fromjson? | select(type == "object") ] as $objs
| ([ $objs[] | select(is_turn) ] | last) as $t
| (if $t == null then ""
   elif $t.type != "assistant" then ""
   elif (($t.isApiErrorMessage // false) != true) then ""
   elif ($t | cwd_ok | not) then ""
   else ($t | limit_code($allowed)) end) as $code
| { code: $code,
    cwd: (if $t == null then "" else (($t.cwd // "") | if type == "string" then . else "" end) end) }
