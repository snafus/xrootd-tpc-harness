#!/usr/bin/env bash

# What the storage under the destination does during and after a pull.
#
# These tests observe more than they assert: each one appends lines to the
# report file named by TPC_REPORT (default: storage-report.txt beside this
# file).  Run them with the destination on the storage of interest:
#
#   TPC_DEST_DIR=/cephfs/some/dir bats storage.bats
#
# or, with the correctness suites, through storage-test.sh.
#
# Every observation is made for the present model and, when the installed
# XRootD is the block-write test build, for block writes as well.  A mode is
# "present" or "block-BLOCK-WRITE", sizes in MiB (BLOCK may be "auto").
#
# Settings:
#   TPC_STORAGE_SIZE  size of the file used for the space, failure and kill
#                     observations, in bytes (default 1 GiB)
#   TPC_RATE_SIZE     size of the file used for the rate, in bytes (default 2 GiB)
#   TPC_BLOCK_BUILD   1 or 0 to say whether the build has block writes
#                     (default: found by looking into the TPC library)

load helper.bash

readonly REPORT=${TPC_REPORT:-$HARNESS_DIR/storage-report.txt}
readonly STORAGE_SIZE=${TPC_STORAGE_SIZE:-$((1024 * MIB))}
readonly RATE_SIZE=${TPC_RATE_SIZE:-$((2048 * MIB))}
readonly STREAMS=4
# per connection; four streams then take about 20 s for 1 GiB
readonly SLOW_RATE=$((STORAGE_SIZE / STREAMS / 20))

setup() {
	cd "$BATS_TEST_TMPDIR"
	launch_source
}

teardown() {
	stop_servers
}

has_block_writes() {
	local dir bin
	[[ -n "${TPC_BLOCK_BUILD:-}" ]] && { [[ "$TPC_BLOCK_BUILD" == 1 ]]; return; }
	bin=$(dirname "$(command -v xrootd)")
	for dir in "$bin/../lib64" "$bin/../lib"; do
		grep -qs XRD_TPC_EXP_BLOCK_MIB "$dir"/libXrdHttpTPC-*.so && return 0
	done
	return 1
}

# report KIND FIELD...: one tab-separated line in the report file
report() {
	local IFS=$'\t'
	printf '%s\n' "$*" >>"$REPORT"
}

# start_destination MODE [CONFIGURATION]
start_destination() {
	local mode=$1 config=${2:-dst-cksrt.cfg} block write

	rm -f "$BATS_TEST_TMPDIR/xrootd_dst.log"
	if [[ "$mode" == present ]]; then
		XRD_TPC_EXP_BLOCK_MIB="" launch_destination "$config"
	else
		IFS=- read -r _ block write <<<"$mode"
		XRD_TPC_EXP_BLOCK_MIB=$block XRD_TPC_EXP_WRITE_MIB=$write launch_destination "$config"
	fi
}

# The length of a destination file and the space the file system says it
# uses: "size=N allocated=N", or "absent".
file_facts() {
	local file
	file=$(dst_file "$1")
	[[ -e "$file" ]] || { echo absent; return; }
	stat -c '%s %b %B' "$file" | awk '{ printf "size=%d allocated=%d\n", $1, $2 * $3 }'
}

# What a client is told about a destination file: its length and its adler32.
served_facts() {
	local length
	length=$(curl --silent --head "${DST_URL}/$1" | tr -d '\r' | sed -n 's/^[Cc]ontent-[Ll]ength: *//p')
	echo "served_length=${length:-none} served_adler32=$(reported_adler32 "$1")"
}

stored_checksum_fact() {
	if has_stored_checksum "$1"; then echo stored_checksum=yes; else echo stored_checksum=no; fi
}

observe_space() { # MODE
	local mode=$1 began pull

	start_destination "$mode"
	tpc_pull "/f/${STORAGE_SIZE}/t?fault=slow&rate=${SLOW_RATE}" file_dst "$STREAMS" >pull.out 2>&1 &
	pull=$!
	began=$SECONDS
	while kill -0 "$pull" 2>/dev/null; do
		report space "$mode" "t=$((SECONDS - began))" "$(file_facts file_dst)"
		sleep 1
	done
	wait "$pull" || true
	report space "$mode" end "$(file_facts file_dst)" "$(stored_checksum_fact file_dst)" \
		"expected_size=$STORAGE_SIZE" "$(verdict "$(<pull.out)")"
	[[ "$(verdict "$(<pull.out)")" == success:* ]] || fail "the pull failed: $(verdict "$(<pull.out)")"
}

