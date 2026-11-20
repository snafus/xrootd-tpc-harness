#!/usr/bin/env bash
# Test a storage (for example a CephFS mount) as the destination of HTTP-TPC
# pulls, with the XRootD that is installed on this host.
#
#   storage-test.sh DESTINATION_DIRECTORY
#
# DESTINATION_DIRECTORY must be on the storage to test and writable by the
# user who runs this.  xrootd does not run as root: run this as an ordinary
# user, or as root with TPC_RUN_AS set to the user the servers are to run as
# (xrootd -R).  The destination files then belong to that user, and the
# directories the tests make below DESTINATION_DIRECTORY are given to it.  The tests make
# their own directories below it and remove them.  The largest file is 2 GiB
# unless TPC_RATE_SIZE says otherwise.
#
# Three parts, all against a destination server whose files are in that
# directory:
#   1. the correctness suites, without and with real-time checksums (run.sh full)
#   2. with the block-write test build only: the size matrix and the fault
#      suite with block writes on and real-time checksums on
#   3. the observations of storage.bats: space used during a copy, what a
#      failed copy and a killed server leave, and rates
#
# STORAGE_TEST_PARTS chooses the parts to run (default "1 2 3").
#
# The results are collected in one archive, named at the end.  Needed: xrootd
# (server and client packages), python3, curl, getfattr (package attr) and
# bats 1.11 or later, named by BATS if it is not on the PATH.
set -uo pipefail

DEST=${1:?usage: storage-test.sh DESTINATION_DIRECTORY}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
[[ -f "$HERE/local.env" ]] && source "$HERE/local.env"
# as run.sh does: an XRootD build tree, if one is named, comes first
[[ -n "${XROOTD_BUILD:-}" ]] && export PATH="$XROOTD_BUILD/bin:$PATH"
BATS=${BATS:-bats}
[[ -x "${XROOTD_SRC:-}/vendor/bats/bin/bats" ]] && BATS="$XROOTD_SRC/vendor/bats/bin/bats"

if [[ $(id -u) == 0 ]]; then
	# xrootd does not run as root; as root, the servers switch to another user
	[[ -n "${TPC_RUN_AS:-}" ]] ||
		{ echo "run this as an ordinary user, or as root with TPC_RUN_AS=USER (the user the servers run as)"; exit 2; }
	id "$TPC_RUN_AS" >/dev/null || exit 2
	runuser -u "$TPC_RUN_AS" -- test -x "$DEST" ||
		{ echo "user $TPC_RUN_AS cannot reach $DEST"; exit 2; }
	export TPC_RUN_AS
fi
[[ -d "$DEST" && -w "$DEST" ]] || { echo "not a writable directory: $DEST"; exit 2; }
for program in xrootd "$BATS" python3 curl getfattr; do
	command -v "$program" >/dev/null || { echo "not found: $program"; exit 2; }
done

OUT="$PWD/storage-results-$(hostname -s)-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
export TPC_DEST_DIR=$DEST BATS BATS_SKIP_SERVER_LOGS=1

block_build=0
bin=$(dirname "$(command -v xrootd)")
grep -qs XRD_TPC_EXP_BLOCK_MIB "$bin"/../lib64/libXrdHttpTPC-*.so "$bin"/../lib/libXrdHttpTPC-*.so && block_build=1

{
	echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "host: $(uname -srm)"
	echo "os: $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null)"
	echo "xrootd: $(xrootd -v 2>&1 | head -1)"
	echo "block-write build: $block_build"
	echo "destination: $DEST"
	echo "file system: $(stat -f -c '%T' "$DEST") $(findmnt -n -o SOURCE,FSTYPE,OPTIONS -T "$DEST" 2>/dev/null)"
	echo "space: $(df -h --output=size,avail "$DEST" | tail -1)"
	echo "user xattr: $(f=$(mktemp -p "$DEST") && setfattr -n user.test -v 1 "$f" 2>&1 && echo works; rm -f "$f")"
} >"$OUT/host.txt" 2>&1
cat "$OUT/host.txt"

PARTS=${STORAGE_TEST_PARTS:-1 2 3}
grep -vE '^(#|$)' "$HERE/known-failures.txt" | sort >"$OUT/known"

# block_pass BLOCK WRITE SUITE: one suite with block writes and real-time
# checksums on.  Failures listed in known-failures.txt are counted apart.
block_pass() {
	local block=$1 write=$2 suite=$3 tap="$OUT/block-$1-$2-${3%.bats}.tap"

	echo "-- $suite, block $block MiB, write $write MiB"
	(cd "$HERE" && XRD_TPC_EXP_BLOCK_MIB=$block XRD_TPC_EXP_WRITE_MIB=$write TPC_CHECKSUM=1 \
		TPC_SURVEY="${tap%.tap}.survey" "$BATS" --tap "$suite") >"$tap" 2>&1
	sed -nE 's/^not ok [0-9]+ //p' "$tap" | sort >"$OUT/failed"
	echo "   passed $(grep -c '^ok' "$tap"), known failures $(comm -12 "$OUT/failed" "$OUT/known" | wc -l), new failures $(comm -23 "$OUT/failed" "$OUT/known" | wc -l)"
	comm -23 "$OUT/failed" "$OUT/known" | sed 's/^/   NEW FAILURE: /'
}

if [[ " $PARTS " == *" 1 "* ]]; then
	echo
	echo "== 1. correctness suites (several minutes)"
	# with the server logs of every failed test, to explain a failure afterwards
	TPC_LOG_DIR="$OUT/suite-logs" BATS_SKIP_SERVER_LOGS="" "$HERE/run.sh" full 2>&1 | tee "$OUT/suite.txt"
fi

if [[ " $PARTS " == *" 2 "* && $block_build == 1 ]]; then
	echo
	echo "== 2. block writes with real-time checksums (several minutes)"
	# The largest file of the matrix is 1 GiB: four blocks of 256 MiB.
	block_pass 256 16 matrix.bats
	block_pass 256 4 matrix.bats
	block_pass auto 16 matrix.bats
	# The file of the fault suite is 80 MiB.  Its tests expect a file of
	# several ranges, hence the small block.
	block_pass 32 16 faults.bats
	block_pass 32 4 faults.bats
fi

if [[ " $PARTS " == *" 3 "* ]]; then
	echo
	echo "== 3. observations (several minutes)"
	(cd "$HERE" && TPC_REPORT="$OUT/storage-report.txt" "$BATS" --tap storage.bats) >"$OUT/storage.tap" 2>&1
	echo "passed $(grep -c '^ok' "$OUT/storage.tap"), failed $(grep -c '^not ok' "$OUT/storage.tap")"
	grep -v '^space' "$OUT/storage-report.txt" 2>/dev/null
fi

rm -f "$OUT/known" "$OUT/failed"
tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
echo
echo "Results to send back: $OUT.tar.gz"
