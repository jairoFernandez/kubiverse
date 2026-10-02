#!/usr/bin/env bash
# test-guard: existing tests and their baselines may only get stronger.
#
# Fails when a change WEAKENS existing test code, unless a commit in the
# range carries a trailer   Test-Change: <why the old test was wrong>
#
# Weakening is any of:
#   - a line removed or changed in an existing test file (bridge/**/*_test.go,
#     game/tests/*.gd); blank lines, comments and whitespace don't count
#   - a test function deleted (Go Test/Fuzz/Benchmark/Example, GDScript func)
#   - fewer assertions in total (Go: t.Error/Errorf/Fatal/Fatalf/Fail/FailNow
#     and check/assert/require/must/expect helpers called with t; GDScript:
#     check( and "fails +=")
#   - a t.Skip / SkipNow / Skipf added
#   - a baseline loosened: a key added to game/tests/i18n_missing_baseline.txt,
#     bridge/coverage-baseline.txt or game/tests/checks-baseline.txt lowered
#   - lines removed from the guards themselves (this script, the hooks,
#     tools/testlint, .claude/settings.json)
# Pure additions (new tests, new assertions, new test files) always pass.
#
# Usage:
#   scripts/test-guard.sh                 CI (GitHub Actions env) or, locally,
#                                         merge-base(origin/main|main)..HEAD
#   scripts/test-guard.sh BASE HEAD       an explicit range
#   scripts/test-guard.sh --staged MSGFILE  the index vs HEAD, trailer read
#                                         from the commit message (commit-msg hook)
#   scripts/test-guard.sh --worktree      uncommitted changes vs HEAD (no
#                                         trailer possible: report only)
# Exit: 0 ok (or justified), 1 weakened without a trailer, 2 usage/git error.
# Written for bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile.

set -u
export LC_ALL=C

TEST_SPECS=('bridge/*_test.go' 'game/tests/*.gd')
BASELINES=('game/tests/i18n_missing_baseline.txt' 'bridge/coverage-baseline.txt' 'game/tests/checks-baseline.txt')
GUARD_SPECS=('scripts/test-guard.sh' 'scripts/hooks/*' 'scripts/claude-hooks/*' 'tools/testlint/*.go' '.claude/settings.json')
ZERO=0000000000000000000000000000000000000000

die() { echo "test-guard: $*" >&2; exit 2; }
note() { echo "test-guard: $*"; }

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in a git repository"

mode=range base="" head="" msgfile=""
case "${1:-}" in
	--staged) mode=staged; msgfile="${2:-}"; head=HEAD; base=HEAD ;;
	--worktree) mode=worktree; head=HEAD; base=HEAD ;;
	-h|--help) sed -n '2,32p' "$0"; exit 0 ;;
	"") head="${2:-}" ;;   # "" HEAD: default base, explicit head
	*) base="$1"; head="${2:-HEAD}" ;;
esac

have() { git cat-file -e "$1^{commit}" 2>/dev/null; }

# The default branch to compare a new branch against.
default_base() {
	local ref
	for ref in "origin/${GITHUB_BASE_REF:-}" origin/main origin/master main master; do
		[ "$ref" = "origin/" ] && continue
		if have "$ref"; then echo "$ref"; return; fi
	done
}

