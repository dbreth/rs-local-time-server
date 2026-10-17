#!/usr/bin/env bash
# One-shot clock sync from a ROAR time-server, no configuration needed.
#
# Usage: get-date.sh <server-ip> [port]   (port defaults to 8123)
#
# Fetches the server's time as JSON over HTTP (pure bash, no curl/jq required),
# compensates for half the round-trip time, sets the clock with `date -s`, then
# re-checks against the server and prints the remaining offset.
set -euo pipefail

if [[ $# -lt 1 || $1 == -h || $1 == --help ]]; then
    echo "usage: get-date.sh <server-ip> [port]" >&2
    exit 2
fi

server=$1
port=${2:-8123}

sudo=()
if [[ $EUID -ne 0 ]]; then
    sudo=(sudo)
    # Ask for the password now, so typing it doesn't delay setting the clock.
    sudo -v
fi

# Sets rtt_ns and offset_ns (how far the local clock is behind the server, assuming a
# symmetric network path). Timestamps are taken inside the connection with $EPOCHREALTIME
# (no fork), so the round-trip time measures the network, not process startup.
measure() {
    local response server_ns t0 t1
    response=$(timeout 5 bash -c '
        t0=$EPOCHREALTIME
        exec 3<>"/dev/tcp/$0/$1" || exit 1
        printf "GET / HTTP/1.0\r\nHost: %s\r\n\r\n" "$0" >&3
        body=$(cat <&3)
        t1=$EPOCHREALTIME
        printf "%s\nt0=%s t1=%s\n" "$body" "${t0/[.,]/}" "${t1/[.,]/}"
    ' "$server" "$port" 2>/dev/null) || {
        echo "error: could not reach time-server at $server:$port" >&2
        exit 1
    }

    if [[ $response =~ \"unix_ns\":([0-9]+) ]]; then
        server_ns=${BASH_REMATCH[1]}
    else
        echo "error: unexpected response from $server:$port:" >&2
        echo "$response" >&2
        exit 1
    fi
    [[ $response =~ t0=([0-9]+)\ t1=([0-9]+) ]]
    # EPOCHREALTIME has microsecond resolution; convert to ns.
    t0=$((10#${BASH_REMATCH[1]} * 1000))
    t1=$((10#${BASH_REMATCH[2]} * 1000))

    rtt_ns=$((t1 - t0))
    offset_ns=$((server_ns + rtt_ns / 2 - t1))
}

# Format nanoseconds as signed milliseconds with 3 decimals, e.g. -1523.412 ms.
fmt_ms() {
    local ns=$1 sign=+
    ((ns < 0)) && sign=- ns=$((-ns))
    printf '%s%d.%03d ms' "$sign" $((ns / 1000000)) $((ns / 1000 % 1000))
}

measure
initial_offset_ns=$offset_ns

# Compute the target as late as possible: current local time + offset.
now=$EPOCHREALTIME
now_ns=$(( 10#${now/[.,]/} * 1000 + offset_ns ))
"${sudo[@]}" date -s "@$((now_ns / 1000000000)).$(printf '%09d' $((now_ns % 1000000000)))" >/dev/null

# Ask the server again to verify the result.
measure

rtt=$(fmt_ms "$rtt_ns")
rows=(
    "host      $(hostname)"
    "date      $(date '+%F %T.%3N %Z')"
    "was off   $(fmt_ms "$initial_offset_ns")"
    "now off   $(fmt_ms "$offset_ns")"
    "rtt       ${rtt#+}"
)
title="time-server $server:$port"
width=${#title}
for r in "${rows[@]}"; do ((${#r} > width)) && width=${#r}; done
border="+$(printf '%*s' $((width + 2)) '' | tr ' ' -)+"

echo "$border"
printf '| %-*s |\n' "$width" "$title"
echo "$border"
for r in "${rows[@]}"; do printf '| %-*s |\n' "$width" "$r"; done
echo "$border"
