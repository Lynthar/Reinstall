#!/bin/bash
# Runs find_xda from trans.sh against stubbed disks. The disk it picks is the one
# that gets wiped, so a partition table id found on two disks (a cloned volume)
# must stop the install instead of picking whichever disk is listed first.
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

# Each case writes "<disk> <id as sfdisk prints it>" lines to $work/disks.
cat >"$work/stubs.sh" <<STUBS
error_and_exit() { echo "error: \$*" >&2; exit 1; }
get_config() { return 1; }
set_config() { echo "saved \$1=\$2" >&2; }
is_have_cmd() { return 0; }
apk() { :; }
get_all_disks() { awk '{print \$1}' "$work/disks"; }
sfdisk() { awk -v d="\${2#/dev/}" '\$1 == d {print \$2}' "$work/disks"; }
STUBS
extract_fn find_xda >"$work/fns.sh"

cat >"$work/case.sh" <<CASE
set -eE
. "$work/stubs.sh"
. "$work/fns.sh"
main_disk=\$1
find_xda >/dev/null
echo "xda=\$xda"
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

# run_case <shell command> <main_disk> <disk lines...>; prints the picked disk or "aborted".
run_case() {
    local shell=$1 id=$2
    shift 2
    printf '%s\n' "$@" >"$work/disks"
    # shellcheck disable=SC2086
    $shell "$work/case.sh" "$id" 2>"$work/log" || echo aborted
}

guid_a=d6b17c1a-fa1e-40a1-bdcb-0278a3ed9cfc
guid_b=0f2c5e1d-3b6a-4c1e-9f7d-1a2b3c4d5e6f

shells=(bash)
if busybox ash -c : 2>/dev/null; then
    shells+=("busybox ash")
fi

for shell in "${shells[@]}"; do
    check "$shell / one match among two disks" \
        "$(run_case "$shell" "$guid_b" "vda $guid_a" "vdb $guid_b")" xda=vdb
    check "$shell / MBR id matches without 0x, any case" \
        "$(run_case "$shell" 3677822a "sda 0x3677822A")" xda=sda
    check "$shell / no match" \
        "$(run_case "$shell" "$guid_b" "vda $guid_a")" aborted
    check "$shell / cloned disk with the same id" \
        "$(run_case "$shell" "$guid_a" "vda $guid_a" "vdb $guid_a")" aborted
    check "$shell / says which disks share the id" \
        "$(grep -c 'on both vda and vdb' "$work/log")" 1
done

if [ "$failures" != 0 ]; then
    echo "check_find_xda: $failures assertion(s) failed" >&2
    exit 1
fi
echo "check_find_xda: ok"
exit 0
