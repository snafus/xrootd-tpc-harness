#!/usr/bin/env bash

# Helpers shared by the multi-stream pull tests.

load lib.bash

readonly HARNESS_DIR="$BATS_TEST_DIRNAME"
readonly SRC_PORT=${SRC_PORT:-8640}
readonly DST_PORT=${DST_PORT:-8641}
readonly SRC_URL="http://localhost:${SRC_PORT}"
readonly DST_URL="http://localhost:${DST_PORT}"
readonly MIB=$((1024 * 1024))

# Start the fault-injecting source and wait until it listens.
launch_source() {
	local out="$BATS_TEST_TMPDIR/source.out"

	python3 "$HARNESS_DIR/faulty_source.py" serve --port "$SRC_PORT" --bind 127.0.0.1 \
		>"$out" 2>&1 3>&- &
	echo $! >"$BATS_TEST_TMPDIR/source.pid"

	for _ in {1..100}; do
		grep -qs READY "$out" && return 0
		sleep 0.05
	done

	echo "the source failed to start" >&2
	cat "$out" >&2
	return 1
}

# The directory in which the destination keeps its files.  It is below the
# temporary directory of the test unless TPC_DEST_DIR names another storage,
# for example a CephFS mount.  Each test then has its own directory there,
# removed when the test ends.
dst_data_dir() {
	if [[ -n "${TPC_DEST_DIR:-}" ]]; then
		echo "$TPC_DEST_DIR/tpc-harness-${BATS_ROOT_PID:-$$}-${BATS_SUITE_TEST_NUMBER:-0}"
	else
		echo "$BATS_TEST_TMPDIR/xrootd_dst/data"
	fi
}