observe_failed_copy() { # MODE
	local mode=$1 body

	start_destination "$mode"
	body=$(tpc_pull "/f/${STORAGE_SIZE}/t?fault=drop&after=1000000&times=1&at=$((STORAGE_SIZE / 2))" \
		file_dst "$STREAMS" 2>&1) || true
	report failed_copy "$mode" "$(file_facts file_dst)" "$(stored_checksum_fact file_dst)" \
		"$(served_facts file_dst)" "expected_size=$STORAGE_SIZE" \
		"expected_adler32=$(expected_adler32 "$STORAGE_SIZE")" "$(verdict "$body")"
	[[ "$(verdict "$body")" == failure:* ]] || fail "the pull did not fail: $(verdict "$body")"
}

observe_killed_server() { # MODE
	local mode=$1 pull

	start_destination "$mode"
	tpc_pull "/f/${STORAGE_SIZE}/t?fault=slow&rate=${SLOW_RATE}" file_dst "$STREAMS" >pull.out 2>&1 &
	pull=$!
	sleep 8
	report killed_server "$mode" before_kill "$(file_facts file_dst)"
	kill -9 "$(awk '{ print }' "$BATS_TEST_TMPDIR/xrootd_dst.pid")"
	wait "$pull" || true
	sleep 1
	report killed_server "$mode" after_kill "$(file_facts file_dst)" "$(stored_checksum_fact file_dst)"

	# What the restarted server tells a client about the file that was left.
	start_destination "$mode"
	report killed_server "$mode" after_restart "$(file_facts file_dst)" "$(served_facts file_dst)" \
		"expected_size=$STORAGE_SIZE" "expected_adler32=$(expected_adler32 "$STORAGE_SIZE")"
}

observe_rate() { # MODE CONFIGURATION STREAMS
	local mode=$1 config=$2 streams=$3 began pulled synced body

	start_destination "$mode" "$config"
	began=$(date +%s.%N)
	body=$(TPC_MAX_TIME=1800 tpc_pull "/f/${RATE_SIZE}/t" file_dst "$streams" 2>&1) || true
	pulled=$(date +%s.%N)
	# the time the storage needs to hold everything that was written
	sync "$(dst_file file_dst)" 2>/dev/null || true
	synced=$(date +%s.%N)
	report rate "$mode" "config=$config" "streams=$streams" "bytes=$RATE_SIZE" \
		"$(awk -v b="$began" -v p="$pulled" -v s="$synced" -v n="$RATE_SIZE" \
			'BEGIN { printf "pull_s=%.1f sync_s=%.1f MB/s=%.0f MB/s_with_sync=%.0f", p - b, s - p, n / (p - b) / 1e6, n / (s - b) / 1e6 }')" \
		"$(file_facts file_dst)" "$(stored_checksum_fact file_dst)" "$(verdict "$body")"
	[[ "$(verdict "$body")" == success:* ]] || fail "the pull failed: $(verdict "$body")"
}

# The rate at which the test source itself can serve, as a ceiling for the
# rates above.
observe_source() {
	local began ended
	began=$(date +%s.%N)
	curl --silent --output /dev/null "${SRC_URL}/f/${RATE_SIZE}/t"
	ended=$(date +%s.%N)
	report source one_connection "bytes=$RATE_SIZE" \
		"$(awk -v b="$began" -v e="$ended" -v n="$RATE_SIZE" 'BEGIN { printf "MB/s=%.0f", n / (e - b) / 1e6 }')"
}

modes=(present)
rate_modes=(present)
if has_block_writes; then
	modes+=(block-256-16)
	rate_modes+=(block-256-16 block-256-4 block-auto-16)
fi

bats_test_function --description "the rate of the test source alone" -- observe_source
for mode in "${modes[@]}"; do
	bats_test_function --description "space used during a copy ($mode)" -- observe_space "$mode"
	bats_test_function --description "the file left by a failed copy ($mode)" -- observe_failed_copy "$mode"
	bats_test_function --description "the file left by a killed server ($mode)" -- observe_killed_server "$mode"
done
bats_test_function --description "rate, 1 stream, no checksum" -- observe_rate present dst.cfg 1
bats_test_function --description "rate, 1 stream, real-time checksum" -- observe_rate present dst-cksrt.cfg 1
for mode in "${rate_modes[@]}"; do
	bats_test_function --description "rate, $STREAMS streams, no checksum ($mode)" -- observe_rate "$mode" dst.cfg "$STREAMS"
	bats_test_function --description "rate, $STREAMS streams, real-time checksum ($mode)" -- observe_rate "$mode" dst-cksrt.cfg "$STREAMS"
done
