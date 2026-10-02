#!/usr/bin/env bash
# Static checks of the headless Godot tests (game/tests/test_*.gd).
#   scripts/game-tests.sh check   every test file extends the harness, calls
#                                 check( at least $MIN_CHECKS times and finish(;
#                                 the total of check( calls may not go below
#                                 game/tests/checks-baseline.txt
#   scripts/game-tests.sh bump    raise the baseline to the current total
# Lowering the baseline by hand is a test change: the test guard asks for a
# Test-Change: trailer.
set -eu
cd "$(dirname "$0")/.."
BASELINE=game/tests/checks-baseline.txt
MIN_CHECKS=${MIN_CHECKS:-5}

count() { grep -Ev '^[[:space:]]*#' "$1" | grep -Eo '(^|[^A-Za-z0-9_.])check\(' | wc -l | tr -d ' '; }

total=0 bad=0
for f in game/tests/test_*.gd; do
	n=$(count "$f")
	total=$((total + n))
	if ! grep -q '^extends "res://tests/harness.gd"' "$f"; then
		echo "game-tests: $f must extend \"res://tests/harness.gd\" (check/finish/watchdog)"; bad=1
	fi
	if ! grep -q "godot_test,[0-9]*,res://tests/$(basename "$f"),ok)" Makefile; then
		echo "game-tests: $f is not run by 'make test-game' (add it to the Makefile)"; bad=1
	fi
	if [ "$n" -lt "$MIN_CHECKS" ]; then
		echo "game-tests: $f has $n check( calls, needs at least $MIN_CHECKS"; bad=1
	fi
	if ! grep -Ev '^[[:space:]]*#' "$f" | grep -Eq '(^|[^A-Za-z0-9_.])finish\('; then
		echo "game-tests: $f never calls finish( (its result would not be reported)"; bad=1
	fi
	if grep -Ev '^[[:space:]]*#' "$f" | grep -Eq '(^|[^A-Za-z0-9_.])assert\('; then
		echo "game-tests: $f uses assert(: it hangs headless Godot, use check("; bad=1
	fi
done
base=$(grep -Eo '[0-9]+' "$BASELINE" | head -1)

case "${1:-check}" in
check)
	if [ "$total" -lt "$base" ]; then
		echo "game-tests: FAIL $total check( calls, the baseline is $base."
		echo "  Checks were removed. If that is right, lower $BASELINE in a commit"
		echo "  with a 'Test-Change: <why>' trailer."
		bad=1
	elif [ "$total" -gt "$base" ]; then
		echo "game-tests: $total check( calls (baseline $base): run 'make coverage-bump' to lock them in"
	else
		echo "game-tests: $total check( calls (baseline $base) OK"
	fi
	exit $bad
	;;
bump)
	[ "$bad" = 0 ] || exit 1
	if [ "$total" -gt "$base" ]; then
		echo "$total" > "$BASELINE"
		echo "game-tests: baseline $base -> $total check( calls"
	else
		echo "game-tests: $total check( calls, baseline $base: unchanged"
	fi
	;;
*) echo "usage: $0 check|bump" >&2; exit 2 ;;
esac
