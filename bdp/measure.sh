#!/usr/bin/env bash
# Measure the throughput of an HTTP-TPC pull over an emulated long path.
#
# Must run as root in a privileged container (it creates network namespaces):
#
#   DOCKER_ARGS="--privileged -u 0" docker/dev.sh run bdp/measure.sh RESULTS.tsv
#
# Two network namespaces, "src" and "dst", are joined by a virtual link with a
# 1500 byte MTU.  Each end delays what it sends by half the round-trip time and
# is limited to RATE.  A source and a destination XRootD run one in each
# namespace; the destination pulls a very large file for DURATION seconds and
# the rate is read from the performance markers it sends back.
#
# With QUEUE_MS a third namespace, "rtr", sits between the two as a router.
# The hosts only delay; the router limits the rate and has the short queue.
# This is needed because a queue on the sending host itself never loses a
# packet: Linux holds the sender back instead.
#
# Environment:
#   RTTS      round-trip times in ms            (default "10 150 300")
#   STREAMS   values of X-Number-Of-Streams     (default "1 4 8")
#   BUFFERS   "default" and/or "tuned"          (default "default tuned")
#   RATE      link rate                         (default 1gbit)
#   DURATION  seconds per run                   (default 40)
#   IDLE      tcp_slow_start_after_idle at the source (default 1, the Linux default)
#   LOSSES    share of the data packets lost, in percent (default "0")
#   QUEUE_MS  depth of the router's queue, in ms at the link rate
#             (default: empty, no router and a queue that never overflows)
#
# Loss is random and applies to the direction the data travels in (source to
# destination).  When LOSSES or QUEUE_MS is used, segmentation offload is
# turned off on the link, so that the link drops and counts single packets
# and not bursts of up to 64 kB.
set -uo pipefail

RESULTS=${1:?usage: measure.sh RESULTS.tsv}
RTTS=${RTTS:-10 150 300}
STREAMS=${STREAMS:-1 4 8}
BUFFERS=${BUFFERS:-default tuned}
RATE=${RATE:-1gbit}
DURATION=${DURATION:-40}
IDLE=${IDLE:-1}
LOSSES=${LOSSES:-0}
QUEUE_MS=${QUEUE_MS:-}

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BIN="${XROOTD_BUILD:?set XROOTD_BUILD to the XRootD build tree}/bin"
WORK=$(mktemp -d /tmp/bdp.XXXXXX)
chmod 755 "$WORK"
SRC_IP=10.99.0.1
DST_IP=10.99.0.2
[[ -n "$QUEUE_MS" ]] && DST_IP=10.99.1.2
SRC_PORT=8650
DST_PORT=8651
FILE_SIZE=$((200 * 1024 * 1024 * 1024))
USER_NAME=dev

as_user() { # NAMESPACE COMMAND...
	local ns=$1
	shift
	ip netns exec "$ns" runuser -u "$USER_NAME" -- env PATH="$BIN:$PATH" "$@"
}

teardown() {
	pkill -x xrootd 2>/dev/null
	for _ in {1..50}; do pgrep -x xrootd >/dev/null || break; sleep 0.1; done
	pkill -9 -x xrootd 2>/dev/null
	ip netns del src 2>/dev/null
	ip netns del dst 2>/dev/null
	ip netns del rtr 2>/dev/null
	return 0
}
trap teardown EXIT

rate_pps() { # packets of 1514 bytes per second at RATE
	local n=${RATE%%[a-z]*} unit=${RATE##*[0-9]}
	case "$unit" in
	gbit) echo $((n * 1000000000 / 8 / 1514)) ;;
	mbit) echo $((n * 1000000 / 8 / 1514)) ;;
	*) echo "RATE must be in mbit or gbit to use QUEUE_MS" >&2; return 1 ;;
	esac
}

no_offload() { # NAMESPACE DEVICE
	ip netns exec "$1" ethtool -K "$2" tso off gso off gro off >/dev/null
}

# Direct link: src (vsrc) --- (vdst) dst
direct_link() {
	ip link add vsrc type veth peer name vdst
	ip link set vsrc netns src
	ip link set vdst netns dst
	ip -n src addr add "$SRC_IP/24" dev vsrc
	ip -n dst addr add "$DST_IP/24" dev vdst
	ip -n src link set vsrc up
	ip -n dst link set vdst up
}

