#!/bin/sh
# agent-stat hook.
#
# Usage: agent-stat-hook.sh <agent>
#   <agent> is "claude" or "codex". The installer registers it explicitly rather
#   than sniffing the payload, because both tools send the same payload shape.
#
# Reads one JSON hook payload on stdin. Prints "{}" on stdout. Always exits 0.
#
# Rules this script must never break:
#   1. Never exit non-zero. Exit code 2 means "block the tool call", so a broken
#      hook takes the whole agent down with it. The installer wraps this script
#      so the exit code is forced to 0, but do not rely on that.
#   2. Never hang. The registered timeout is 3 seconds and it is enforced.
#   3. Never write to stdout except "{}". Both tools read stdout as a decision.
#   4. No apostrophes anywhere in a comment. The jq program below is one
#      single-quoted string, so one apostrophe in a comment ends it early and
#      makes this file unparseable. scripts/test.sh checks for this.
#
# Why one file per host per day:
#   Each machine owns its local files. Remote readers resume at a byte cursor.
#   Never truncate a file, because that would invalidate every saved cursor.
#
# Why there is no "host" field in the record:
#   The file name carries the host. Only one machine ever writes a given file.
#
# Why the tty is read only on SessionStart:
#   A process keeps its controlling terminal for its whole life, so one read is
#   enough. Ghostty 1.4.0 and later report that tty per surface, which names the
#   tab exactly. It rides on the ps call that already runs for agent_start, so it
#   costs no extra fork.

set -u

# Files land as 0600. Only this user can read session records.
umask 077

agent=${1:-unknown}
dir=${AGENT_STAT_DIR:-$HOME/.local/state/agent-stat}
hosts="$dir/hosts"

# The pid of the agent process, passed in by the registered wrapper. The wrapper
# cannot use exec (it must force a zero exit code), which puts an extra shell
# between the agent and this script, so PPID here would be that shell. The
# fallback covers a hand run of this script, where PPID is right anyway.
agent_pid=${AGENT_HOOK_AGENT_PID:-$PPID}

# Print an empty decision and leave. Every failure path ends here.
emit_empty() {
    printf '{}\n'
    exit 0
}

payload=$(cat 2>/dev/null) || emit_empty
[ -n "$payload" ] || emit_empty

command -v jq >/dev/null 2>&1 || emit_empty

# Host name, asked of this machine. It must not come from a cache file in the
# events directory: a copied cache could claim another machine name. uname costs
# one fork per event, which is the price of being right on every machine.
host=$(uname -n 2>/dev/null) || host=
host=${host%.local}
[ -n "$host" ] || emit_empty

# One date call for both the file name and the timestamp.
stamp=$(date +"%Y-%m-%d %s" 2>/dev/null) || emit_empty
day=${stamp% *}
now=${stamp#* }
[ -n "$day" ] && [ -n "$now" ] || emit_empty

[ -d "$hosts" ] || mkdir -p "$hosts" 2>/dev/null || emit_empty
[ -w "$hosts" ] || emit_empty

# agent_start pins the pid to a process start time, so a recycled pid cannot look
# like a live session. Only SessionStart pays for the ps call, which keeps the
# per tool call path at one jq and one date.
#
# One ps call answers both. The start time is five fields and the tty is the last
# one, so collapse the run of spaces between them and split on the final space. A
# process with no terminal prints "??", which is recorded as no tty at all.
start=null
tty=
case "$payload" in
    *'"SessionStart"'*)
        psline=$(ps -o lstart=,tty= -p "$agent_pid" 2>/dev/null | sed 's/  */ /g;s/^ //;s/ $//')
        tty=${psline##* }
        start=${psline% *}
        [ -n "$start" ] || start=null
        case "$tty" in
            ''|'??') tty= ;;
            *) tty=/dev/$tty ;;
        esac
        ;;
esac

