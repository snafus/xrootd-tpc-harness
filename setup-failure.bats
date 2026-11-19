#!/usr/bin/env bash

# What the destination answers when it cannot prepare a multi-stream pull.
#
# The failure is made with a small library placed in front of libcurl in the
# destination server (shims/no_duphandle.c), so these tests need a C compiler.

load helper.bash

readonly SIZE=$((40 * MIB + 4321))

setup() {
	command -v cc >/dev/null || skip "no C compiler to build the shim"
	cd "$BATS_TEST_TMPDIR"
	cc -shared -fPIC -o no_duphandle.so "$HARNESS_DIR/shims/no_duphandle.c"
	launch_source
	LD_PRELOAD="$BATS_TEST_TMPDIR/no_duphandle.so" launch_destination
}

teardown() {
	stop_servers
}

@test "a pull that cannot copy its request handle is answered with a complete error response" {
	local status

	status=$(curl --silent --show-error --max-time 30 --output answer \
		--write-out '%{http_code}' -X COPY -H "Source: ${SRC_URL}/f/${SIZE}/t" \
		-H "X-Number-Of-Streams: 4" "${DST_URL}/file_dst") ||
		fail "the answer is not a valid HTTP response (curl exit $?)"

	[[ "$status" == 500 ]] || fail "status $status, expected 500: $(<answer)"
	grep -q "Failed to duplicate existing curl handle" answer ||
		fail "the answer does not give the reason: $(<answer)"
	assert_destination_alive
}

@test "a single-stream pull needs no copy of the handle and succeeds" {
	pull_and_classify "/f/${SIZE}/t" file_dst "$SIZE" 1
	assert_pull_succeeded
}