if [ "$mode" = range ] && [ -z "$base" ]; then
	ev="${GITHUB_EVENT_NAME:-}"
	if [ "$ev" = pull_request ] || [ "$ev" = pull_request_target ]; then
		base="${TG_BASE:-}"; head="${TG_HEAD:-HEAD}"
		[ -n "$base" ] || base="$(default_base)"
	elif [ "$ev" = push ]; then
		base="${TG_BEFORE:-}"; head="${TG_AFTER:-${GITHUB_SHA:-HEAD}}"
		case "${GITHUB_REF:-}" in refs/tags/*) note "tag push: nothing to check"; exit 0 ;; esac
	else
		[ -n "$head" ] || head=HEAD
	fi
	# New branch (zero SHA), unknown SHA (force push of history we don't
	# have), or no event: the merge base with the default branch.
	if [ -z "$base" ] || [ "$base" = "$ZERO" ] || ! have "$base"; then
		[ -n "$base" ] && note "base ${base:0:12} unknown or zero: comparing with the default branch"
		base="$(default_base)"
	fi
	[ -n "$base" ] || { note "no base to compare with: skipped"; exit 0; }
fi

if [ "$mode" = range ]; then
	have "$head" || die "unknown head $head"
	have "$base" || die "unknown base $base"
	# Only what this range introduces: from the merge base (a PR's base
	# branch may have moved on; a force push may have rewritten history).
	mb="$(git merge-base "$base" "$head" 2>/dev/null)" || mb=""
	[ -n "$mb" ] || { note "no common history between $base and $head: skipped"; exit 0; }
	base="$mb"
	if [ "$(git rev-parse "$base")" = "$(git rev-parse "$head^{commit}")" ]; then
		note "empty range: nothing to check"; exit 0
	fi
	diff_args=("$base" "$head")
	range_desc="$(git rev-parse --short "$base")..$(git rev-parse --short "$head")"
elif [ "$mode" = staged ]; then
	diff_args=(--cached HEAD)
	range_desc="staged changes"
else
	diff_args=(HEAD)
	range_desc="uncommitted changes"
fi

# Nothing guarded touched: done (keeps hooks fast).
changed="$(git diff --name-only "${diff_args[@]}" -- "${TEST_SPECS[@]}" "${BASELINES[@]}" "${GUARD_SPECS[@]}" 2>/dev/null)"
if [ -z "$changed" ]; then
	note "no test, baseline or guard file changed in $range_desc"
	exit 0
fi

# --- file contents on each side -------------------------------------------
# side: "old" (base / HEAD) or "new" (head / index / worktree).
old_rev() { if [ "$mode" = range ]; then echo "$base"; else echo HEAD; fi; }

TEST_RE='^(bridge/.*_test\.go|game/tests/[^/]*\.gd)$'
KEEP_RE='^(bridge/.*_test\.go|bridge/coverage-baseline\.txt|game/tests/[^/]*\.(gd|txt))$'

# Each side's test files and baselines, extracted once into a temp dir (one
# git archive per commit: fast enough for hooks).
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-guard.XXXXXX")" || die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

materialize() { # side
	local side="$1" dir="$TMP/$1" rev="" p
	mkdir -p "$dir"
	if [ "$side" = old ]; then rev="$(old_rev)"; elif [ "$mode" = range ]; then rev="$head"; fi
	if [ -n "$rev" ]; then
		local paths=()
		for p in bridge game/tests; do
			git cat-file -e "$rev:$p" 2>/dev/null && paths+=("$p")
		done
		if [ ${#paths[@]} -gt 0 ]; then
			git archive --format=tar "$rev" -- "${paths[@]}" | tar -xf - -C "$dir"
		fi
	elif [ "$mode" = staged ]; then
		git ls-files -- bridge game/tests | grep -E "$KEEP_RE" | git checkout-index --stdin --prefix="$dir/"
	else
		git ls-files -co --exclude-standard -- bridge game/tests | grep -E "$KEEP_RE" | while read -r p; do
			[ -f "$p" ] && mkdir -p "$dir/$(dirname "$p")" && cp "$p" "$dir/$p"
		done
	fi
}
materialize old
materialize new

test_files() { # side -> the test files on that side
	(cd "$TMP/$1" && find bridge game/tests -type f 2>/dev/null) | grep -E "$TEST_RE" | sort
}

show() { # side path
	cat "$TMP/$1/$2" 2>/dev/null
}

GO_ASSERT='((^|[^A-Za-z0-9_])(t|tb|b|f|tt)\.(Error|Errorf|Fatal|Fatalf|Fail|FailNow)\(|(^|[^A-Za-z0-9_.])(check|assert|require|must|expect)[A-Za-z0-9_]*\((t|tb)[,)])'
GD_ASSERT='((^|[^A-Za-z0-9_.])check\(|fails[[:space:]]*\+=)'

# One awk per side over every test file (hooks run this: few processes).
count_asserts() { # side
	local files
	files="$(test_files "$1")"
	[ -n "$files" ] || { echo 0; return; }
	(cd "$TMP/$1" && printf '%s\n' "$files" | GO_RE="$GO_ASSERT" GD_RE="$GD_ASSERT" xargs awk '
		{ go_file = FILENAME ~ /\.go$/; re = go_file ? ENVIRON["GO_RE"] : ENVIRON["GD_RE"] }
		go_file && /^[ \t]*\/\// { next }
		!go_file && /^[ \t]*#/ { next }
		{ l = $0; while (match(l, re)) { n++; l = substr(l, RSTART + (RLENGTH > 0 ? RLENGTH : 1)) } }
		END { print n + 0 }')
}

test_funcs() { # side -> "dir/Name" (Go) and "file::name" (GDScript), sorted
	local files
	files="$(test_files "$1")"
	[ -n "$files" ] || return 0
	(cd "$TMP/$1" && printf '%s\n' "$files" | xargs awk '
		FILENAME ~ /\.go$/ && match($0, /^func (Test|Fuzz|Benchmark|Example)[A-Za-z0-9_]*\(/) {
			d = FILENAME; sub(/\/[^\/]*$/, "", d); print d "/" substr($0, 6, RLENGTH - 6) }
		FILENAME ~ /\.gd$/ && match($0, /^(static )?func [A-Za-z0-9_]+\(/) {
			s = substr($0, 1, RLENGTH - 1); sub(/^(static )?func /, "", s); print FILENAME "::" s }') | sort -u
}

baseline_num() { # side path -> first number in the file, or empty
	show "$1" "$2" | grep -Eo '[0-9]+(\.[0-9]+)?' | head -1
}

# --- the checks -------------------------------------------------------------
problems=""
add() { problems="${problems}$1"$'\n'; }

# 1. Removed or changed lines in existing test files (and in the guards).
removed="$(git diff -M -w --ignore-blank-lines -U0 --no-color "${diff_args[@]}" -- "${TEST_SPECS[@]}" "${GUARD_SPECS[@]}" | awk '
	/^--- / { f = ($2 == "/dev/null") ? "" : substr($2, 3); next }
	/^\+\+\+ / { next }
	/^-/ {
		l = substr($0, 2)
		t = l; gsub(/^[ \t]+|[ \t]+$/, "", t)
		if (t == "") next
		if (f ~ /\.go$/ && t ~ /^\/\//) next
		if (f ~ /\.(gd|sh)$/ && t ~ /^#/) next
		if (f ~ /(^|\/)commit-msg$|(^|\/)pre-push$/ && t ~ /^#/) next
		printf "    %s: %s\n", f, (length(t) > 110 ? substr(t, 1, 110) "..." : t)
	}')"
if [ -n "$removed" ]; then
	n=$(printf '%s\n' "$removed" | wc -l | tr -d ' ')
	add "- $n line(s) removed or changed in existing test/guard code:"
	add "$(printf '%s\n' "$removed" | head -40)"
	[ "$n" -gt 40 ] && add "    ... and $((n - 40)) more"
fi

# 2. Deleted test functions.
gone="$(comm -23 <(test_funcs old) <(test_funcs new))"
if [ -n "$gone" ]; then
	add "- test function(s) deleted (or renamed):"
	add "$(printf '%s\n' "$gone" | sed 's/^/    /')"
fi

# 3. Fewer assertions in total.
a_old=$(count_asserts old)
a_new=$(count_asserts new)
# Fail closed: a guard that can't count must not say OK.
case "$a_old$a_new" in ''|*[!0-9]*) die "could not count assertions (old '$a_old', new '$a_new')" ;; esac
if [ "$a_new" -lt "$a_old" ]; then
	add "- assertions went down: $a_old -> $a_new (Go t.Error*/t.Fatal*/t.Fail*/check helpers, GDScript check( / fails +=)"
