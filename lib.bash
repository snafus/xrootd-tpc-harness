#!/usr/bin/env bash

# Functions to start and stop the servers of a test.  They follow the helpers
# of the XRootD test suite (tests/end-to-end/helper/common.bash) but are kept
# here so that the harness needs nothing from the XRootD source tree: it runs
# against any xrootd found on the PATH, built or installed.

bats_require_minimum_version 1.11.0

# Prefer the programs of a build tree when one is given.
if [[ -n "${XROOTD_BUILD:-}" ]]; then
	export PATH="${XROOTD_BUILD}/bin:${PATH}"
fi

fail() {
	echo "$*" >&2
	return 1
}

# launch_xrootd CONFIGURATION NAME
#
# Start xrootd in the background and wait until it has completed its
# initialization, so that a test never races with the server start-up.
launch_xrootd() {
	local config=$1 name=$2
	local log="$BATS_TEST_TMPDIR/$name.log"
	local pidfile="$BATS_TEST_TMPDIR/$name.pid"
	local -a as=()

	if [[ $(id -u) == 0 ]]; then
		# xrootd does not run as root: it switches to the user named with -R.
		[[ -n "${TPC_RUN_AS:-}" ]] ||
			{ echo "run as root: set TPC_RUN_AS to the user the servers are to run as" >&2; return 1; }
		as=(-R "$TPC_RUN_AS")
		give_to_server_user "$BATS_TEST_TMPDIR"
	fi

	# XROOTD_WRAPPER: a command to start xrootd under, for example
	# "setarch x86_64 -R" for a build with the thread sanitizer.
	# shellcheck disable=SC2086
	(cd "$BATS_TEST_TMPDIR" && NAME=$name \
		${XROOTD_WRAPPER:-} xrootd "${as[@]}" -b -c "$BATS_TEST_DIRNAME/$config" -l "$name.log" -s "$name.pid")

	for _ in {1..200}; do
		grep -qsE '^------ xrootd .* initialization completed' "$log" && return 0
		grep -qsE '^------ xrootd .* initialization failed' "$log" && break
		# the pid file exists but the daemon is gone
		[[ -s "$pidfile" ]] && ! is_running "$(<"$pidfile")" && break
		sleep 0.05
	done

	echo "xrootd '$name' failed to start" >&2
	[[ -f "$log" ]] && cat "$log" >&2
	return 1
}

# give_to_server_user DIRECTORY: when the tests run as root, hand a directory
# to the user the servers run as, and let that user reach it.
give_to_server_user() {
	local dir=$1 top

	[[ $(id -u) == 0 && -n "${TPC_RUN_AS:-}" ]] || return 0
	chown -R "$TPC_RUN_AS" "$dir"
	# bats makes its temporary directories (RUN/test/N) for root alone; open
	# those, and nothing outside them.  For the group as well: a server
	# started with -R keeps the groups of root, so the group bits apply to it.
	top=$(dirname "$(dirname "$BATS_TEST_TMPDIR")")
	while [[ "$dir" == "$top"* ]]; do
		chmod go+rx "$dir"
		dir=$(dirname "$dir")
	done
	return 0
}

# A daemon that exited stays a zombie until its parent reaps it, and in a
# container the parent may be a PID 1 that never does, so kill -0 alone would
# report it as running.
is_running() {
	local pid=$1 stat

	stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
	# the state follows the command name, which is in parentheses
	stat=${stat##*) }
	[[ ${stat%% *} != Z ]]
}

# Stop every daemon started by the test and wait until it has exited, so that
# the next test can bind the same ports.
kill_pid_files() {
	local pid

	# xrootd writes its pid without a newline, hence awk and not cat
	for pid in $(find "$BATS_TEST_TMPDIR" -name '*.pid' -type f -exec awk '{ print }' {} + | sort -u); do
		[[ "$pid" =~ ^[0-9]+$ ]] && is_running "$pid" || continue

		kill "$pid" 2>/dev/null
		for _ in {1..100}; do
			is_running "$pid" || break
			sleep 0.05
		done
		is_running "$pid" && kill -9 "$pid" 2>/dev/null
	done

	find "$BATS_TEST_TMPDIR" -name '*.pid' -type f -delete
	return 0
}

# Show the server logs of a failed test, unless BATS_SKIP_SERVER_LOGS is set.
bats::on_failure() {
	local file name

	[[ -n "${BATS_SKIP_SERVER_LOGS:-}" ]] && return 0
	for file in $(find "$BATS_TEST_TMPDIR" -name '*.log' -type f ! -empty); do
		name=${file##*/}
		printf '\n'
		sed "s|^|[${name%.*}] |" "$file"
		printf '\n'
	done
}
