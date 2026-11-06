# lib/transcript.jq - turns the end of a Claude Code transcript into recovered-context JSON.
#
# Run it like this (the shell passes the last N lines):
#   tail -n 4000 session.jsonl | jq -n -R -c --argjson np 5 -f lib/transcript.jq
#
# Rules:
#   - Every line is read as text first. Lines that are not JSON objects are skipped.
#   - The transcript format is internal and may change. Unknown line types are ignored.
#   - Nothing in the transcript is ever run. It is only read and copied as text.

# Cut long text. Appends an ellipsis when something was removed.
def clip($n): if type == "string" and length > $n then .[0:$n] + "…" else . end;

# Text shown as one line of plain text (task text, file paths, commands): control characters
# are removed (also the Unicode line separators and the marks that flip text direction) and
# backticks become apostrophes, so the text cannot break a Markdown code span, start a new line
# or heading, or show in a misleading order. Multi-line prompts keep their line breaks (they are quoted).
def plain: gsub("[[:cntrl:]\u2028\u2029\u200e\u200f\u202a-\u202e\u2066-\u2069]"; "") | gsub("`"; "'");

# Token-shaped strings are replaced with [redacted] before anything is written:
#   - private key blocks (-----BEGIN ... PRIVATE KEY----- to the END line, or to the end of the text);
#   - API keys and access tokens in their usual shapes (Anthropic/OpenAI sk-, Stripe sk_live_/rk_/pk_,
#     GitHub, Google AIza, npm, AWS key ids, Slack, JWTs);
#   - the password in a URL (scheme://user:PASSWORD@host);
#   - the value after a secret-like name (password=, "api_key": "...", TOKEN=, secret: ...);
#   - the token after "Bearer";
#   - command-line passwords and keys (--password X, mysql -pX, sshpass -p X), upper-case
#     variables that end in PASS, SECRET, TOKEN or _KEY (DB_PASS=...), API-key and Authorization
#     headers, and Twilio (SK...), Mailgun (key-...) and SendGrid (SG.x.y) keys;
#   - long runs (40 or more) of hex, or of base64 letters that mix letters and digits. A run that
#     contains "/" (an AWS secret key, a line of a key file) must also mix upper and lower case,
#     must not start with "/" and must not follow a letter, digit, "+" or "/", so file paths are kept.
# hk_redact_line in lib/common.sh reads the lines between the two marker comments, so keep them.
# >>> redact
def redact:
  gsub("-----BEGIN[A-Z ]*PRIVATE KEY-----[\\s\\S]*?(?:-----END[A-Z ]*PRIVATE KEY-----|\\z)"; "[redacted private key]")
  | gsub("sk-[A-Za-z0-9_-]{16,}"; "[redacted]")
  | gsub("[rsp]k_(?:live|test)_[A-Za-z0-9]{10,}"; "[redacted]")
  | gsub("gh[pousr]_[A-Za-z0-9]{20,}"; "[redacted]")
  | gsub("github_pat_[A-Za-z0-9_]{20,}"; "[redacted]")
  | gsub("AIza[0-9A-Za-z_-]{30,}"; "[redacted]")
  | gsub("npm_[A-Za-z0-9]{20,}"; "[redacted]")
  | gsub("(?:AKIA|ASIA)[0-9A-Z]{16}"; "[redacted]")
  | gsub("xox[abpors]-[A-Za-z0-9-]{10,}"; "[redacted]")
  | gsub("eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"; "[redacted]")
  | gsub("(?<k>[A-Za-z][A-Za-z0-9+.-]*://[^/\\s:@]+:)[^@\\s/]+@"; "\(.k)[redacted]@")
  | gsub("(?<k>(?<![A-Za-z])(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret)[A-Za-z0-9_]*[\"']?(?:\\s*=\\s*|:\\s*(?=[\"'])|:(?=[^\\s/]))[\"']?)[^\\s\"'&;,]{3,}"; "\(.k)[redacted]"; "i")
  | gsub("(?<k>(?<![A-Za-z])bearer\\s+)[A-Za-z0-9._~+/=-]{16,}"; "\(.k)[redacted]"; "i")
  | gsub("(?<k>(?<![A-Za-z0-9_-])--(?:password|passwd|pass|token|api-key|apikey|secret|client-secret)(?:=|\\s+))[\"']?[^\\s\"']{3,}[\"']?"; "\(.k)[redacted]"; "i")
  | gsub("(?<k>\\b(?:mysql|mysqldump|mysqladmin|mariadb)\\b[^\\n|;&]*?\\s-p)[^\\s\"']+"; "\(.k)[redacted]")
  | gsub("(?<k>\\bsshpass\\s+-p\\s*)[\"']?[^\\s\"']+[\"']?"; "\(.k)[redacted]")
  | gsub("(?<k>(?<![A-Za-z0-9_])[A-Z0-9_]*(?:PASS|PASSWD|SECRET|TOKEN|APIKEY|API_KEY|_KEY)\\s*=\\s*)[\"']?[^\\s\"'&;,]{3,}"; "\(.k)[redacted]")
  | gsub("(?<k>(?<![A-Za-z0-9-])(?:x-api-key|api-key|x-auth-token|authorization)\\s*:\\s*(?:basic\\s+|token\\s+)?)[^\\s\"']{8,}"; "\(.k)[redacted]"; "i")
  | gsub("(?<![A-Za-z0-9])(?:SK[0-9a-fA-F]{32}|key-[0-9a-zA-Z]{32})(?![A-Za-z0-9])"; "[redacted]")
  | gsub("SG\\.[A-Za-z0-9_-]{16,}\\.[A-Za-z0-9_-]{16,}"; "[redacted]")
  | gsub("[A-Fa-f0-9]{40,}"; "[redacted]")
  | gsub("(?=[A-Za-z0-9+]*[0-9])(?=[A-Za-z0-9+]*[A-Za-z])[A-Za-z0-9+]{40,}"; "[redacted]")
  | gsub("(?<![A-Za-z0-9+/])(?=[A-Za-z0-9+/]*/)(?=[A-Za-z0-9+/]*[0-9])(?=[A-Za-z0-9+/]*[a-z])(?=[A-Za-z0-9+/]*[A-Z])[A-Za-z0-9+][A-Za-z0-9+/]{39,}=*"; "[redacted]");