# launch_destination [CONFIGURATION]
#
# Without an argument the destination runs with dst.cfg, or with real-time
# checksums (dst-cksrt.cfg) when TPC_CHECKSUM is set.  Every pull that
# succeeds is then also required to have stored the right checksum.
launch_destination() {
	dst_config=${1:-dst.cfg}
	[[ $# -gt 0 || -z "${TPC_CHECKSUM:-}" ]] || dst_config=dst-cksrt.cfg
	mkdir -p "$BATS_TEST_TMPDIR/xrootd_dst" "$(dst_data_dir)"
	DATA=$(dst_data_dir) PORT=$DST_PORT launch_xrootd "$dst_config" xrootd_dst
}

# Whether the destination computes a checksum while it writes a file.
checksums_on() {
	[[ "${dst_config:-}" == dst-cksrt.cfg ]]
}

# stored_checksum_state NAME SIZE: ok, wrong or absent.
stored_checksum_state() {
	if ! has_stored_checksum "$1"; then
		echo absent
	elif [[ "$(reported_adler32 "$1")" == "$(expected_adler32 "$2")" ]]; then
		echo ok
	else
		echo wrong
	fi
}

# Stop the source and the destination and remove what the test stored outside
# its temporary directory.
stop_servers() {
	kill_pid_files
	[[ -z "${TPC_DEST_DIR:-}" ]] || rm -rf "$(dst_data_dir)"
}

# Whether XRootD has stored an adler32 with a destination file.
has_stored_checksum() {
	getfattr -n user.XrdCks.adler32 "$(dst_file "$1")" >/dev/null 2>&1
}

# The adler32 the destination reports for a file, asked for as a transfer
# client asks for it after a copy.
reported_adler32() {
	curl --silent --head -H "Want-Digest: adler32" "${DST_URL}/$1" |
		tr -d '\r' | sed -n 's/^[Dd]igest: *adler32=//p'
}

expected_adler32() {
	python3 "$HARNESS_DIR/faulty_source.py" adler32 "$1"
}

# tpc_pull SOURCE_PATH_AND_QUERY DESTINATION_NAME [STREAMS]
#
# Ask the destination to pull a file from the source and print the body of its
# response: the performance markers followed by the final status line.
tpc_pull() {
	local source=$1 name=$2 streams=${3:-}
	local -a headers=(-H "Source: ${SRC_URL}${source}")

	[[ -n "$streams" ]] && headers+=(-H "X-Number-Of-Streams: ${streams}")

	curl --silent --show-error --max-time "${TPC_MAX_TIME:-120}" \
		-X COPY "${headers[@]}" "${DST_URL}/${name}"
}

dst_file() {
	echo "$(dst_data_dir)/$1"
}

# Compare a destination file with what the source serves for that size.
verify_file() {
	python3 "$HARNESS_DIR/faulty_source.py" verify "$(dst_file "$1")" "$2"
}

# Number of GET requests and of connections the source has seen.
source_stats() {
	curl --silent "${SRC_URL}/_stats" | python3 -c '
import json, sys
log = [r for r in json.load(sys.stdin) if r["method"] == "GET" and r["path"].startswith(("/f/", "/r/"))]
print("gets=%d connections=%d" % (len(log), len({r["conn"] for r in log})))'
}

# File offsets of the ranges the source served, in the order in which their
# answers were complete.  One offset per line.
arrival_order() {
	curl --silent "${SRC_URL}/_stats" | python3 -c '
import json, re, sys
log = [r for r in json.load(sys.stdin) if r["method"] == "GET" and r["status"] == 206]
for r in sorted(log, key=lambda r: r["end"]):
    print(re.match(r"bytes=(\d+)-", r["range"]).group(1))'
}

# Number of ranges the source had been asked for when the answer to the first
# range of the file was complete: how far the other streams ran ahead of it.
ranges_ahead_of_first() {
	curl --silent "${SRC_URL}/_stats" | python3 -c '
import json, sys
log = [r for r in json.load(sys.stdin) if r["method"] == "GET" and r["status"] == 206]
first = next(r for r in log if r["range"].startswith("bytes=0-"))
print(sum(1 for r in log if r["start"] < first["end"]) - 1)'
}

# The last line of a pull response is its verdict.
verdict() {
	printf '%s\n' "$1" | awk 'NF { last = $0 } END { print last }'
}

# record OUTCOME DETAIL...: append one line to the survey file, if one is set.
record() {
	[[ -n "${TPC_SURVEY:-}" ]] || return 0
	printf '%s\t%s\t%s\n' "$BATS_TEST_DESCRIPTION" "$1" "${*:2}" >>"$TPC_SURVEY"
}

# pull_and_classify SOURCE NAME SIZE STREAMS
#
# Run a pull and set:
#   outcome  success | failure | no-verdict
#   content  ok | <description of the mismatch> | absent
#   message  the final line of the response
#   checksum ok | wrong | absent: the checksum stored with the file, after a
#            success on a destination with real-time checksums; off otherwise
# The result is also appended to the survey file.
pull_and_classify() {
	local source=$1 name=$2 size=$3 streams=$4 body began

	began=$SECONDS
	body=$(tpc_pull "$source" "$name" "$streams" 2>&1) || true
	message=$(verdict "$body")

	case "$message" in
	success:*) outcome=success ;;
	failure:*) outcome=failure ;;
	*) outcome=no-verdict ;;
	esac

	if [[ -f "$(dst_file "$name")" ]]; then
		content=$(verify_file "$name" "$size") || true
		[[ "$content" == OK ]] && content=ok
	else
		content=absent
	fi

	checksum=off
	if [[ "$outcome" == success ]] && checksums_on; then
		checksum=$(stored_checksum_state "$name" "$size")
	fi

	record "$outcome" "content=$content" "checksum=$checksum" "seconds=$((SECONDS - began))" "$(source_stats)" "| $message"
}

# The one property every pull must have, whatever the source does: it ends
# with a verdict, and it never calls a wrong file a success.
assert_safe() {
	if [[ "$outcome" == no-verdict ]]; then
		fail "the pull ended without a verdict: '$message'"
	fi
	if [[ "$outcome" == success && "$content" != ok ]]; then
		fail "the pull reported success for a wrong file: $content"
	fi
	if [[ "$outcome" == success ]] && checksums_on && [[ "$checksum" != ok ]]; then
		fail "the pull succeeded but the checksum stored with the file is $checksum"
	fi
}

# assert_failed_because TEXT: the pull failed and its verdict gives the reason.
assert_failed_because() {
	assert_safe
	[[ "$outcome" == failure ]] || fail "the pull did not fail: $message"
	[[ "$message" == *"$1"* ]] || fail "the verdict does not say '$1': $message"
}

assert_pull_succeeded() {
	assert_safe
	[[ "$outcome" == success ]] || fail "the pull failed: $message"
}

# The destination must survive whatever the source did to it.
assert_destination_alive() {
	run -0 curl --silent --output /dev/null --write-out '%{http_code}' "${DST_URL}/"
}
