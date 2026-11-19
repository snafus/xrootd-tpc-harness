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

	(cd "$BATS_TEST_TMPDIR" && NAME=$name \
		xrootd -b -c "$BATS_TEST_DIRNAME/$config" -l "$name.log" -s "$name.pid")

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