# Routed link: src (vsrc) --- (rsrc) rtr (rdst) --- (vdst) dst
routed_link() {
	ip netns add rtr
	ip link add vsrc type veth peer name rsrc
	ip link add vdst type veth peer name rdst
	ip link set vsrc netns src
	ip link set vdst netns dst
	ip link set rsrc netns rtr
	ip link set rdst netns rtr
	ip -n src addr add "$SRC_IP/24" dev vsrc
	ip -n dst addr add "$DST_IP/24" dev vdst
	ip -n rtr addr add "${SRC_IP%.*}.254/24" dev rsrc
	ip -n rtr addr add "${DST_IP%.*}.254/24" dev rdst
	ip -n src link set vsrc up
	ip -n dst link set vdst up
	ip -n rtr link set rsrc up
	ip -n rtr link set rdst up
	ip -n rtr link set lo up
	ip -n src route add default via "${SRC_IP%.*}.254"
	ip -n dst route add default via "${DST_IP%.*}.254"
	ip netns exec rtr sysctl -qw net.ipv4.ip_forward=1
}

setup_network() { # RTT_MS BUFFERS LOSS
	local half=$(($1 / 2)) buffers=$2 loss=$3 pps
	local -a drop=() rate=(rate "$RATE")

	ip netns add src
	ip netns add dst
	ip -n src link set lo up
	ip -n dst link set lo up
	[[ "$loss" != 0 ]] && drop=(loss "${loss}%")

	if [[ -n "$QUEUE_MS" ]]; then
		# The router forwards at RATE and keeps QUEUE_MS of backlog; what does
		# not fit is dropped.  The hosts delay and do not limit the rate.
		pps=$(rate_pps) || return 1
		routed_link || return 1
		no_offload rtr rsrc && no_offload rtr rdst || return 1
		tc -n rtr qdisc add dev rdst root netem rate "$RATE" limit $((pps * QUEUE_MS / 1000)) || return 1
		tc -n rtr qdisc add dev rsrc root netem rate "$RATE" limit $((pps * QUEUE_MS / 1000)) || return 1
		rate=()
	else
		direct_link || return 1
	fi
	if [[ "$loss" != 0 || -n "$QUEUE_MS" ]]; then
		no_offload src vsrc && no_offload dst vdst || return 1
	fi

	# The queue of each host is long enough to hold everything in flight: a
	# host loses nothing unless a sender overshoots the link rate by a wide
	# margin.
	tc -n src qdisc add dev vsrc root netem delay "${half}ms" "${rate[@]}" limit 400000 "${drop[@]}" || return 1
	tc -n dst qdisc add dev vdst root netem delay "${half}ms" "${rate[@]}" limit 400000 || return 1

	ip netns exec src sysctl -qw net.ipv4.tcp_slow_start_after_idle="$IDLE"
	if [[ "$buffers" == tuned ]]; then
		ip netns exec src sysctl -qw net.ipv4.tcp_wmem="4096 65536 268435456"
		ip netns exec dst sysctl -qw net.ipv4.tcp_rmem="4096 131072 268435456"
	fi
}

launch() { # NAMESPACE NAME PORT
	local ns=$1 name=$2 port=$3

	mkdir -p "$WORK/$name"
	chown -R "$USER_NAME" "$WORK"
	(cd "$WORK" && as_user "$ns" env RUN="$WORK" NAME="$name" PORT="$port" \
		xrootd -b -c "$HERE/mirage.cfg" -l "$WORK/$name.log" -s "$WORK/$name.pid")
	for _ in {1..200}; do
		grep -qsE '^------ xrootd .* initialization completed' "$WORK/$name.log" && return 0
		sleep 0.05
	done
	echo "xrootd $name failed to start" >&2
	tail -20 "$WORK/$name.log" >&2
	return 1
}

summarise() { # MARKERS CWND_LOG -> "overall steady last30 connections cwnd_median cwnd_min retrans_pct"
	python3 - "$1" "$2" <<'PY'
import re, statistics, sys
points, stamp = [], None
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"\s*Timestamp: (\d+)", line)
    if m:
        stamp = int(m.group(1))
    m = re.match(r"\s*Stripe Bytes Transferred: (\d+)", line)
    if m and stamp is not None:
        points.append((stamp, int(m.group(1))))
overall = steady = last = 0.0
if len(points) >= 2:
    t0 = points[0][0]
    span = points[-1][0] - t0
    if span > 0:
        overall = points[-1][1] / span / 1e6
    later = [p for p in points if p[0] - t0 >= 10]
    if len(later) >= 2 and later[-1][0] > later[0][0]:
        steady = (later[-1][1] - later[0][1]) / (later[-1][0] - later[0][0]) / 1e6
    final = [p for p in points if points[-1][0] - p[0] <= 30]
    if len(final) >= 2 and final[-1][0] > final[0][0]:
        last = (final[-1][1] - final[0][1]) / (final[-1][0] - final[0][0]) / 1e6
