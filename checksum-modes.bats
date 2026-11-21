#!/usr/bin/env bash

# The checksum that the destination computes while it writes (ofs.cksrt), for
# whichever way of pulling the environment selects: the present model, block
# writes (XRD_TPC_EXP_BLOCK_MIB), or block writes with one thread for each
# stream (XRD_TPC_EXP_THREADS, XRD_TPC_EXP_WRITE_LOCK).
#
# After each pull, and before anything asks the server for a checksum:
#   - the checksum is stored with the file (extended attribute);
#   - the stored value is the adler32 of what the source served;
#   - it is also the adler32 of the bytes now in the destination file;
#   - the server did not give up on the checksum part way.
# Then the value the server reports to a client is checked as well.

load helper.bash

setup() {
	cd "$BATS_TEST_TMPDIR"
	launch_source
	launch_destination dst-cksrt.cfg
}

teardown() {
	stop_servers
}

# The value in the stored checksum record of a file, as hexadecimal digits.
# The record is XrdCksData: name (16 bytes), times and reserved (15 bytes),
# length of the value (1 byte), value.
stored_adler32() {
	getfattr --only-values -n user.XrdCks.adler32 "$(dst_file "$1")" 2>/dev/null | python3 -c '
import sys
record = sys.stdin.buffer.read()
name = record[:16].rstrip(b"\0").decode()
if name != "adler32":
    sys.exit("the record is for \"%s\"" % name)
print(record[32:32 + record[31]].hex())'
}

# The adler32 of the bytes in a destination file, computed here.
file_adler32() {
	python3 -c '
import sys, zlib
value = 1
with open(sys.argv[1], "rb") as f:
    for block in iter(lambda: f.read(1 << 20), b""):
        value = zlib.adler32(block, value)
print("%08x" % value)' "$(dst_file "$1")"
}

# The log must show that the pull ran the way the environment asked for.
assert_mode() {
	local streams=$1 log="$BATS_TEST_TMPDIR/xrootd_dst.log"

	((streams > 1)) || return 0
	if [[ "${XRD_TPC_EXP_THREADS:-0}" == 1 && -n "${XRD_TPC_EXP_BLOCK_MIB:-}" ]]; then
		grep -q "EXPERIMENT block writes.* threads=" "$log" || fail "the pull did not use threads"
		grep -q "write_lock=${XRD_TPC_EXP_WRITE_LOCK:-1}" "$log" || fail "the write lock is not as asked"
	elif [[ -n "${XRD_TPC_EXP_BLOCK_MIB:-}" && "${XRD_TPC_EXP_BLOCK_MIB}" != 0 ]]; then
		grep -q "EXPERIMENT block writes" "$log" || fail "the pull did not use block writes"
	else
		! grep -q "EXPERIMENT block writes" "$log" || fail "the pull used block writes"
	fi
}

# checksum_after_pull SIZE STREAMS
checksum_after_pull() {
	local size=$1 streams=$2 name="file_$1_$2" expected stored

	pull_and_classify "/f/${size}/${name}" "$name" "$size" "$streams"
	[[ "$outcome" == success ]] || fail "size $size: the pull failed: $message"
	[[ "$content" == ok ]] || fail "size $size: the file is wrong: $content"
	assert_mode "$streams"

	# pull_and_classify looked for the record before it asked the server.
	[[ "$checksum" != absent ]] || fail "size $size: no checksum was stored with the file"

	expected=$(expected_adler32 "$size")
	stored=$(stored_adler32 "$name")
	[[ "$stored" == "$expected" ]] || fail "size $size: stored $stored, the source has $expected"
	[[ "$(file_adler32 "$name")" == "$expected" ]] || fail "size $size: the bytes in the file do not give $expected"
	[[ "$checksum" == ok ]] || fail "size $size: the server reports a checksum that is $checksum"

	! grep -E "checksum was not set|nable to continue real-time|continue streaming checksum" \
		"$BATS_TEST_TMPDIR/xrootd_dst.log" || fail "size $size: the server gave up on the checksum"
}

