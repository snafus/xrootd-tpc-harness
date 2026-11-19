#!/usr/bin/env bash

# What a multi-stream pull does when the source misbehaves.
#
# Every test checks the property that must hold today: the pull ends with a
# verdict, never calls a wrong file a success, and leaves the destination
# running.  Tests named "survives ..." also expect the pull to succeed; that
# needs the per-range retry which is not written yet.

load helper.bash

readonly SIZE=$((80 * MIB + 4321))
readonly STREAMS=4

setup() {
	cd "$BATS_TEST_TMPDIR"
	launch_source
	launch_destination
}

teardown() {
	stop_servers
}

pull_with_fault() {
	pull_and_classify "/f/${SIZE}/t?$1" file_dst "$SIZE" "$STREAMS"
}

@test "no fault: the reference pull succeeds" {
	pull_with_fault "fault=none"
	assert_pull_succeeded
}

# -- a source that answers the wrong thing -------------------------------

@test "safe when the source ignores Range and sends the whole file" {
	pull_with_fault "fault=norange"
	assert_safe
	assert_destination_alive
}

@test "safe when the source ignores Range once" {
	pull_with_fault "fault=norange&times=1&at=$((20 * MIB))"
	assert_safe
	assert_destination_alive
}

@test "safe when the source answers with another range than asked" {
	pull_with_fault "fault=wrongrange&times=1&at=$((20 * MIB))"
	assert_safe
	assert_destination_alive
}

@test "safe when the source answers with a shorter range than asked" {
	pull_with_fault "fault=short&by=1000&times=1&at=$((20 * MIB))"
	assert_safe
	assert_destination_alive
}

@test "safe when the last range is short because the source file shrank" {
	pull_with_fault "fault=shrink&by=1000"
	assert_safe
	assert_destination_alive
}

@test "safe when the source sends the data of another offset" {
	pull_with_fault "fault=shift&times=1&at=$((20 * MIB))"
	assert_safe
	assert_destination_alive
}

@test "safe when one bit of the data is corrupted" {
	pull_with_fault "fault=corrupt&at=$((20 * MIB))"
	assert_safe
	assert_destination_alive
}

@test "safe when the source does not announce the file size" {
	pull_with_fault "fault=noclen"
	assert_safe
	assert_destination_alive
}

# -- a source that fails for a moment -------------------------------------

@test "survives one connection reset in the middle of a range" {
	pull_with_fault "fault=drop&after=1000000&times=1&at=$((20 * MIB))"
	assert_safe
	assert_destination_alive
	assert_pull_succeeded
}

@test "survives one connection closed in the middle of a range" {
	pull_with_fault "fault=drop&rst=0&after=1000000&times=1&at=$((20 * MIB))"
	assert_safe
	assert_destination_alive
	assert_pull_succeeded
}

@test "survives one 503 answer" {
	pull_with_fault "fault=status&code=503&times=1&at=$((20 * MIB))"
	assert_safe
	assert_destination_alive
	assert_pull_succeeded
}

# bats test_tags=slow
@test "survives one stalled range" {
	TPC_MAX_TIME=90 pull_with_fault "fault=stall&after=1000000&secs=60&times=1&at=$((20 * MIB))"
	assert_safe
	assert_destination_alive
	assert_pull_succeeded
}

@test "survives a source that closes the connection after every answer" {
	pull_with_fault "fault=close"
	assert_safe
	assert_destination_alive
	assert_pull_succeeded
}

@test "survives a source reached through a redirect" {
	pull_and_classify "/r/${SRC_PORT}/f/${SIZE}" file_dst "$SIZE" "$STREAMS"
	assert_safe
	assert_destination_alive
	assert_pull_succeeded
}

# -- a source that fails for good ------------------------------------------

@test "fails cleanly when the source always answers 503" {
	pull_with_fault "fault=status&code=503"
	assert_safe
	assert_destination_alive
	[[ "$outcome" == failure ]]
}

@test "fails cleanly when the source answers 404 for one range" {
	pull_with_fault "fault=status&code=404&times=1&at=$((20 * MIB))"
	assert_safe
	assert_destination_alive
	[[ "$outcome" == failure ]]
}