# One jq call builds the whole record. The shape is fixed and the raw payload is
# never dumped, so lines stay small enough that concurrent appends are atomic and
# the reader never has to know either tool full payload schema.
#
# term and tmux come from the environment the agent inherited, so they cost no
# fork. They are what lets the panel take you back to the right tab.
#
# agent_id is present only for an event raised inside a subagent or an in-process
# teammate. Those events belong to the parent row, so a subagent tool call is
# dropped here, before the record is built. The panel drops those anyway,
# and on a busy machine they were most of the file, measured on one host at 2069
# of 3184 records in a day. What is kept is the start and the stop: two records
# per subagent say the parent is still working, which is what lets its row stay
# fresh and say how many subagents are running.
#
# A Codex name can arrive after SessionStart or change during a session. Read the
# current profile index on each event so later hooks capture the latest name.
# Missing indexes must never stop an event or make the hook wait on a pipe.
names_file=/dev/null
candidate=${CODEX_HOME:-$HOME/.codex}/session_index.jsonl
if [ "$agent" = codex ] && [ -f "$candidate" ] && [ -r "$candidate" ]; then
    names_file=$candidate
fi
#
# A payload title takes precedence. Indexed names stay under 200 characters so a
# large name does not turn a small hook record into a large append.
#
# dur_ms is a Claude Code field. Codex does not send it, so it is null for every
# codex tool call. Readers derive elapsed time from the PreToolUse and
# PostToolUse timestamps and treat dur_ms as an optional cross check.
#
# Keep comments out of the program below. See rule 4 at the top of this file.
make_record() {
    printf '%s' "$payload" | jq -c \
    --rawfile names "$1" \
    --arg agent "$agent" \
    --argjson ts "$now" \
    --arg pid "$agent_pid" \
    --arg start "$start" \
    --arg term "${TERM_PROGRAM-}" \
    --arg tmux "${TMUX_PANE-}" \
    --arg tty "$tty" '
    def codex_title($session):
        reduce ($names | split("\n")[] | fromjson?
                | select(type == "object" and .id == $session)
                | .thread_name | select(type == "string" and length > 0))
            as $name (null; $name)
        | if . == null then null
          else (gsub("[\\n\\r\\t]+"; " ") | .[0:200]) end;
    select((.agent_id // null) == null
           or .hook_event_name == "SubagentStart"
           or .hook_event_name == "SubagentStop")
    | .session_id as $session
    | {
        v: 1,
        ts: $ts,
        agent: $agent,
        agent_pid: ($pid | tonumber? // 0),
        agent_start: (if $start == "null" then null else $start end),
        term: (if $term == "" then null else $term end),
        tmux: (if $tmux == "" then null else $tmux end),
        tty: (if $tty == "" then null else $tty end),
        event: (.hook_event_name // "unknown"),
        source: (.source // null),
        agent_id: (.agent_id // null),
        session: (.session_id // ""),
        cwd: (.cwd // ""),
        turn: (.prompt_id // .turn_id // null),
        model: (.model // null),
        title: ((.session_title // null)
                | if $agent != "codex" then .
                  elif type == "string" and length > 0 then .
                  else codex_title($session) end),
        tool: (.tool_name // null),
        dur_ms: (.duration_ms // null),
        message: (
            (.last_assistant_message // null)
            | if . == null then null
              else (gsub("[\\n\\r\\t]+"; " ") | .[0:120])
              end
        )
    }' 2>/dev/null
}

# An atomic index replacement can remove the selected file before jq opens it.
# Retry without the index so a failed name lookup never drops the event.
record=$(make_record "$names_file") || record=$(make_record /dev/null) || emit_empty

[ -n "$record" ] || emit_empty

# Single append. Keep the record under 4 KB so the kernel writes it whole even
# when several agents fire hooks at the same moment.
printf '%s\n' "$record" >> "$hosts/$host-$day.jsonl" 2>/dev/null || emit_empty

emit_empty
