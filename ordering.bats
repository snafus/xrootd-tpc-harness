#!/usr/bin/env bash

# A multi-stream pull must give the right file whatever the order in which
# the ranges arrive, and however unequal the streams are.
#
# The source decides when each range is answered, so the order is the same on
# every run.  Each test also checks that the order it wanted really happened:
# a test of reordering in which nothing was reordered proves nothing.

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

pull_in_order() { # QUERY [SIZE] [STREAMS]
	local size=${2:-$SIZE} streams=${3:-$STREAMS}

	pull_and_classify "/f/${size}/t?$1" file_dst "$size" "$streams"
	assert_pull_succeeded
	assert_destination_alive
}

# Fail unless at least one range was complete before a range that precedes it
# in the file.
assert_arrived_out_of_order() {
	local order
	order=$(arrival_order)
	if [[ "$order" == "$(sort -n <<<"$order")" ]]; then
		fail "the ranges arrived in file order: $(tr '\n' ' ' <<<"$order")"
	fi
}

@test "right file when the first range arrives last" {
	pull_in_order "fault=slow&rate=$((16 * MIB))&at=0"
	run arrival_order
	[[ "${lines[-1]}" == 0 ]] || fail "the first range was not the last to arrive: ${lines[*]}"
}

@test "right file when later ranges are answered first" {
	pull_in_order "fault=late&order=reverse&window=${STREAMS}&step=0.25"
	assert_arrived_out_of_order
}

@test "right file when ranges are answered after random waits (seed 1)" {
	pull_in_order "fault=late&order=random&seed=1&max=1"
	assert_arrived_out_of_order
}

for seed in 2 3 4 5 6; do
	bats_test_function --tags slow \
		--description "right file when ranges are answered after random waits (seed ${seed})" \
		-- pull_in_order "fault=late&order=random&seed=${seed}&max=1" $((200 * MIB + 77)) 4
done

# One connection is slow for the whole copy.  The others must carry on, the
# copy must end well, and the slow stream must not be taken for a stalled one.
# bats test_tags=slow
@test "right file when one connection is slow for the whole copy" {
	pull_in_order "fault=slow&rate=$((8 * MIB))&conn=1" $((512 * MIB + 4321)) 4
	assert_arrived_out_of_order
}

# The other streams may run ahead of a slow first range only as far as the
# reorder buffers allow: 16 buffers per stream today (defect B4).  This test
# measures that limit instead of reading it from the code.  With 2 streams the
# limit is 32 ranges, and the file has 48.
# bats test_tags=slow
@test "streams run ahead of a slow first range by no more than the buffers allow" {
	local streams=2 ahead
	local limit=$((16 * streams))

	TPC_MAX_TIME=180 pull_in_order "fault=slow&rate=$((4 * MIB))&at=0" $((768 * MIB)) "$streams"
	ahead=$(ranges_ahead_of_first)
	record info "ranges_ahead=$ahead limit=$limit"
	((ahead >= limit / 2)) || fail "only $ahead ranges ran ahead: the test did not reach the limit"
	((ahead <= limit)) || fail "$ahead ranges ran ahead of the first one, more than the $limit buffers"
}