# One byte; less than one range or block; several; many, and not a multiple
# of any range, block or write size.
sizes() {
	echo 1 $((5 * MIB + 1)) $((100 * MIB + 4321)) $((700 * MIB + 12345))
}

@test "the checksum computed while writing is stored and right: 1 stream" {
	for size in $(sizes); do checksum_after_pull "$size" 1; done
}

@test "the checksum computed while writing is stored and right: 2 streams" {
	for size in $(sizes); do checksum_after_pull "$size" 2; done
}

@test "the checksum computed while writing is stored and right: 4 streams" {
	for size in $(sizes); do checksum_after_pull "$size" 4; done
}

@test "the checksum computed while writing is stored and right: 8 streams" {
	for size in $(sizes); do checksum_after_pull "$size" 8; done
}

@test "the checksum computed while writing is stored and right: a slow source, 4 streams" {
	# Streams that take turns: the ranges or blocks end in an uneven order.
	local size=$((100 * MIB + 4321)) name=file_slow expected

	pull_and_classify "/f/${size}/${name}?fault=slow&rate=$((16 * MIB))" "$name" "$size" 4
	[[ "$outcome" == success ]] || fail "the pull failed: $message"
	expected=$(expected_adler32 "$size")
	[[ "$checksum" == ok ]] || fail "the checksum is $checksum"
	[[ "$(stored_adler32 "$name")" == "$expected" ]] || fail "stored $(stored_adler32 "$name"), the source has $expected"
}

# after_failure NAME SIZE: what a failed pull left, and that no checksum of
# the source file can be had for it.  Whether the part that arrived is kept is
# a matter of configuration.  If it is kept and has a stored checksum, that
# must be the checksum of the bytes kept.
after_failure() {
	local name=$1 size=$2 left on_disk stored state reported

	if [[ ! -f "$(dst_file "$name")" ]]; then
		echo "# after the failure: no file" >&3
		return 0
	fi
	left=$(stat -c %s "$(dst_file "$name")")
	on_disk=$(($(stat -c %b "$(dst_file "$name")") * 512))
	if has_stored_checksum "$name"; then
		stored=$(stored_adler32 "$name")
		state="stored checksum $stored"
		[[ "$stored" == "$(file_adler32 "$name")" ]] || fail "the stored checksum is not that of the bytes kept"
		[[ "$stored" != "$(expected_adler32 "$size")" ]] || fail "the stored checksum is that of the source file"
	else
		state="no stored checksum"
	fi
	reported=$(reported_adler32 "$name")
	echo "# after the failure: a file of $left bytes of $size ($on_disk on disk), $state, a query gives '$reported'" >&3
	[[ "$reported" != "$(expected_adler32 "$size")" ]] || fail "a query gives the checksum of the source file"
}

@test "a pull that fails early does not leave the checksum of the whole file" {
	local size=$((100 * MIB + 4321))

	pull_and_classify "/f/${size}/t?fault=drop&after=1000000&at=$((48 * MIB))" file_bad "$size" 4
	[[ "$outcome" == failure ]] || fail "the pull did not fail: $message"
	after_failure file_bad "$size"
}

@test "a pull that fails with later data already written does not leave the checksum of the whole file" {
	# Two streams.  The request that covers 70 MiB breaks after 10 MB; by
	# then the other stream has gone on to the end of the file.
	local size=$((100 * MIB + 4321))

	pull_and_classify "/f/${size}/t?fault=drop&after=10000000&at=$((70 * MIB))" file_bad "$size" 2
	[[ "$outcome" == failure ]] || fail "the pull did not fail: $message"
	after_failure file_bad "$size"
	grep -E "bytes missing at offset|checksum was not set" "$BATS_TEST_TMPDIR/xrootd_dst.log" | sed 's/^/# server: /' | cut -c1-200 >&3 || true
}