ports, cwnds, began, now = set(), [], None, None
port, sent, resent = None, {}, {}
for line in open(sys.argv[2], errors="replace"):
    m = re.match(r"@ ([\d.]+)", line)
    if m:
        now = float(m.group(1))
        began = began or now
        continue
    m = re.search(r"\S+:8650\s+\S+:(\d+)\s*$", line)
    if m:
        port = m.group(1)
        ports.add(port)
    m = re.search(r"\bdata_segs_out:(\d+)", line)
    if m and port:
        sent[port] = max(sent.get(port, 0), int(m.group(1)))
    m = re.search(r"\bretrans:\d+/(\d+)", line)
    if m and port:
        resent[port] = max(resent.get(port, 0), int(m.group(1)))
    m = re.search(r"\bcwnd:(\d+)", line)
    if m and now is not None and now - began >= 10:
        cwnds.append(int(m.group(1)))
median = int(statistics.median(cwnds)) if cwnds else 0
retrans = 100.0 * sum(resent.values()) / sum(sent.values()) if sum(sent.values()) else 0.0
print("%.1f\t%.1f\t%.1f\t%d\t%d\t%d\t%.4f" % (overall, steady, last, len(ports), median, min(cwnds) if cwnds else 0, retrans))
PY
}

run_one() { # RTT BUFFERS STREAMS LOSS
	local rtt=$1 buffers=$2 streams=$3 loss=$4 tag="rtt${1}-${2}-s${3}"
	local -a header=()

	[[ "$loss" != 0 ]] && tag+="-loss$loss"
	[[ -n "$QUEUE_MS" ]] && tag+="-q$QUEUE_MS"
	teardown
	rm -rf "$WORK/xrootd_src" "$WORK/xrootd_dst" "$WORK"/*.log "$WORK"/*.pid
	setup_network "$rtt" "$buffers" "$loss" || { echo "cannot set up the network" >&2; return 1; }
	launch src xrootd_src "$SRC_PORT" || return 1
	launch dst xrootd_dst "$DST_PORT" || return 1

	# A file of one byte, grown to its final size: Mirage generates the content.
	printf x | as_user src curl -sS -o /dev/null -T - "http://$SRC_IP:$SRC_PORT/big" || return 1
	as_user src xrdfs "root://$SRC_IP:$SRC_PORT" truncate /big "$FILE_SIZE" || return 1

	[[ "$streams" != 1 ]] && header=(-H "X-Number-Of-Streams: $streams")

	( while :; do
		echo "@ $(date +%s.%N)"
		ip netns exec src ss -tin "sport = :$SRC_PORT"
		sleep 0.5
	done ) >"$WORK/$tag.cwnd" 2>/dev/null &
	local sampler=$!

	as_user dst curl -sS -N --max-time "$DURATION" -X COPY \
		-H "Source: http://$SRC_IP:$SRC_PORT/big" "${header[@]}" \
		"http://$DST_IP:$DST_PORT/out" >"$WORK/$tag.markers" 2>"$WORK/$tag.err"

	kill "$sampler" 2>/dev/null
	wait "$sampler" 2>/dev/null
	if [[ -n "$QUEUE_MS" ]]; then
		tc -n rtr -s qdisc show dev rdst >"$WORK/$tag.router"
		cp "$WORK/$tag.router" "$(dirname "$RESULTS")/" 2>/dev/null
	fi

	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$rtt" "$buffers" "$loss" "${QUEUE_MS:-deep}" "$streams" \
		"$(summarise "$WORK/$tag.markers" "$WORK/$tag.cwnd")" | tee -a "$RESULTS"
	cp "$WORK/$tag.markers" "$WORK/$tag.cwnd" "$(dirname "$RESULTS")/" 2>/dev/null
	return 0
}

printf 'rtt_ms\tbuffers\tloss_pct\tqueue_ms\tstreams\tMB/s_overall\tMB/s_after_10s\tMB/s_last_30s\tconnections\tcwnd_median\tcwnd_min\tretrans_pct\n' >"$RESULTS"
for rtt in $RTTS; do
	for buffers in $BUFFERS; do
		for loss in $LOSSES; do
			for streams in $STREAMS; do
				run_one "$rtt" "$buffers" "$streams" "$loss" ||
					echo "run rtt=$rtt $buffers loss=$loss s=$streams failed" >&2
			done
		done
	done
done
teardown
chown -R "$USER_NAME" "$(dirname "$RESULTS")" 2>/dev/null