# <<< redact

# Output text: redacted, then cut. Plain text also loses its control characters and backticks.
# The text is first cut to a little more than $n, so the redact patterns never scan a huge string
# (a token that crosses the final cut is still seen whole and redacted). Before that cut, every
# token-like run of 200 or more characters becomes "[redacted]" (no real word is that long), so a
# long key in the middle of a prompt does not take the rest of the prompt with it. A token-like
# run cut by the precut itself is dropped, so no part of it can show.
def precut($n):
  if type == "string" and length > ($n + 200)
  then .[0:($n * 4 + 2000)] | gsub("[A-Za-z0-9_+/=-]{200,}"; "[redacted]")
       | if length > ($n + 200) then .[0:($n + 200)] | sub("[A-Za-z0-9_+/=-]+$"; "") else . end
  else . end;
def clean($n): precut($n) | redact | clip($n);
# raw($n): the text kept while the lines are read, only cut (precut keeps a little more than $n so
# a token that crosses the cut is still seen whole later). The output runs clean_plain on the few
# items that are kept, so the slow redact patterns never run on thousands of items.
def raw($n): precut($n);
def clean_plain($n): precut($n) | plain | redact | clip($n);

# A user message whose content is a list containing tool results is not a real prompt.
def is_tool_result_list:
  type == "array" and any(.[]?; type == "object" and .type == "tool_result");

