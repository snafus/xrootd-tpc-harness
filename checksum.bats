#!/usr/bin/env bash

# The checksum of a pulled file, computed by XRootD itself.
#
# XRootD 6 can compute a checksum while a file is written ("ofs.cksrt") and
# store it with the file at close.  These tests show that a pull uses it with
# no checksum code in the TPC handler, and that the checksum a client asks for
# afterwards exposes data the source corrupted.

load helper.bash

readonly SIZE=$((80 * MIB + 4321))

setup() {
	cd "$BATS_TEST_TMPDIR"
	launch_source
}

teardown() {
	stop_servers
}

pull() {
	pull_and_classify "/f/${SIZE}/t?${2:-fault=none}" file_dst "$SIZE" "$1"
}

@test "real-time checksum: stored at the end of a single-stream pull" {
	launch_destination dst-cksrt.cfg
	pull 1
	assert_pull_succeeded
	has_stored_checksum file_dst || fail "no checksum was stored with the file"
	[[ "$(reported_adler32 file_dst)" == "$(expected_adler32 "$SIZE")" ]]
}

@test "real-time checksum: stored at the end of a 4-stream pull" {
	launch_destination dst-cksrt.cfg
	pull 4
	assert_pull_succeeded
	has_stored_checksum file_dst || fail "no checksum was stored with the file"
	[[ "$(reported_adler32 file_dst)" == "$(expected_adler32 "$SIZE")" ]]
}

@test "without real-time checksums nothing is stored by the pull" {
	launch_destination dst.cfg
	pull 4
	assert_pull_succeeded
	! has_stored_checksum file_dst
}

# The TPC handler does not check the content it receives.  These two faults
# are reported as success today; the checksum is what exposes them.

@test "real-time checksum: one corrupted bit shows in the reported checksum" {
	launch_destination dst-cksrt.cfg
	pull 4 "fault=corrupt&at=$((20 * MIB))"
	has_stored_checksum file_dst || fail "no checksum was stored with the file"
	[[ -n "$(reported_adler32 file_dst)" ]] || fail "the destination reported no checksum"
	[[ "$(reported_adler32 file_dst)" != "$(expected_adler32 "$SIZE")" ]]
}

@test "real-time checksum: data of another offset shows in the reported checksum" {
	launch_destination dst-cksrt.cfg
	pull 4 "fault=shift&times=1&at=$((20 * MIB))"
	has_stored_checksum file_dst || fail "no checksum was stored with the file"
	[[ -n "$(reported_adler32 file_dst)" ]] || fail "the destination reported no checksum"
	[[ "$(reported_adler32 file_dst)" != "$(expected_adler32 "$SIZE")" ]]
}
