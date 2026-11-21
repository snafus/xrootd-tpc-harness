#!/usr/bin/env bash

# The status that ends the source's answer to a GET.  Three carry what was
# asked for: 200 with the file, 203 with the file as a proxy has passed it on,
# 206 with a range of it.  A request may also end
# normally, with no error from the source or from the HTTP library, on a status
# that brings no file: 204, 304, or a redirect that cannot be followed.  Such a
# pull has failed, with one stream and with several, and must say so with the
# status.
#
# The single-stream pull is the ordinary way of copying a file, so its tests
# come first, with the cases that must keep working.

load helper.bash

readonly SIZE=$((40 * MIB + 4321))
readonly STREAMS=4

setup() {
	cd "$BATS_TEST_TMPDIR"
	launch_source
	launch_destination
}

teardown() {
	stop_servers
}

# The last TRANSFER_FAIL or MULTISTREAM_FAIL line of the destination.
logged_failure() {
	grep -E "TPC_PullRequest: event=(TRANSFER|MULTISTREAM)_FAIL," "$BATS_TEST_TMPDIR/xrootd_dst.log" | tail -1
}

# Nothing of the source's answer may have been stored as the file.
assert_nothing_stored() {
	[[ ! -s "$(dst_file "$1")" ]] ||
		fail "the destination file has $(stat -c %s "$(dst_file "$1")") bytes"
}

# -- one stream: what must keep working ------------------------------------

@test "one stream: a 200 answer with the file succeeds" {
	pull_and_classify "/f/${SIZE}" file_dst "$SIZE" 1
	assert_pull_succeeded
}

@test "one stream: an empty file succeeds" {
	pull_and_classify "/f/0" file_dst 0 1
	assert_pull_succeeded
}

@test "one stream: a redirect that is followed to a 200 answer succeeds" {
	pull_and_classify "/r/${SRC_PORT}/f/${SIZE}" file_dst "$SIZE" 1
	assert_pull_succeeded
}

@test "one stream: a 203 answer with the file succeeds" {
	# 203 is a 200 that a proxy has passed on; it carries the file.
	pull_and_classify "/f/${SIZE}/t?fault=proxied" file_dst "$SIZE" 1
	assert_pull_succeeded
	grep -q "event=TRANSFER_SUCCESS,.*tpc_status=203" "$BATS_TEST_TMPDIR/xrootd_dst.log" ||
		fail "the source did not answer 203"
}

@test "one stream: an error status still fails with that status" {
	pull_and_classify "/f/${SIZE}/t?fault=status&code=503" file_dst "$SIZE" 1
	assert_failed_because "status code 503"
	assert_nothing_stored file_dst
}

# -- one stream: a status that brings no file -------------------------------

one_stream_fails_on() {
	local code=$1

	pull_and_classify "/f/${SIZE}/t?fault=status&code=${code}" file_dst "$SIZE" 1
	assert_failed_because "status code ${code}"
	assert_nothing_stored file_dst
	[[ "$(logged_failure)" == *"tpc_status=${code}"* ]] ||
		fail "the log does not give the status: $(logged_failure)"
	assert_destination_alive
}

# 204 and 304 have no content.  300 and 305 are not followed by the HTTP
# library, and neither is a 302 without a Location; the test source sends a
# short text with them, which must not end up in the file.
for code in 204 304 300 302 305; do
	bats_test_function --description "one stream: the pull fails when the source answers ${code}" \
		-- one_stream_fails_on "$code"
done

# -- several streams ---------------------------------------------------------

several_streams_fail_on() {
	local code=$1

	pull_and_classify "/f/${SIZE}/t?fault=status&code=${code}&times=1&at=$((20 * MIB))" file_dst "$SIZE" "$STREAMS"
	assert_failed_because "status code ${code}"
	[[ "$(logged_failure)" == *"tpc_status=${code}"* ]] ||
		fail "the log does not give the status: $(logged_failure)"
	assert_destination_alive
}

for code in 304 300 302 305; do
	bats_test_function --description "${STREAMS} streams: the pull fails when the source answers ${code} for one range" \
		-- several_streams_fail_on "$code"
done

@test "4 streams: the pull fails when the source answers 204 for one range" {
	# Caught earlier, as an answer that is not the range asked for.
	pull_and_classify "/f/${SIZE}/t?fault=status&code=204&times=1&at=$((20 * MIB))" file_dst "$SIZE" "$STREAMS"
	assert_failed_because "did not return the requested range"
	assert_destination_alive
}