# Message content can be a plain string or a list of blocks. Keep only the text blocks.
def content_text:
  if type == "string" then .
  elif type == "array" then
    [ .[]? | select(type == "object" and .type == "text") | (.text // "") | select(type == "string") ]
    | join("\n")
  else "" end;

# Text that Claude Code writes around real prompts. These are not things the user typed.
def is_system_text($t):
  ($t | sub("^\\s+"; "")) as $s
  | any(["<task-notification", "<system-reminder", "<command-name", "<command-message", "<local-command", "Caveat:"][];
        . as $p | $s | startswith($p));

# Status words from different tools mapped to three values.
def norm_status:
  if . == "completed" or . == "done" or . == "complete" then "completed"
  elif . == "in_progress" or . == "in-progress" or . == "active" then "in_progress"
  elif . == "deleted" then "deleted"
  else "pending" end;

def str: if type == "string" then . else tostring end;

# The "message" of a line when it is an object. Any other shape (a string, a number,
# a list, null) gives an empty object, so reading .content never fails on odd lines.
def msg: if (.message | type) == "object" then .message else {} end;

# Remove whole <system-reminder>...</system-reminder> sections from a text.
# Some clients put a reminder and the typed prompt in the same message.
# The text is split at each opening tag and each piece is read once, so the time grows in step
# with the text. (A lazy regex scanned to the end of the text for every unclosed opening tag: a
# prompt with many of them took more than the hook's 30 s.) Same result as that regex: a section
# runs from an opening tag to the first closing tag after it, so pieces up to the last piece
# that has a closing tag keep only the text after their closing tag (a piece with none is inside
# a section). Opening tags after that last closing tag are kept as text.
# Only the first 1,000,000 characters are read (far more than any real reminder), so even a
# hostile prompt is done in well under a second. split is used, not index: jq 1.6 gives index
# in bytes, which would cut text with non-English letters in the wrong place.
# Text over 2000 characters is cut first, then trimmed, then gets an ellipsis. On a long run of spaces the trim is slow, and clean cuts the text to 600
# characters anyway.
def strip_reminders:
  (if length > 1000000 then .[0:1000000] else . end)
  | split("<system-reminder>") as $parts
  | [ $parts[1:][] | split("</system-reminder>") ] as $sp
  | (([ $sp | to_entries[] | select(.value | length > 1) | .key ] | last) // -1) as $last
  | ([ $parts[0] ]
     + [ range(0; $last + 1) | $sp[.] | select(length > 1) | .[1:] | join("</system-reminder>") ]
     + [ range($last + 1; $sp | length) | "<system-reminder>" + $parts[. + 1] ])
  | join("")
  | sub("^\\s+"; "")
  | (if length > 2000 then (.[0:2000] | sub("\\s+$"; "")) + "…" else sub("\\s+$"; "") end);

# The typed part of a user message. For a list of blocks, each text block is checked on
# its own, so a system block next to a typed block does not hide the typed one.
def user_text:
  if type == "string" then strip_reminders
  elif type == "array" then
    [ .[]? | select(type == "object" and .type == "text") | (.text // "") | select(type == "string")
      | strip_reminders | select(test("\\S") and (is_system_text(.) | not)) ]
    | join("\n")
  else "" end;

# The real user prompt text of a line, as a list (empty list when it is not a prompt).
def real_prompts:
  if .type == "user"
     and ((.isMeta // false) | not)
     and ((.isSidechain // false) != true)
     and ((msg.content // null) | is_tool_result_list | not)
  then
    (msg.content | user_text) as $t
    | if ($t | test("\\S")) and (is_system_text($t) | not) then [$t] else [] end
  else [] end;

# Text blocks of an assistant line, as a list. A synthetic API error line (isApiErrorMessage)
# is never a reply, so its text is left out: the real last reply must win. A subagent's line
# (isSidechain true) is not the main chat's reply either.
def assistant_texts:
  if .type == "assistant" and ((.isApiErrorMessage // false) == false) and ((.isSidechain // false) != true)
     and ((msg.content | type) == "array") then
    [ msg.content[] | select(type == "object" and .type == "text") | .text
      | select(type == "string" and test("\\S")) ]
  else [] end;

# A synthetic line that Claude Code writes when a limit stops the chat. A subagent copy
# (isSidechain true) does not count.
def is_limit_line:
  .type == "assistant" and ((.isApiErrorMessage // false) == true) and ((.isSidechain // false) != true);

# A value that is an object, or an empty object when it is not (so a field lookup never fails).
def obj_or_empty: if type == "object" then . else {} end;

# The first text block of a limit line, with newlines removed and cut to 200 characters.
def limit_text:
  (msg.content) as $c
  | (if ($c | type) == "array"
     then ([ $c[] | select(type == "object" and .type == "text") | .text | select(type == "string") ] | .[0] // "")
     elif ($c | type) == "string" then $c
     else "" end)
  | gsub("[\\r\\n]"; "") | clean(200);

# The limit facts of a limit line: the error code, the limit type, the reset time (epoch
# seconds, only when it is a number) and the first text block.
def limit_info:
  (.quotaLimits | obj_or_empty) as $q
  | (.apiErrorParams | obj_or_empty | .rate_limit_info | obj_or_empty) as $r
  | {
      error: ((.error // "") | if type == "string" then . else "" end),
      at: (.timestamp | if type == "string" then . else null end),
      type: (($q.rateLimitType // $r.rateLimitType // "") | if type == "string" then . else "" end),
      resets_at: (($q.resetsAt // $r.resetsAt) | if type == "number" then . else null end),
      text: limit_text
    };

# Tool calls of an assistant line, as a list.
def tool_uses:
  if .type == "assistant" and ((msg.content | type) == "array") then
    [ msg.content[] | select(type == "object" and .type == "tool_use") ]
  else [] end;

# Tool results of a user line, as a list.
def tool_results:
  if .type == "user" and ((msg.content | type) == "array") then
    [ msg.content[] | select(type == "object" and .type == "tool_result") ]
  else [] end;

def is_file_tool($n): (["Edit", "Write", "MultiEdit", "NotebookEdit"] | any(. == $n));

# Add a prompt unless it repeats the previous one.
def add_prompt($p):
  if (.prompts | length) > 0 and .prompts[-1] == $p then .
  else .prompts += [$p] end;

# Put the task list in order: first the in-progress step, then the pending ones.
def idx_where(f): [ to_entries[] | select(.value | f) | .key ] | .[0];

# "advance": the in-progress step is done, the next pending step starts.
def advance_list:
  idx_where(.status == "in_progress") as $cur
  | if $cur == null then
      (idx_where(.status == "pending") as $n
       | if $n == null then . else .[$n].status = "in_progress" end)
    else
      .[$cur].status = "completed"
      | ([ to_entries[] | select(.key > $cur and .value.status == "pending") | .key ] | .[0]) as $n
      | if $n == null then . else .[$n].status = "in_progress" end
    end;

# A full plan list replaces the old one. Entries without "content" are ignored.
def replace_tasks($items):
  .tasks = [ $items[] | select(type == "object" and has("content"))
             | {content: (.content | str | raw(600)), status: ((.status // "pending") | str | norm_status)} ]
  | .task_ids = {} | .pending_creates = {};

# update_plan with "done" (1-based list) and "start" (1-based number).
def apply_done_start($i):
  reduce ((if ($i.done | type) == "array" then $i.done else [] end) | map(select(type == "number") | floor) | .[]) as $k (.;
    if $k >= 1 and $k <= (.tasks | length) then .tasks[$k - 1].status = "completed" else . end)
  | (if ($i.start | type) == "number" then ($i.start | floor) else null end) as $s
  | if $s != null and $s >= 1 and $s <= (.tasks | length) then
      .tasks |= map(if .status == "in_progress" then .status = "pending" else . end)
      | .tasks[$s - 1].status = "in_progress"
    else . end;

# update_plan: a full list, an {advance: true} item, or the done/start form.
def apply_plan($i):
  if ($i.items | type) == "array" and ($i.items | any(type == "object" and .advance == true)) then
    .tasks |= advance_list
  elif ($i.items | type) == "array" then
    replace_tasks($i.items)
  elif $i.advance == true then
    .tasks |= advance_list
  elif (($i.done | type) == "array") or (($i.start | type) == "number") then
    apply_done_start($i)
  else . end;

# A tool call from an assistant line.
def apply_tool($u):
  ($u.name // "" | str) as $n
  | (if ($u.input | type) == "object" then $u.input else {} end) as $i
  | if $n == "TodoWrite" then
      .tasks = [ ($i.todos // []) | if type == "array" then .[] else empty end
                 | select(type == "object")
                 | {content: ((.content // .activeForm // "") | str | raw(600)), status: ((.status // "pending") | str | norm_status)} ]
      | .task_ids = {} | .pending_creates = {}
    elif ($n | endswith("update_plan")) then apply_plan($i)
    elif $n == "TaskCreate" then
      (.tasks | length) as $pos
      | .tasks += [{content: ((($i.subject // $i.description // "") | str | raw(600))), status: "pending"}]
      | if ($u.id | type) == "string" then .pending_creates[$u.id] = $pos else . end
    elif $n == "TaskUpdate" then
      (($i.taskId // "") | str) as $tid
      | (.task_ids[$tid] // null) as $pos
      | if $pos == null or ($i.status == null) then .
        else .tasks[$pos].status = (($i.status | str) | norm_status) end
    elif is_file_tool($n) then
      (($i.file_path // $i.notebook_path // null) | if type == "string" then raw(400) else null end) as $p
      | if ($p | type) == "string" and $p != "" then
          .files = (([$p] + (.files | map(select(. != $p)))) | .[0:20])
        else . end
    elif $n == "Bash" then
      (($i.command // null)) as $c
      | if ($c | type) == "string" and ($c | test("\\S")) then
          .commands = ((.commands + [{command: ($c | raw(200)),
                                      description: ((($i.description // "") | str) | raw(200))}]) | .[-5:])
        else . end
    else . end;

# A tool result: if it answers a TaskCreate, remember the number Claude Code gave the task.
def note_result($r):
  (($r.tool_use_id // "") | str) as $id
  | if (.pending_creates | has($id)) then
      (.pending_creates[$id]) as $pos
      | ((($r.content // "") | content_text) | [ scan("#([0-9]+)") | .[0] ] | .[0]) as $num
      | del(.pending_creates[$id])
      | if $num != null then .task_ids[$num] = $pos else . end
    else . end;

# One transcript line as JSON. jq refuses a lone UTF-16 surrogate escape (half an emoji, such as
# \ud83d), which would drop the whole line. Only when the line does not parse, each lone surrogate
# escape is replaced by \ufffd and the line is read again. Normal lines keep their full speed.
def parse_line:
  fromjson? // (if test("\\\\u[dD][89a-fA-F]") then
                  gsub("\\\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\\\u[dD][c-fC-F][0-9a-fA-F]{2})"; "\\ufffd")
                  | gsub("(?<!\\\\u[dD][89abAB][0-9a-fA-F]{2})\\\\u[dD][c-fC-F][0-9a-fA-F]{2}"; "\\ufffd")
                  | fromjson?
                else empty end);

# One transcript line updates the running state.
def step($e):
  if $e.type == "user" then
    ($e | real_prompts) as $ps
    | (if ($ps | length) > 0 then add_prompt($ps[0]) else . end)
    # A typed prompt of the main chat means the chat went on, so an old limit no longer counts.
    | (if ($ps | length) > 0 and (($e.isSidechain // false) != true) then .limit = null else . end)
    | (if ($e.isSidechain // false) == true then . else reduce ($e | tool_results | .[]) as $r (.; note_result($r)) end)
  elif $e.type == "assistant" then
    (if ($e | is_limit_line) then .limit = ($e | limit_info)
     elif (($e.isSidechain // false) != true) then .limit = null
     else . end)
    | ($e | assistant_texts) as $ts
    | (if ($ts | length) > 0 then .assistant = $ts[-1] else . end)
    # A subagent's file edits and commands are real work in the project, so they count. Its task
    # list is its own, so its task tools are skipped.
    | reduce ($e | tool_uses | .[]) as $u (.;
        if (($e.isSidechain // false) == true) and ((is_file_tool($u.name // "" | str) or ($u.name == "Bash")) | not)
        then . else apply_tool($u) end)
  elif $e.type == "last-prompt" and (($e.lastPrompt | type) == "string") then
    .last_prompt = $e.lastPrompt
  else . end;

{prompts: [], assistant: null, tasks: [], pending_creates: {}, task_ids: {}, files: [], commands: [], last_prompt: null, limit: null} as $init
| [ inputs ] as $raw
| ([ $raw[] | parse_line | select(type == "object") ]) as $objs
| (reduce $objs[] as $e ($init; step($e))) as $st
| ($st.prompts) as $prompts
| (if ($prompts | length) == 0 and ($st.last_prompt != null) then [$st.last_prompt] else $prompts end) as $all
| {
    first_prompt: ($all[0] | if . == null then null else clean(600) end),
    last_prompts: (if $np <= 0 then []
                   else ($all | .[([0, (length - $np)] | max):] | map(clean(600))) end),
    last_assistant_text: ($st.assistant | if . == null then null else clean(800) end),
    tasks: [ $st.tasks[] | select(.status != "deleted") | {content: (.content | clean_plain(600)), status: .status} ],
    files_touched: ($st.files | map(clean_plain(400)) | reduce .[] as $f ([]; if any(.[]; . == $f) then . else . + [$f] end)),
    last_commands: [ $st.commands[] | {command: (.command | clean_plain(200)), description: (.description | clean_plain(200))} ],
    limit: $st.limit,
    line_count: ($raw | length)
  }
