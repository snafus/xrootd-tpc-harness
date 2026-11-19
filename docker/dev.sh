#!/usr/bin/env bash
# Build XRootD and run the harness inside the development container.
#
#   dev.sh image              build the container image
#   dev.sh configure          run cmake for the XRootD source tree
#   dev.sh build [TARGET...]  compile XRootD
#   dev.sh test [quick|full]  run the tests (default: quick)
#   dev.sh bats ARG...        run bats directly, for one file or one test
#   dev.sh run CMD [ARG...]   run a command in the container, in the harness
#   dev.sh shell              interactive shell
#
# XROOTD_SRC names the XRootD source tree and XROOTD_BUILD its build tree
# (default: $XROOTD_SRC/build).  Set them in the environment or in the file
# local.env at the top of the harness.  Both trees and the harness are mounted
# at the same paths as on the host, so paths printed by the compiler and the
# tests can be used directly.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HARNESS=$(cd "$HERE/.." && pwd)
# shellcheck disable=SC1091
[[ -f "$HARNESS/local.env" ]] && source "$HARNESS/local.env"
: "${XROOTD_SRC:?set XROOTD_SRC to the XRootD source tree, here or in local.env}"
XROOTD_BUILD=${XROOTD_BUILD:-$XROOTD_SRC/build}
IMAGE=${IMAGE:-xrd-tpc-dev:alma9}
JOBS=${JOBS:-3}
BATS="$XROOTD_SRC/vendor/bats/bin/bats"

# Settings of the tests and of the measurement script are passed through.
FORWARD="TPC_SURVEY TPC_MAX_TIME TPC_DEST_DIR BATS_SKIP_SERVER_LOGS RTTS STREAMS BUFFERS RATE DURATION IDLE LOSSES QUEUE_MS"

run() {
	local -a env=() mounts=(-v "$XROOTD_SRC:$XROOTD_SRC" -v "$HARNESS:$HARNESS")
	local name
	for name in $FORWARD; do
		[[ -n "${!name+x}" ]] && env+=(-e "$name")
	done
	[[ "$XROOTD_BUILD" == "$XROOTD_SRC"/* ]] || mounts+=(-v "$XROOTD_BUILD:$XROOTD_BUILD")
	[[ -z "${TPC_DEST_DIR:-}" ]] || mounts+=(-v "$TPC_DEST_DIR:$TPC_DEST_DIR")
	docker run --rm ${TTY:-} ${DOCKER_ARGS:-} "${env[@]}" "${mounts[@]}" -w "$HARNESS" \
		-e XROOTD_SRC="$XROOTD_SRC" -e XROOTD_BUILD="$XROOTD_BUILD" -e BATS="$BATS" \
		"$IMAGE" "$@"
}

cmd=${1:-}
shift || true
case "$cmd" in
image)
	docker build --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" -t "$IMAGE" "$HERE"
	;;
configure)
	run cmake -S "$XROOTD_SRC" -B "$XROOTD_BUILD" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
		-DENABLE_TESTS=ON -DENABLE_PYTHON=OFF -DENABLE_FUSE=OFF -DENABLE_KRB5=OFF \
		-DENABLE_VOMS=OFF -DENABLE_XRDOSSARC=OFF "$@"
	;;
build)
	if [[ $# -gt 0 ]]; then
		run cmake --build "$XROOTD_BUILD" -j"$JOBS" --target "$@"
	else
		run cmake --build "$XROOTD_BUILD" -j"$JOBS"
	fi
	;;
test)
	run ./run.sh "$@"
	;;
bats)
	run "$BATS" "$@"
	;;
run)
	run "$@"
	;;
shell)
	TTY=-it run bash
	;;
*)
	sed -n '2,16p' "${BASH_SOURCE[0]}"
	exit 1
	;;
esac