fi

# 4. Skips added.
skips="$(git diff -U0 --no-color "${diff_args[@]}" -- "${TEST_SPECS[@]}" | grep -E '^\+[^+]' | grep -E '\.Skip(f|Now)?\(' | sed 's/^+[[:space:]]*/    /')"
if [ -n "$skips" ]; then
	add "- t.Skip added:"
	add "$skips"
fi

# 5. Baselines loosened.
i18n=game/tests/i18n_missing_baseline.txt
more_keys=""
if [ -n "$(show old "$i18n" | head -1)" ]; then   # a new baseline loosens nothing
	more_keys="$(comm -13 <(show old "$i18n" | grep -v '^#' | sort -u) <(show new "$i18n" | grep -v '^#' | sort -u) | grep -v '^[[:space:]]*$')"
fi
if [ -n "$more_keys" ]; then
	add "- $i18n allows more untranslated keys:"
	add "$(printf '%s\n' "$more_keys" | sed 's/^/    + /' | head -10)"
fi
for f in bridge/coverage-baseline.txt game/tests/checks-baseline.txt; do
	o=$(baseline_num old "$f"); n=$(baseline_num new "$f")
	if [ -n "$o" ] && { [ -z "$n" ] || awk -v o="$o" -v n="$n" 'BEGIN { exit !(n < o) }'; }; then
		add "- $f lowered: $o -> ${n:-(removed)}"
	fi
done

if [ -z "$problems" ]; then
	note "OK: $range_desc only adds to the tests (assertions $a_old -> $a_new)"
	exit 0
fi

# --- justified? ---------------------------------------------------------------
reasons=""
if [ "$mode" = range ]; then
	reasons="$(git log --format='%(trailers:key=Test-Change,valueonly,separator=%x0a)' "$base..$head" | grep -v '^[[:space:]]*$')"
elif [ "$mode" = staged ] && [ -n "$msgfile" ] && [ -f "$msgfile" ]; then
	reasons="$(grep -v '^#' "$msgfile" | git interpret-trailers --parse | sed -nE 's/^Test-Change:[[:space:]]*(.*[^[:space:]].*)$/\1/p')"
fi

echo
echo "test-guard: existing tests were weakened in $range_desc"
echo
printf '%s' "$problems"
echo
if [ -n "$reasons" ]; then
	echo "Justified by Test-Change:"
	printf '%s\n' "$reasons" | sed 's/^/    /'
	echo "test-guard: OK (justified)"
	exit 0
fi
cat <<'EOF'
Existing tests and baselines may only get stronger. If the change is right
and the OLD test was wrong (or the behavior really changed on purpose), say
why in a commit of this range with a trailer, last paragraph of the message:

    Test-Change: the old test expected X, but X was a bug (see #123)

Prefer a separate commit for the test change. Never weaken a test only to
make new code pass: fix the code. See CONTRIBUTING.md.
EOF
[ "$mode" = worktree ] && echo "(uncommitted changes: add the trailer when you commit)"
exit 1
