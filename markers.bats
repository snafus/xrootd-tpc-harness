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

# The numbers of connections listed in the markers of a pull response, one
# number per marker that lists any.
connections_listed() {
	printf '%s\n' "$1" | sed -n 's/^RemoteConnections: //p' | awk -F, '{ print NF }'
}

# bats test_tags=slow
@test "a performance marker lists each connection once" {
	local body most

	# A marker is sent every 5 s.  The source is slowed down so that the pull
	# lasts about 12 s: two markers are sent while all the streams are busy,
	# after the request handles have each served several ranges.
	body=$(tpc_pull "/f/${SIZE}/t?fault=slow&rate=$((8 * MIB))" file_dst "$STREAMS")
	[[ "$(verdict "$body")" == success:* ]] || fail "the pull failed: $(verdict "$body")"

	most=$(connections_listed "$body" | sort -n | tail -1)
	((${most:-0} == STREAMS)) || fail "a marker lists ${most:-0} connections for $STREAMS streams"
}

# A pull keeps 16 request handles for each stream.  A file of more ranges than
# that makes it use handles again, and a handle used again still names the
# connection of its previous request for a moment.
# bats test_tags=slow
@test "a performance marker lists each connection once when request handles are used again" {
	local size=$((2048 * MIB)) body

	body=$(tpc_pull "/f/${size}/t?fault=slow&rate=$((36 * MIB))" file_dst "$STREAMS")
	[[ "$(verdict "$body")" == success:* ]] || fail "the pull failed: $(verdict "$body")"

	[[ -n "$(connections_listed "$body")" ]] || fail "no marker lists a connection"
	[[ "$(connections_listed "$body" | sort -u)" == "$STREAMS" ]] ||
		fail "markers list $(connections_listed "$body" | tr '\n' ' ')connections for $STREAMS streams"
}

# A source behind a redirector: each range is asked of the redirector, which
# sends the request on to the data server.  Both hold connections of the pull.
# bats test_tags=slow
@test "a performance marker lists the connections to a redirector and to the data server" {
	local data_port=$((SRC_PORT + 5)) body line

	python3 "$HARNESS_DIR/faulty_source.py" serve --port "$data_port" --bind 127.0.0.1 \
		>data-source.out 2>&1 3>&- &
	echo $! >"$BATS_TEST_TMPDIR/data-source.pid"
	for _ in {1..100}; do grep -qs READY data-source.out && break; sleep 0.05; done

	body=$(tpc_pull "/r/${data_port}/f/${SIZE}/t?fault=slow&rate=$((8 * MIB))" file_dst "$STREAMS")
	[[ "$(verdict "$body")" == success:* ]] || fail "the pull failed: $(verdict "$body")"

	line=$(printf '%s\n' "$body" | sed -n 's/^RemoteConnections: //p' | tail -1)
	[[ "$line" == *":${data_port}"* ]] || fail "no connection to the data server is listed: $line"
	while read -r count; do
		((count <= 2 * STREAMS)) || fail "a marker lists $count connections for $STREAMS streams and a redirector"
	done < <(connections_listed "$body")
	(($(tr ',' '\n' <<<"$line" | grep -c ":${data_port}\$") <= STREAMS)) ||
		fail "more than $STREAMS connections to the data server: $line"
}
