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

# Bytes the destination server has read so far, from files and sockets alike.
destination_bytes_read() {
	awk '$1 == "rchar:" { print $2 }' "/proc/$(awk '{ print }' "$BATS_TEST_TMPDIR/xrootd_dst.pid")/io"
}

# The adler32 of a destination file as it is now, computed here.
adler32_of_file() {
	python3 -c '
import sys, zlib
value = 1
with open(sys.argv[1], "rb") as f:
    for block in iter(lambda: f.read(1 << 20), b""):
        value = zlib.adler32(block, value)
print("%08x" % value)' "$(dst_file "$1")"
}

# A client asks for the checksum with a HEAD request and Want-Digest.  The
# answer must come from the value stored at the end of the pull, not from
# reading the file again.
@test "real-time checksum: a query is answered from the stored value, without reading the file" {
	local before after

	launch_destination dst-cksrt.cfg
	pull 4
	assert_pull_succeeded
	has_stored_checksum file_dst || fail "no checksum was stored with the file"

	before=$(destination_bytes_read)
	[[ "$(reported_adler32 file_dst)" == "$(expected_adler32 "$SIZE")" ]] ||
		fail "the reported checksum is wrong: $(reported_adler32 file_dst)"
	after=$(destination_bytes_read)
	((after - before < MIB)) ||
		fail "the server read $((after - before)) bytes to answer; the file is $SIZE bytes"
}

# The same, shown another way: the file is changed behind the back of the
# server and its modification time put back.  The server still reports the
# stored value, which no longer matches the content.  Once the modification
# time differs from the one stored with the checksum, the server computes the
# checksum again.
@test "real-time checksum: the stored value is used until the modification time changes" {
	local stored before after

	launch_destination dst-cksrt.cfg
	pull 4
	assert_pull_succeeded
	stored=$(expected_adler32 "$SIZE")

	touch -r "$(dst_file file_dst)" saved-times
	printf 'XYZ' | dd of="$(dst_file file_dst)" bs=1 seek=12345 conv=notrunc status=none
	touch -r saved-times "$(dst_file file_dst)"
	[[ "$(adler32_of_file file_dst)" != "$stored" ]] || fail "the file was not changed"
	[[ "$(reported_adler32 file_dst)" == "$stored" ]] ||
		fail "the server did not report the stored value: $(reported_adler32 file_dst)"

	touch "$(dst_file file_dst)"
	before=$(destination_bytes_read)
	[[ "$(reported_adler32 file_dst)" == "$(adler32_of_file file_dst)" ]] ||
		fail "after a change of modification time the server reports $(reported_adler32 file_dst)"
	after=$(destination_bytes_read)
	((after - before >= SIZE)) ||
		fail "the server read only $((after - before)) bytes to compute the checksum again"
}

# Without real-time checksums the first query makes the server read the whole
# file; it then stores the result, and the second query is answered from it.
@test "without real-time checksums the first query reads the file and the second does not" {
	local start first second

	launch_destination dst-cks.cfg
	pull 4
	assert_pull_succeeded
	! has_stored_checksum file_dst || fail "a checksum is stored before any query"

	start=$(destination_bytes_read)
	[[ "$(reported_adler32 file_dst)" == "$(expected_adler32 "$SIZE")" ]]
	first=$(destination_bytes_read)
	[[ "$(reported_adler32 file_dst)" == "$(expected_adler32 "$SIZE")" ]]
	second=$(destination_bytes_read)

	((first - start >= SIZE)) || fail "the first query read only $((first - start)) bytes"
	((second - first < MIB)) || fail "the second query read $((second - first)) bytes"
	has_stored_checksum file_dst || fail "the computed checksum was not stored"
}

# xrootd.chksum can name an external program.  The real-time checksum is
# still computed and stored, but the server then gives every query to the
# program and never looks at the stored value itself: the program has to.
@test "with an external checksum program the checksum is stored but every query runs the program" {
	cat >checksum-program.sh <<'PROGRAM'
#!/bin/bash
echo "$*" >>"$(dirname "$0")/checksum-program.log"
echo deadbeef
PROGRAM
	chmod +x checksum-program.sh

	PROG="$BATS_TEST_TMPDIR/checksum-program.sh" launch_destination dst-cksrt-prog.cfg
	pull 4
	[[ "$outcome" == success && "$content" == ok ]] || fail "the pull failed: $message"
	has_stored_checksum file_dst || fail "no checksum was stored with the file"
	[[ ! -e checksum-program.log ]] || fail "the program was run during the pull"

	[[ "$(reported_adler32 file_dst)" == deadbeef ]] || fail "the answer is not the program's"
	[[ "$(reported_adler32 file_dst)" == deadbeef ]] || fail "the answer is not the program's"
	(($(wc -l <checksum-program.log) == 2)) || fail "the program ran $(wc -l <checksum-program.log) times for 2 queries"
	[[ "$(head -1 checksum-program.log)" == /file_dst ]] || fail "unexpected arguments: $(head -1 checksum-program.log)"
}
