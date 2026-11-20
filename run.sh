#!/usr/bin/env bash
# Run the multi-stream TPC tests and compare the failures with the known ones.
#
#   run.sh quick   the fast functional tests (the default)
#   run.sh full    every functional test
#
# The tests use the xrootd found on the PATH.  Settings, from the environment
# or from the file local.env beside this script:
#
#   XROOTD_BUILD   an XRootD build tree: its programs are used, its TPC unit
#                  tests are run first and, in full mode, its own TPC tests last
#   XROOTD_SRC     an XRootD source tree, for the bats it carries in vendor/
#   BATS           the bats program to use (1.11 or later)
#   TPC_DEST_DIR   directory for the destination files, to test another
#                  storage (for example a CephFS mount)
#   TPC_LOG_DIR    directory in which to keep the output of every test, also
#                  when the run succeeds (default: a temporary directory,
#                  kept only when the run fails)
#   TPC_CHECKSUM   if set, the destination computes a checksum while it writes
#                  (ofs.cksrt) and every successful pull must have stored the
#                  right one.  The full run does this by itself for the matrix
#                  and the fault suites.
#
# In the development container: docker/dev.sh test [quick|full]
#
# Tests that fail today because of a known defect are listed in
# known-failures.txt.  The run succeeds when exactly those tests fail.  A new
# failure is an error, and so is a listed test that now passes: remove it
# from the list in the commit that fixes it.
set -uo pipefail

MODE=${1:-quick}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
[[ -f "$HERE/local.env" ]] && source "$HERE/local.env"
export XROOTD_BUILD=${XROOTD_BUILD:-} XROOTD_SRC=${XROOTD_SRC:-}
[[ -n "$XROOTD_BUILD" ]] && export PATH="$XROOTD_BUILD/bin:$PATH"
if [[ -z "${BATS:-}" ]]; then
	BATS=bats
	[[ -x "$XROOTD_SRC/vendor/bats/bin/bats" ]] && BATS="$XROOTD_SRC/vendor/bats/bin/bats"
fi
for program in xrootd "$BATS" python3 curl getfattr; do
	command -v "$program" >/dev/null || { echo "not found: $program"; exit 2; }
done
if [[ -n "${TPC_LOG_DIR:-}" ]]; then
	LOG=$TPC_LOG_DIR
	mkdir -p "$LOG"
else
	LOG=$(mktemp -d /tmp/tpc-tests.XXXXXX)
fi
SUITES=(matrix.bats faults.bats ordering.bats checksum.bats markers.bats setup-failure.bats)
CHECKSUM_SUITES=(matrix.bats faults.bats)
status=0
began=$SECONDS

case "$MODE" in
quick) filter=(--filter-tags '!slow') ;;
full) filter=() ;;
*) sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac

step() { printf '%-28s ' "$1"; }

# -- unit tests ---------------------------------------------------------------
units=(xrdhttptpc-unit-tests xrdhttptpc-stream-unit-tests)
[[ -n "$XROOTD_BUILD" ]] || { units=(); step "unit tests"; echo "skipped (XROOTD_BUILD is not set)"; }
for binary in "${units[@]}"; do
	step "$binary"
	if "$XROOTD_BUILD/bin/$binary" >"$LOG/$binary.log" 2>&1; then
		grep -E '^\[  PASSED  \]' "$LOG/$binary.log" | sed 's/^\[  PASSED  \] //'
	else
		echo "FAILED"
		grep -E '^\[  FAILED  \]' "$LOG/$binary.log" | sort -u
		status=1
	fi
done

# -- functional tests ---------------------------------------------------------
# functional LABEL TAG SUITE...: run the suites and compare the failures with
# the known ones.  The caller sets the environment of the tests.
functional() {
	local label=$1 tag=$2
	shift 2

	step "$label"
	(cd "$HERE" && "$BATS" --tap "${filter[@]}" "$@") >"$LOG/$tag.tap" 2>&1

	# Names of the tests that ran, and of those that failed.
	sed -nE 's/^(not )?ok [0-9]+ //p' "$LOG/$tag.tap" | sed -E 's/ # skip.*$//' | sort >"$LOG/ran"
	sed -nE 's/^not ok [0-9]+ //p' "$LOG/$tag.tap" | sort >"$LOG/failed"
	comm -12 "$LOG/known" "$LOG/ran" >"$LOG/expected"
	comm -23 "$LOG/failed" "$LOG/expected" >"$LOG/new"
	comm -13 "$LOG/failed" "$LOG/expected" >"$LOG/fixed"

	echo "$(wc -l <"$LOG/ran") run, $(wc -l <"$LOG/failed") failed, $(wc -l <"$LOG/expected") known failures"
	if [[ ! -s "$LOG/ran" ]]; then
		echo "  no test ran:"
		sed 's/^/    /' "$LOG/$tag.tap" | head -20
		status=1
	fi
	if [[ -s "$LOG/new" ]]; then
		echo "  NEW FAILURES:"
		sed 's/^/    /' "$LOG/new"
		status=1
	fi
	if [[ -s "$LOG/fixed" ]]; then
		echo "  NOW PASSING (remove from known-failures.txt):"
		sed 's/^/    /' "$LOG/fixed"
		status=1
	fi
}

grep -vE '^(#|$)' "$HERE/known-failures.txt" | sort >"$LOG/known"

functional "functional ($MODE)" bats "${SUITES[@]}"
if [[ "$MODE" == full && -n "$(comm -23 "$LOG/known" "$LOG/ran")" ]]; then
	echo "  LISTED IN known-failures.txt BUT NOT A TEST:"
	comm -23 "$LOG/known" "$LOG/ran" | sed 's/^/    /'
	status=1
fi

# The same pulls on a destination that computes a checksum while it writes:
# every pull that succeeds must also have stored the right checksum.
if [[ "$MODE" == full ]]; then
	TPC_CHECKSUM=1 functional "with real-time checksums" bats-cksrt "${CHECKSUM_SUITES[@]}"
fi

# -- upstream TPC tests -------------------------------------------------------
if [[ "$MODE" == full && -n "$XROOTD_BUILD" ]]; then
	step "upstream TPC tests"
	if ctest --test-dir "$XROOTD_BUILD" -R '[Tt]pc' >"$LOG/upstream.log" 2>&1; then
		grep -E 'tests passed' "$LOG/upstream.log"
	else
		echo "FAILED"
		grep -E '\*\*\*Failed|tests passed' "$LOG/upstream.log"
		status=1
	fi
fi

if [[ $status == 0 ]]; then
	echo "OK in $((SECONDS - began)) s"
	[[ -n "${TPC_LOG_DIR:-}" ]] || rm -rf "$LOG"
else
	echo "FAILED in $((SECONDS - began)) s; logs kept in $LOG"
fi
exit $status
