#!/usr/bin/env bash

# What the destination writes in its log when a pull ends: the event and the
# HTTP status (tpc_status).  A pull that succeeds has the whole file and logs
# 200, with one stream or with several; a pull that fails logs the status the
# source failed with, or 0 when the failure had no HTTP status.

load helper.bash

readonly SIZE=$((48 * MIB + 12345))

setup() {
	cd "$BATS_TEST_TMPDIR"
	launch_source
	launch_destination
}

teardown() {
	stop_servers
}

# logged EVENT: the last line the destination logged for that event
logged() {
	grep "TPC_PullRequest: event=$1," "$BATS_TEST_TMPDIR/xrootd_dst.log" | tail -1
}

# assert_logged EVENT TEXT...: the line of that event has every TEXT
assert_logged() {
	local event=$1 line text
	shift

	line=$(logged "$event")
	[[ -n "$line" ]] || fail "the destination logged no $event"
	for text in "$@"; do
		[[ "$line" == *"$text"* ]] || fail "the $event line has no '$text': $line"
	done
}

@test "a single-stream pull that succeeds logs status 200" {
	pull_and_classify "/f/${SIZE}" file_dst "$SIZE" 1
	assert_pull_succeeded
	# The line names the number of streams only when there are several.
	assert_logged TRANSFER_SUCCESS "bytes_transferred=${SIZE}," "tpc_status=200"
}

@test "a multi-stream pull that succeeds logs status 200" {
	pull_and_classify "/f/${SIZE}" file_dst "$SIZE" 4
	assert_pull_succeeded
	assert_logged TRANSFER_SUCCESS "streams=4," "bytes_transferred=${SIZE}," "tpc_status=200"
}

@test "a multi-stream pull that fails on a status from the source logs that status" {
	pull_and_classify "/f/${SIZE}/t?fault=status&code=404&at=$((20 * MIB))" file_dst "$SIZE" 4
	assert_failed_because "status code 404"
	assert_logged MULTISTREAM_FAIL "streams=4," "tpc_status=404"
	[[ -z "$(logged TRANSFER_SUCCESS)" ]] || fail "the destination logged a success"
}

@test "a multi-stream pull that fails without a status from the source logs status 0" {
	pull_and_classify "/f/${SIZE}/t?fault=drop&after=1000000&at=$((20 * MIB))" file_dst "$SIZE" 4
	[[ "$outcome" == failure ]] || fail "the pull did not fail: $message"
	assert_logged MULTISTREAM_FAIL "streams=4," "tpc_status=0"
	[[ -z "$(logged TRANSFER_SUCCESS)" ]] || fail "the destination logged a success"
}
