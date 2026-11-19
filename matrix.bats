#!/usr/bin/env bash

# A pull must produce the right file for every size and every number of
# streams.  The sizes sit on both sides of the 16 MiB range the multi-stream
# code splits a file into.
#
# The quick run keeps the sizes up to 48 MiB with 1 and 4 streams; the other
# combinations are tagged "slow" and run in the full suite only.

load helper.bash

setup() {
	cd "$BATS_TEST_TMPDIR"
	launch_source
	launch_destination
}

teardown() {
	stop_servers
}

pull_of_size() {
	local size=$1 streams=$2

	pull_and_classify "/f/${size}" file_dst "$size" "$streams"
	assert_pull_succeeded
	assert_destination_alive
}

for size in 0 1 $((16 * MIB - 1)) $((16 * MIB)) $((16 * MIB + 1)) $((48 * MIB + 12345)) $((256 * MIB)); do
	for streams in 1 2 4 10; do
		tags=()
		if ((size > 64 * MIB || streams == 2 || streams == 10)); then
			tags=(--tags slow)
		fi
		bats_test_function --description "pull of ${size} bytes with ${streams} streams" \
			"${tags[@]}" -- pull_of_size "$size" "$streams"
	done
done

# The size of the smallest upstream test that is skipped as a known bug.
for streams in 4 10; do
	bats_test_function --description "pull of $((1024 * MIB)) bytes with ${streams} streams" \
		--tags slow -- pull_of_size $((1024 * MIB)) "$streams"
done
