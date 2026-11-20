#!/usr/bin/env bash

# The block-write test build with one thread for each stream
# (XRD_TPC_EXP_THREADS): what happens to the threads when a pull ends, fails
# or loses its client, and many pulls at once.
#
# Skipped unless the XRootD in use is the block-write test build.
#
# TPC_FULL_DIR  a directory on a file system too small for the test file
#               (less than 256 MiB), for the test of storage that fills up.
#               In the development container:
#                 DOCKER_ARGS="--tmpfs /full:size=64m,mode=1777" TPC_FULL_DIR=/full

load helper.bash

readonly SIZE=$((400 * MIB + 4321))
readonly STREAMS=4

setup() {
	local bin
	bin=$(dirname "$(command -v xrootd)")
	grep -qs XRD_TPC_EXP_THREADS "$bin"/../lib64/libXrdHttpTPC-*.so "$bin"/../lib/libXrdHttpTPC-*.so ||
		skip "not the block-write test build with threads"
	cd "$BATS_TEST_TMPDIR"
	launch_source
}

teardown() {
	stop_servers
}

# start_destination [CONFIGURATION]: blocks of 32 MiB, so that the test file is
# 13 blocks, written 4 MiB at a time.
start_destination() {
	XRD_TPC_EXP_BLOCK_MIB=32 XRD_TPC_EXP_WRITE_MIB=4 XRD_TPC_EXP_THREADS=1 \
		launch_destination "${1:-dst-cksrt.cfg}"
}

destination_threads() {
	find "/proc/$(awk '{ print }' "$BATS_TEST_TMPDIR/xrootd_dst.pid")/task" -mindepth 1 -maxdepth 1 | wc -l
}

# wait_for_threads NUMBER SECONDS: until the destination has at most NUMBER threads
wait_for_threads() {
	local deadline=$((SECONDS + $2))
	while (($(destination_threads) > $1)); do
		((SECONDS < deadline)) || return 1
		sleep 0.5
	done
}

# The server makes threads of its own for the requests it serves; one quick
# pull first, so that the count taken afterwards is a fair baseline.
baseline_threads() {
	pull_and_classify "/f/$((8 * MIB))/warm" file_warm $((8 * MIB)) 1
	[[ "$outcome" == success ]] || fail "the first pull failed: $message"
	sleep 1
	destination_threads
}

@test "each stream is a thread during a pull, and the threads end with it" {
	local baseline during pull

	start_destination
	baseline=$(baseline_threads)

	tpc_pull "/f/${SIZE}/t?fault=slow&rate=$((8 * MIB))" file_dst "$STREAMS" >pull.out 2>&1 &
	pull=$!
	sleep 4
	during=$(destination_threads)
	wait "$pull" || true
	[[ "$(verdict "$(<pull.out)")" == success:* ]] || fail "the pull failed: $(verdict "$(<pull.out)")"
	[[ "$(verify_file file_dst "$SIZE")" == OK ]] || fail "the file is wrong"

	((during >= baseline + STREAMS)) || fail "$during threads during the pull, $baseline before"
	wait_for_threads "$baseline" 5 || fail "$(destination_threads) threads after the pull, $baseline before"
}

@test "a failure in one stream stops the others and gives the cause" {
	local baseline began

	start_destination
	baseline=$(baseline_threads)

	# The source is slow, so every stream is in the middle of a block when
	# the request for the range at 200 MiB is reset.
	began=$SECONDS
	pull_and_classify "/f/${SIZE}/t?fault=drop&after=1000000&at=$((200 * MIB))" file_dst "$SIZE" "$STREAMS"
	[[ "$outcome" == failure ]] || fail "the pull did not fail: $message"
	[[ "$message" == *"HTTP library failure"* ]] || fail "the verdict does not give the cause: $message"
	[[ "$message" != *"callback"* ]] || fail "the verdict blames the stop, not the cause: $message"
	((SECONDS - began < 15)) || fail "the pull took $((SECONDS - began)) s to fail"
	wait_for_threads "$baseline" 5 || fail "$(destination_threads) threads after the failure, $baseline before"
	assert_destination_alive
}

@test "a client that goes away stops the streams" {
	local baseline

	start_destination
	baseline=$(baseline_threads)

	# The client gives up after 3 s; the pull would take about 12 s.
	TPC_MAX_TIME=3 tpc_pull "/f/${SIZE}/t?fault=slow&rate=$((8 * MIB))" file_dst "$STREAMS" >pull.out 2>&1 || true
	(($(destination_threads) >= baseline + STREAMS)) || fail "the streams ended before the client left"

	# The destination notices when it next sends a marker, every 5 s.
	wait_for_threads "$baseline" 20 || fail "$(destination_threads) threads 20 s after the client left, $baseline before"
	assert_destination_alive

	# and the server still serves a pull afterwards
	pull_and_classify "/f/$((8 * MIB))/again" file_again $((8 * MIB)) "$STREAMS"
	assert_pull_succeeded
}

@test "eight pulls at once, each with its own threads" {
	local size=$((80 * MIB + 4321)) n pids=()

	start_destination
	for n in 1 2 3 4 5 6 7 8; do
		tpc_pull "/f/${size}/t$n" "file_$n" "$STREAMS" >"pull.$n" 2>&1 &
		pids+=($!)
	done
	wait "${pids[@]}" || true

	for n in 1 2 3 4 5 6 7 8; do
		[[ "$(verdict "$(<"pull.$n")")" == success:* ]] || fail "pull $n failed: $(verdict "$(<"pull.$n")")"
		[[ "$(verify_file "file_$n" "$size")" == OK ]] || fail "file $n is wrong"
		[[ "$(stored_checksum_state "file_$n" "$size")" == ok ]] || fail "the checksum of file $n is $(stored_checksum_state "file_$n" "$size")"
	done
	assert_destination_alive
}

# Every stream meets the same error at the same moment.
@test "storage that fills up fails the pull with the cause, once" {
	[[ -n "${TPC_FULL_DIR:-}" ]] || skip "TPC_FULL_DIR is not set"
	local size=$((256 * MIB)) baseline

	export TPC_DEST_DIR=$TPC_FULL_DIR
	start_destination dst.cfg
	baseline=$(baseline_threads)

	pull_and_classify "/f/${size}/t" file_dst "$size" "$STREAMS"
	[[ "$outcome" == failure ]] || fail "the pull did not fail: $message"
	[[ "$message" == *"local filesystem"* ]] || fail "the verdict does not name the storage: $message"
	wait_for_threads "$baseline" 5 || fail "$(destination_threads) threads after the failure, $baseline before"
	assert_destination_alive
}

# libcurl calls such a transfer a success: it must not count as a block.
@test "an answer that is neither a success nor an error fails the pull with its status" {
	start_destination
	pull_and_classify "/f/${SIZE}/t?fault=status&code=304&times=1&at=$((200 * MIB))" file_dst "$SIZE" "$STREAMS"
	[[ "$outcome" == failure ]] || fail "the pull did not fail: $message"
	[[ "$message" == *"status code 304"* ]] || fail "the verdict does not give the status: $message"
	assert_destination_alive
}
