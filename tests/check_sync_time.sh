#!/bin/bash
# Runs sync_time from trans.sh with ntpd and the HTTP Date fallback each stubbed
# to succeed or fail. The caller treats the sync as optional (`sync_time || true`),
# so the only thing it can do about a double failure is say so: a clock that is
# far off makes the later HTTPS downloads fail on certificate dates. The pool it asks
# follows the host's address family: pool.ntp.org has no AAAA.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# trans.sh's collaborators, replaced. ntpd and wget answer per mode; the apk
# repositories file the function reads for a mirror URL is answered by a grep
# stub for that one call and passed through otherwise. ip answers whether there is
# an IPv4 default route, which picks the NTP pool; ntpd records the peer it got.
cat >"$work/stubs.sh" <<'STUBS'
warn() { echo "warn: $*" >&2; }
ip() { [ "$*" = "-4 route show default" ] && [ "$v4" = yes ] && echo "default via 203.0.113.1 dev eth0"; return 0; }
ntpd() { echo "ntpd $*" >&2; [ "$ntp_mode" = ok ]; }
wget() {
    if [ "$http_mode" = ok ]; then
        echo "  Date: Mon, 01 Jan 2024 00:00:00 GMT"
        return 0
    fi
    return 4
}
busybox() {
    if [ "$1" = date ]; then
        echo "date set: $*"
        return 0
    fi
    command busybox "$@"
}
grep() {
    if [ "$1" = -m1 ] && [ "$2" = ^http ]; then
        echo http://dl-cdn.alpinelinux.org/alpine/v3.22/main
        return 0
    fi
    command grep "$@"
}
STUBS
extract_fn "$trans" get_ntp_server >"$work/fns.sh"
extract_fn "$trans" sync_time >>"$work/fns.sh"

# Called exactly as trans.sh calls it: the sync is allowed to fail.
cat >"$work/case.sh" <<CASE
set -eE
. "$work/stubs.sh"
. "$work/fns.sh"
ntp_mode=\$1
http_mode=\$2
v4=\$3
sync_time || true
CASE

# run_case <shell command> <ntp mode> <http mode> [<ipv4 route: yes|no>]; the log is what is asserted on.
run_case() {
    local shell=$1
    # shellcheck disable=SC2086
    $shell "$work/case.sh" "$2" "$3" "${4:-yes}" >/dev/null 2>"$work/log"
}
said() { grep -q "$1" "$work/log" && echo yes || echo no; }

for shell in "${shells[@]}"; do
    run_case "$shell" ok ok
    check "$shell / ntp ok: no warning" "$(said warn:)" no

    run_case "$shell" fail ok
    check "$shell / http fallback: says NTP failed" "$(said 'NTP sync failed')" yes
    check "$shell / http fallback: does not claim total failure" "$(said 'Time sync failed')" no

    run_case "$shell" fail fail
    check "$shell / both fail: says so" "$(said 'Time sync failed')" yes

    run_case "$shell" ok ok yes
    check "$shell / with ipv4: pool.ntp.org" "$(said 'ntpd .* -p pool.ntp.org$')" yes
    run_case "$shell" ok ok no
    check "$shell / ipv6 only: the pool's dual-stack zone" "$(said 'ntpd .* -p 2.pool.ntp.org$')" yes
done

finish
