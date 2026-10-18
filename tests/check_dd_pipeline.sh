#!/bin/bash
# Runs dd_raw_with_extract from trans.sh against a wget that fails part-way. A raw
# image passes through cat, whose exit status is all a plain pipeline reports, so a
# truncated download must still fail, and the reason it gives must be wget's own
# words: they go to the screen, not through pipe_extract. A sparse tar (Debian's
# tar.xz images are) must land on the disk byte for byte: the disk is seekable and
# not truncated, so the target here is a file full of 0xff opened the same way, and
# any hole tar skips instead of writing shows. Also runs under busybox ash when
# installed.
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
# Arguments: the wget mode, then optionally the image's wrapper and the image.
cat >"$work/case.sh" <<CASE
set -eE
. "$work/stubs.sh"
. "$work/fns.sh"
xda=stdout
img=https://mirror.invalid/image.raw
wget_mode=\$1
img_type_warp=\${2-}
image=\${3:-$work/image}
dd_raw_with_extract
CASE

# pipe_extract alone: the wrapper is $1, the archive on stdin.
cat >"$work/extract.sh" <<CASE
set -eE
. "$work/stubs.sh"
. "$work/fns.sh"
img_type_warp=\$1
pipe_extract
CASE

# 4 MiB with data at both ends and a hole between, archived as GNU sparse
truncate -s 4M "$work/sparse.raw"
printf 'start of the disk' | dd of="$work/sparse.raw" conv=notrunc status=none
printf 'end of the disk' | dd of="$work/sparse.raw" bs=1M seek=3 conv=notrunc status=none
tar -C "$work" --sparse -cf "$work/sparse.tar" sparse.raw
xz -k "$work/sparse.tar"
head -c 2048 "$work/sparse.tar" >"$work/cut.tar"

# onto_used_disk <shell command> <wrapper> <archive>: whether what pipe_extract
# leaves on a disk that held something else is the image.
onto_used_disk() {
    head -c 4M /dev/zero | tr '\0' '\377' >"$work/target"
    # shellcheck disable=SC2086
    $1 "$work/extract.sh" "$2" <"$3" 1<>"$work/target" 2>"$work/log"
    cmp -s "$work/target" "$work/sparse.raw" && echo identical || echo differs
}

# run_case <shell command> <wget mode> <expected pass|fail> [<wrapper> <image>]
run_case() {
    local shell=$1 mode=$2 want=$3 got
    shift 3
    rm -f "$work/reason"
    # shellcheck disable=SC2086
    if $shell "$work/case.sh" "$mode" "$@" >"$work/disk" 2>"$work/log"; then
        got=pass
    else
        got=fail
    fi
    check "$shell / wget $mode${1:+ / $1}" "$got" "$want"
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

    check "$shell / sparse tar: holes written" "$(onto_used_disk "$shell" tar "$work/sparse.tar")" identical
    check "$shell / sparse tar.xz: holes written" "$(onto_used_disk "$shell" tar.xz "$work/sparse.tar.xz")" identical
    # wget succeeds and tar fails behind cat: only pipefail reports it
    run_case "$shell" ok fail tar "$work/cut.tar"
    check "$shell / tar cut short: reason is tar's" "$(said "$work/reason" 'Unexpected EOF')" yes
done

finish
