#!/bin/bash
# Runs dd_raw_with_extract from trans.sh against a wget that fails part-way. A raw
# image passes through cat, whose exit status is all a plain pipeline reports, so a
# truncated download must still fail, and the reason it gives must be wget's own
# words: they go to the screen, not through pipe_extract. Also runs under busybox
# ash when installed.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# trans.sh's collaborators, replaced. wget plays the download end of the pipe: "ok"
# streams the whole image; "truncate" draws a progress bar, stops after 8 bytes and
# exits 4 (GNU wget: network failure); "missing" writes nothing and exits 8 (server
# error, e.g. 404). error_and_exit keeps the reason it was given in reason.
cat >"$work/stubs.sh" <<STUBS
info() { :; }
apk() { :; }
begin_disk_write() { :; }
error_and_exit() {
    printf '%s\n' "\$*" >"$work/reason"
    exit 1
}
wget() {
    case "\$wget_mode" in
    ok) cat "\$image" ;;
    truncate)
        printf ' 10%%[=>      ]\r 40%%[===>   ]\r' >&2
        head -c 8 "\$image"
        echo "Read error at byte 8 (Connection reset by peer). Giving up." >&2
        return 4
        ;;
    missing)
        echo "ERROR 404: Not Found." >&2
        return 8
        ;;
    esac
}
STUBS
extract_fn "$trans" pipe_extract >"$work/fns.sh"
extract_fn "$trans" dd_raw_with_extract >>"$work/fns.sh"
printf 'raw image bytes, all of them' >"$work/image"

# The target disk is /dev/$xda; /dev/stdout lets the harness capture what was written.
cat >"$work/case.sh" <<CASE
set -eE
. "$work/stubs.sh"
. "$work/fns.sh"
xda=stdout
img=https://mirror.invalid/image.raw
img_type_warp=
image=$work/image
wget_mode=\$1
dd_raw_with_extract
CASE

# run_case <shell command> <wget mode> <expected pass|fail>
run_case() {
    local shell=$1 mode=$2 want=$3 got
    rm -f "$work/reason"
    # shellcheck disable=SC2086
    if $shell "$work/case.sh" "$mode" >"$work/disk" 2>"$work/log"; then
        got=pass
    else
        got=fail
    fi
    check "$shell / wget $mode" "$got" "$want"
}

said() { grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no; }

for shell in "${shells[@]}"; do
    run_case "$shell" ok pass
    check "$shell / image written whole" "$(cmp -s "$work/disk" "$work/image" && echo yes || echo no)" yes
    run_case "$shell" truncate fail
    check "$shell / wget truncate: reason is wget's" "$(said "$work/reason" 'Giving up.')" yes
    check "$shell / wget truncate: wget still on screen" "$(said "$work/log" 'Giving up.')" yes
    run_case "$shell" missing fail
    check "$shell / wget missing: reason is wget's" "$(said "$work/reason" 'ERROR 404: Not Found.')" yes
done

finish
