#!/bin/sh
# tracker-context.sh — SessionStart hook sample for the Aubade tracker.
# Prints the active sprint's incident list into the session context so
# every session starts knowing what is open. Wire it to SessionStart in
# the client's hook config (see examples/hooks/claudecode in the
# aubade repository).
#
# The output follows the Claude Code hook JSON contract, which
# Claude Code-compatible harnesses accept. Hooks receive their input
# as JSON on stdin; this sample ignores it. Set AUBADE_BIN to test
# against a specific binary.

cat >/dev/null

list=$("${AUBADE_BIN:-aubade}" tracker list --sprint current --project-from-cwd 2>/dev/null) ||
	list=$("${AUBADE_BIN:-aubade}" tracker list --project-from-cwd 2>/dev/null) ||
	exit 0

# JSON-escape per line without external JSON tooling: strip CR, widen
# tabs, escape backslash and quote, then join lines as \n escapes.
escaped=
while IFS= read -r line || [ -n "$line" ]; do
	line=$(printf '%s' "$line" | tr -d '\r' | tr '\t' ' ' |
		sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
	escaped="$escaped${escaped:+\\n}$line"
done <<EOF
$list
EOF

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Tracker status for this session:\\n\\n%s"}}\n' "$escaped"
