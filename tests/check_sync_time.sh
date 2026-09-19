#!/bin/bash
# Runs sync_time from trans.sh with ntpd and the HTTP Date fallback each stubbed
# to succeed or fail. The caller treats the sync as optional (`sync_time || true`),
# so the only thing it can do about a double failure is say so: a clock that is
# far off makes the later HTTPS downloads fail on certificate dates.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh

# Pulls one top-level function out of trans.sh, closing brace included.
extract_fn() {
    awk -v name="$1" '
        index($0, name "() {") == 1 { found = 1 }
        found { print }
        found && $0 == "}" { exit }
    ' "$trans" | grep . || {
        echo "cannot extract $1() from trans.sh" >&2
        exit 1
    }
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# trans.sh's collaborators, replaced. ntpd and wget answer per mode; the apk
# repositories file the function reads for a mirror URL is answered by a grep
# stub for that one call and passed through otherwise.
cat >"$work/stubs.sh" <<'STUBS'
warn() { echo "warn: $*" >&2; }
ntpd() { [ "$ntp_mode" = ok ]; }
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
extract_fn sync_time >"$work/fns.sh"

# Called exactly as trans.sh calls it: the sync is allowed to fail.
cat >"$work/case.sh" <<CASE
set -eE
. "$work/stubs.sh"
. "$work/fns.sh"
ntp_mode=\$1
http_mode=\$2
sync_time || true
CASE

failures=0
check() {
    if [ "$2" = "$3" ]; then
        echo "    ok   $1 = $2"
    else
        echo "    FAIL $1: expected '$3', got '$2'" >&2
        failures=$((failures + 1))
    fi
}

# run_case <shell command> <ntp mode> <http mode>; the log is what is asserted on.
run_case() {
    local shell=$1
    # shellcheck disable=SC2086
    $shell "$work/case.sh" "$2" "$3" >/dev/null 2>"$work/log"
}
said() { grep -q "$1" "$work/log" && echo yes || echo no; }

shells=(bash)
if busybox ash -c : 2>/dev/null; then
    shells+=("busybox ash")
fi

for shell in "${shells[@]}"; do
    run_case "$shell" ok ok
    check "$shell / ntp ok: no warning" "$(said warn:)" no

    run_case "$shell" fail ok
    check "$shell / http fallback: says NTP failed" "$(said 'NTP sync failed')" yes
    check "$shell / http fallback: does not claim total failure" "$(said 'Time sync failed')" no

    run_case "$shell" fail fail
    check "$shell / both fail: says so" "$(said 'Time sync failed')" yes
done

if [ "$failures" != 0 ]; then
    echo "check_sync_time: $failures assertion(s) failed" >&2
    exit 1
fi
echo "check_sync_time: ok"
exit 0
