#!/usr/bin/env bash
# Claude Code PreToolUse hook (.claude/settings.json): asks the user before
# Claude changes an EXISTING test, baseline or guard file. New test files go
# through without asking. Reads the hook JSON on stdin; prints a decision only
# for protected files and fails open (no output, exit 0) on anything odd.
#
#   Edit / Write / MultiEdit / NotebookEdit  -> tool_input.file_path / notebook_path
#   Bash                                     -> a command that rewrites, moves or
#                                               deletes a protected path
command -v jq >/dev/null 2>&1 || exit 0
input="$(cat)" || exit 0
root="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# Protected, relative to the repo root (extended regex).
PROTECTED='^(bridge/(.*/)?[^/]*_test\.go|bridge/coverage-baseline\.txt|bridge/testdata/fuzz/.*|game/tests/[^/]*\.(gd|txt)|scripts/test-guard\.sh|scripts/coverage\.sh|scripts/game-tests\.sh|scripts/hooks/[^/]*|scripts/claude-hooks/[^/]*|tools/testlint/.*\.go|\.claude/settings\.json)$'

REASON='Existing tests, baselines and test guards must not be weakened to make a change pass (CLAUDE.md, CONTRIBUTING.md). Approve only if the change is warranted: a test that was really wrong (fix it in its own commit with a "Test-Change: <why>" trailer) or a pure addition of checks.'

ask() {
	jq -cn --arg r "$1 $REASON" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
	exit 0
}

tool="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$root"

abs() { # absolute or cwd-relative path -> absolute, ./ and ../ resolved (no disk access)
	local p="$1"
	case "$p" in /*) ;; *) p="$cwd/$p" ;; esac
	printf '%s' "$p" | awk -F/ '{ n = 0; for (i = 1; i <= NF; i++) { if ($i == "" || $i == ".") continue; if ($i == "..") { if (n) n--; continue } s[++n] = $i } o = ""; for (i = 1; i <= n; i++) o = o "/" s[i]; print o }'
}

rel() { # absolute path -> repo-relative ("" if outside); a worktree under
	# .claude/worktrees/<name>/ counts as the repo too
	local r
	case "$1" in "$root"/*) r="${1#"$root"/}" ;; *) return ;; esac
	case "$r" in .claude/worktrees/*/*) r="${r#.claude/worktrees/*/}" ;; esac
	printf '%s' "$r"
}

protected() { # absolute path -> its repo-relative name if it is an existing protected file
	local r
	r="$(rel "$1")"
	[ -n "$r" ] && [ -e "$1" ] && printf '%s' "$r" | grep -Eq "$PROTECTED" && printf '%s' "$r"
}

case "$tool" in
Edit|Write|MultiEdit|NotebookEdit)
	path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
	[ -n "$path" ] || exit 0
	r="$(protected "$(abs "$path")")"
	[ -n "$r" ] && ask "$tool on the existing test/guard file $r."
	;;
Bash)
	cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
	[ -n "$cmd" ] || exit 0
	# Only commands that can rewrite or remove files, naming a protected path.
	printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])(sed[[:space:]]+(-[a-zA-Z]*i|--in-place)|perl[[:space:]]+-[a-zA-Z]*i|rm|mv|truncate|tee|cp|git[[:space:]]+(rm|mv|checkout|restore))([[:space:]]|$)|>[[:space:]]*[^&[:space:]]' || exit 0
	for w in $(printf '%s' "$cmd" | tr -s ' \t;&|<>()"'"'"'' '\n'); do
		r="$(protected "$(abs "$w")")"
		[ -n "$r" ] && ask "This command may rewrite or delete the existing test/guard file $r."
	done
	;;
esac
exit 0
