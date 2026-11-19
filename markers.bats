#!/usr/bin/env bash

# The performance markers a pull sends to its client while it runs.

load helper.bash

readonly SIZE=$((400 * MIB + 4321))
readonly STREAMS=4

setup() {
	cd "$BATS_TEST_TMPDIR"
	launch_source
	launch_destination
}

teardown() {
	stop_servers
}

# bats test_tags=slow
@test "a performance marker lists each connection once" {
	local body most

	# A marker is sent every 5 s.  The source is slowed down so that the pull
	# lasts about 12 s: two markers are sent while all the streams are busy,
	# after the request handles have each served several ranges.
	body=$(tpc_pull "/f/${SIZE}/t?fault=slow&rate=$((8 * MIB))" file_dst "$STREAMS")
	[[ "$(verdict "$body")" == success:* ]] || fail "the pull failed: $(verdict "$body")"

	# the largest number of connections listed in one marker
	most=$(printf '%s\n' "$body" | sed -n 's/^RemoteConnections: //p' |
		awk -F, '{ if (NF > most) most = NF } END { print most + 0 }')
	((most == STREAMS)) || fail "a marker lists $most connections for $STREAMS streams"
}
