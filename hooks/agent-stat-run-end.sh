#!/bin/sh
# agent-stat end bridge.
#
# Usage: agent-stat-run-end.sh <agent-session-id>
#
# An orchestrator that runs an agent per turn leaves a row behind: an interactive
# per turn, and tears the tmux pane down when the turn ends. An interactive codex
# reports no end however it ends, so that session leaves a panel row behind with
# nothing to close it. Such an orchestrator knows the turn is over, and names the
# its notify payload, so this script writes the one record that closes the row.
#
# This is not codex reporting its own end, and the event name says so. The panel
# closes the row on RunEnd, never on a SessionEnd that codex did not send.
#
# It is not a hook. Nothing reads its stdout, no 3 second timeout kills it, and a
# broken argument has to be visible. So it exits 2 and prints why, while the hook
# exits 0 on every path.
#
# The record carries three fields: ts, event, session. The panel already has the
# agent name, the folder, the pid and the terminal from that session own hook
# records. A bridge that repeated them could only repeat them wrong.
#
# No apostrophes in these comments. install.py and scripts/test.sh check every
# script in hooks/ for one, because one inside the hook jq program ends it early.
#
# Rule: one writer per file. This runs on the machine that ran the session, so it
# asks uname for the host the same way the hook does, and never caches it here.
# A copied cache must never decide the machine name.

set -u

# Files land as 0600, the same as the hook writes.
umask 077

session=${1:-}
dir=${AGENT_STAT_DIR:-$HOME/.local/state/agent-stat}
hosts="$dir/hosts"

fail() {
    printf 'agent-stat end bridge: %s\n' "$1" >&2
    exit 2
}

[ -n "$session" ] || fail "usage: agent-stat-run-end.sh <agent-session-id>"

# A session id is a uuid. Anything else is a caller bug, and it would also create
# a row that never existed, which the panel would show for a few seconds.
case "$session" in
    *[!0-9a-fA-F-]*) fail "session id is not a uuid: $session" ;;
esac
[ "${#session}" -eq 36 ] || fail "session id is not 36 characters: $session"

host=$(uname -n 2>/dev/null) || fail "uname -n failed"
host=${host%.local}
[ -n "$host" ] || fail "this machine reports no host name"

# One date call for the file name and the timestamp, the same call the hook makes,
# so both writers land in the same day file.
stamp=$(date +"%Y-%m-%d %s" 2>/dev/null) || fail "date failed"
day=${stamp% *}
now=${stamp#* }
[ -n "$day" ] && [ -n "$now" ] || fail "date reported no timestamp"

[ -d "$hosts" ] || mkdir -p "$hosts" 2>/dev/null || fail "cannot create $hosts"
[ -w "$hosts" ] || fail "$hosts is not writable"

# Single append, under 4 KB, so it stays whole when the hook writes at the same
# moment. Never truncate: remote readers keep byte cursors.
printf '{"ts":%s,"event":"RunEnd","session":"%s"}\n' "$now" "$session" \
    >> "$hosts/$host-$day.jsonl" || fail "cannot append to $hosts/$host-$day.jsonl"

exit 0
