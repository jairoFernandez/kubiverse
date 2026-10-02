#!/usr/bin/env bash
# Coverage ratchet for the bridge.
#   scripts/coverage.sh check PROFILE   fail if the total is more than
#                                       $SLACK points below the baseline
#   scripts/coverage.sh bump PROFILE    raise the baseline (never lowers it)
# The baseline is bridge/coverage-baseline.txt (one number, percent). Lowering
# it by hand is a test change: the test guard asks for a Test-Change: trailer.
set -eu
cd "$(dirname "$0")/.."
BASELINE=bridge/coverage-baseline.txt
SLACK=${SLACK:-0.2}
cmd="${1:-}"; profile="${2:-bridge/bin/coverage.out}"
[ -f "$profile" ] || { echo "coverage: no profile at $profile (run make test-race)" >&2; exit 2; }
total=$(cd bridge && go tool cover -func="${profile#bridge/}" | awk '$1 == "total:" { sub("%", "", $NF); print $NF }')
[ -n "$total" ] || { echo "coverage: no total in $profile" >&2; exit 2; }
base=$(grep -Eo '[0-9]+(\.[0-9]+)?' "$BASELINE" | head -1)

case "$cmd" in
check)
	if awk -v t="$total" -v b="$base" -v s="$SLACK" 'BEGIN { exit !(t < b - s) }'; then
		echo "coverage: FAIL total $total% is below the baseline $base% (slack $SLACK)."
		echo "  New code needs tests. If coverage dropped for a good reason (dead code"
		echo "  removed with its tests), lower $BASELINE in a commit with a"
		echo "  'Test-Change: <why>' trailer."
		exit 1
	fi
	if awk -v t="$total" -v b="$base" 'BEGIN { exit !(t >= b + 0.1) }'; then
		echo "coverage: $total% (baseline $base%): run 'make coverage-bump' to lock it in"
	else
		echo "coverage: $total% (baseline $base%) OK"
	fi
	;;
bump)
	if awk -v t="$total" -v b="$base" 'BEGIN { exit !(t > b) }'; then
		echo "$total" > "$BASELINE"
		echo "coverage: baseline $base% -> $total%"
	else
		echo "coverage: $total% is not above the baseline $base%: unchanged"
	fi
	;;
*) echo "usage: $0 check|bump [profile]" >&2; exit 2 ;;
esac
