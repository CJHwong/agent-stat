#!/bin/bash
# The two faults that once reached a real config and blocked every tool call in
# every session that picked the hook up. scripts/test.sh and the commit hook both
# call this, so the rule has one implementation.
#
# 1. A syntax error exits 2 before a single line runs, and exit 2 from a hook means
#    "block the tool call".
# 2. The hook's jq program is one single-quoted string, so one apostrophe in a
#    comment ends it early and makes the file unparseable.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
status=0

for SCRIPT in "$HERE"/hooks/*.sh; do
    NAME="$(basename "$SCRIPT")"
    if ! sh -n "$SCRIPT"; then
        echo "  FAIL: $NAME does not parse"
        status=1
    elif grep -nE "^[[:space:]]*#.*'" "$SCRIPT"; then
        echo "  FAIL: apostrophe in a comment in $NAME, which can break the jq program"
        status=1
    elif [ ! -x "$SCRIPT" ]; then
        echo "  FAIL: $NAME is not executable"
        status=1
    else
        echo "  $NAME: parses, no apostrophes in comments, executable"
    fi
done

exit $status
