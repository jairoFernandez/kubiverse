#!/usr/bin/env bash
# Claude Code hook (.claude/settings.json): runs scripts/test-guard.sh and,
# when existing tests were weakened without a "Test-Change:" trailer, tells
# Claude (additionalContext) and the user (systemMessage). Never blocks.
#
#   Stop                       -> uncommitted changes vs HEAD
#   PostToolUse on Bash        -> after a "git commit": the commit just made
#
# Fast when nothing guarded changed (test-guard.sh exits after one
# "git diff --name-only"); fails open on anything odd.
command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)" || exit 0
event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
cd "${cwd:-${CLAUDE_PROJECT_DIR:-.}}" 2>/dev/null || exit 0
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
guard="$root/scripts/test-guard.sh"
[ -x "$guard" ] || exit 0

case "$event" in
Stop|SubagentStop)
	out="$("$guard" --worktree 2>&1)"; rc=$?
	what="Your uncommitted changes"
	;;
PostToolUse)
	cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
	printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)' || exit 0
	printf '%s' "$cmd" | grep -Eq -- '--dry-run' && exit 0
	git rev-parse -q --verify HEAD~1 >/dev/null 2>&1 || exit 0
	out="$("$guard" HEAD~1 HEAD 2>&1)"; rc=$?
	what="The commit you just made"
	;;
*) exit 0 ;;
esac

[ "$rc" = 1 ] || exit 0
msg="$what weaken existing tests (scripts/test-guard.sh):
$out
Do not weaken tests to make a change pass: fix the code instead. If the old test really was wrong, fix it in its own commit whose message ends with a 'Test-Change: <why>' trailer, and tell the user."
jq -cn --arg e "$event" --arg m "$msg" \
	'{systemMessage: "test-guard: existing tests were weakened (see the transcript)", hookSpecificOutput: {hookEventName: $e, additionalContext: $m}}'
exit 0
