#!/bin/bash
# Unit tests for the model and the reader, then a full app build.
# The real-agent gate is separate: python3 tests/live-probe.py
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HERE/.build/unit-tests"
HOOK="$HERE/hooks/agent-stat-hook.sh"

mkdir -p "$HERE/.build"

# Guard every deployed script before anything else. One implementation, in a
# script, because the commit hook runs the same rule.
echo "deployed script guards"
bash "$HERE/scripts/guard-hooks.sh"

# What the hook writes, driven with a payload instead of an agent. A subagent tool
# call must leave no record: those were most of the file on a busy machine and the
# panel drops them anyway. A subagent start must leave one, because that is what
# keeps its parent's row fresh, and a parent event must still land.
PROBE="$(mktemp -d)"
mkdir -p "$PROBE/hosts"
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"p1","agent_id":"a1","cwd":"/w","tool_name":"Bash"}' \
    | AGENT_STAT_DIR="$PROBE" AGENT_HOOK_AGENT_PID=1 "$HOOK" claude
if [ -n "$(ls -A "$PROBE/hosts" 2>/dev/null)" ]; then
    echo "  FAIL: the hook wrote a record for a subagent tool call"
    rm -r "$PROBE"
    exit 1
fi
printf '%s' '{"hook_event_name":"SubagentStart","session_id":"p1","agent_id":"a1","cwd":"/w"}' \
    | AGENT_STAT_DIR="$PROBE" AGENT_HOOK_AGENT_PID=1 "$HOOK" claude
printf '%s' '{"hook_event_name":"SessionStart","session_id":"p1","cwd":"/w","session_title":"Builder Workshop"}' \
    | AGENT_STAT_DIR="$PROBE" AGENT_HOOK_AGENT_PID=1 "$HOOK" claude
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"p1","cwd":"/w","tool_name":"Bash"}' \
    | AGENT_STAT_DIR="$PROBE" AGENT_HOOK_AGENT_PID=1 "$HOOK" claude
grep -q '"title":"Builder Workshop"' "$PROBE"/hosts/*.jsonl 2>/dev/null || {
    echo "  FAIL: the hook dropped the name Claude Code gives the session"
    exit 1
}
grep -q '"event":"SubagentStart"' "$PROBE"/hosts/*.jsonl 2>/dev/null || {
    echo "  FAIL: the hook dropped a subagent start"
    rm -r "$PROBE"
    exit 1
}
grep -q '"session":"p1"' "$PROBE"/hosts/*.jsonl 2>/dev/null || {
    echo "  FAIL: the hook dropped a parent event"
    rm -r "$PROBE"
    exit 1
}
awk 'END { exit !(NR == 3) }' "$PROBE"/hosts/*.jsonl || {
    echo "  FAIL: expected three records, a session start, a subagent start and a parent event"
    rm -r "$PROBE"
    exit 1
}
echo "  hook: names its session, keeps a subagent start, drops a subagent tool call"
rm -r "$PROBE"
echo

swiftc -o "$BIN" \
    "$HERE/tests/main.swift" \
    "$HERE/tests/watcher.swift" \
    "$HERE/tests/icon.swift" \
    "$HERE/tests/failure.swift" \
    "$HERE/tests/transport.swift" \
    "$HERE/tests/titles.swift" \
    "$HERE/tests/review-regressions.swift" \
    "$HERE/src/CodexTitles.swift" \
    "$HERE/src/FileStamp.swift" \
    "$HERE/src/Record.swift" \
    "$HERE/src/Session.swift" \
    "$HERE/src/SessionStore.swift" \
    "$HERE/src/Liveness.swift" \
    "$HERE/src/EventReader.swift" \
    "$HERE/src/Placement.swift" \
    "$HERE/src/Routes.swift" \
    "$HERE/src/StatusIcon.swift" \
    "$HERE/src/TickClock.swift" \
    "$HERE/src/EventWatcher.swift" \
    "$HERE/src/StatusMenu.swift" \
    "$HERE/src/LoginItem.swift" \
    "$HERE/src/PanelMemory.swift" \
    "$HERE/src/Jump.swift" \
    "$HERE/src/TmuxTargeting.swift" \
    "$HERE/src/Paths.swift" \
    "$HERE/src/RemoteCache.swift"

"$BIN"
python3 -m unittest discover -s "$HERE/tests" -p 'test_*.py'
python3 "$HERE/tests/stream-lifecycle-probe.py" --quick

echo
echo "building the app"
"$HERE/build.sh"
