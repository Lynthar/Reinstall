#!/bin/bash
# Runs trans.sh's check_qcow_fits_disk, which stage 2 runs for debian before it wipes the
# disk: the qcow2's virtual disk, the partition the download goes into and 2 MiB must fit
# the target disk; an image whose header cannot be read is let through with a warning.
# bash, then busybox ash; the host's head / od / awk, then busybox's.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# trans.sh's collaborators, replaced. The disk is $DISK_BYTES, the server says the download
# is $FILE_BYTES (none when empty), and wget serves the file named by its URL. The names
# differ from the function's locals: a stub reads the caller's variables.
cat >"$work/stubs.sh" <<STUBS
warn() { echo "Warning: \$*"; }
error_and_exit() {
    printf '%s\n' "\$*" >"$work/reason"
    exit 1
}
get_disk_size() { echo "\$DISK_BYTES"; }
get_http_file_size() { [ -n "\$FILE_BYTES" ] && echo "\$FILE_BYTES"; }
STUBS
for fn in get_part_size_mb_for_file_size_b get_cloud_image_part_size get_qcow_virtual_size check_qcow_fits_disk; do
    extract_fn "$trans" $fn
done >"$work/fns.sh"

# trap_err stands in for trans.sh's ERR trap: a probe that fails must not trip it
cat >"$work/case.sh" <<CASE
set -eE
trap 'echo trapped >"$work/reason"; exit 1' ERR
. "$work/stubs.sh"
. "$work/fns.sh"
xda=vdz distro=debian releasever=13 img=\$1
check_qcow_fits_disk
CASE

mkdir "$work/bin" "$work/bb"
cat >"$work/bin/wget" <<'WGET'
#!/bin/sh
# the last argument is the URL; like the real server it sends more than the 32 bytes read
for url; do :; done
[ -f "$url" ] && cat "$url" "$url"
WGET
chmod +x "$work/bin/wget"

toolsets=(host)
if busybox awk 'BEGIN {}' 2>/dev/null && busybox od /dev/null >/dev/null 2>&1; then
    for t in head od awk; do
        ln -s "$(command -v busybox)" "$work/bb/$t"
    done
    toolsets+=(busybox)
fi

# header <file> <virtual size>: the first 32 bytes of a qcow2 image that size.
header() {
    local i oct=
    for i in 56 48 40 32 24 16 8 0; do
        oct+=$(printf '\\%03o' $((($2 >> i) & 255)))
    done
    # shellcheck disable=SC2059
    { printf 'QFI\373\0\0\0\3'; head -c 16 /dev/zero; printf "$oct"; } >"$1"
}

gib=$((1 << 30))
mib=$((1 << 20))
header "$work/debian.qcow2" $((3 * gib))
# a raw image where the qcow2 header should be
head -c 32 /dev/zero >"$work/raw.img"

# run <shell> <toolset> <image> <disk size> <file size>: passed or failed, the reason in reason.
run() {
    local path=$work/bin:$PATH
    [ "$2" = busybox ] && path=$work/bin:$work/bb:$PATH
    rm -f "$work/reason"
    # shellcheck disable=SC2086
    if PATH=$path DISK_BYTES=$4 FILE_BYTES=$5 $1 "$work/case.sh" "$3" >"$work/out" 2>&1; then
        status=passed
    else
        status=failed
    fi
}
reason() { cat "$work/reason" 2>/dev/null || echo none; }
said() { grep -qF -- "$1" "$work/out" && echo yes || echo no; }

# 400 MiB downloaded needs a 550 MiB partition: 3 GiB + 550 MiB + 2 MiB in all
need=$((3 * gib + 552 * mib))

for shell in "${shells[@]}"; do
    for tools in "${toolsets[@]}"; do
        echo "== $shell / $tools =="
        on="$shell / $tools"

        run "$shell" "$tools" "$work/debian.qcow2" $((4 * gib)) $((400 * mib))
        check "$on / room to spare: passes" "$status, $(reason)" "passed, none"
        check "$on / room to spare: says the sizes" \
            "$(said "a 3072 MiB disk, downloaded into a 550 MiB partition: $need of $((4 * gib)) bytes")" yes

        run "$shell" "$tools" "$work/debian.qcow2" "$need" $((400 * mib))
        check "$on / exactly enough: passes" "$status, $(reason)" "passed, none"

        run "$shell" "$tools" "$work/debian.qcow2" $((need - 1)) $((400 * mib))
        check "$on / one byte short: refused" "$status, $(reason)" \
            "failed, /dev/vdz is too small for debian 13: it needs $need bytes and has $((need - 1)). Install alpine instead, or use a bigger disk."

        # no Content-Length: the partition falls back to 2 GiB, which no longer fits
        run "$shell" "$tools" "$work/debian.qcow2" $((4 * gib)) ''
        check "$on / size unknown, 2 GiB partition: refused" "$status, $(reason)" \
            "failed, /dev/vdz is too small for debian 13: it needs $((5 * gib + 2 * mib)) bytes and has $((4 * gib)). Install alpine instead, or use a bigger disk."

        run "$shell" "$tools" "$work/raw.img" $((1 * gib)) $((400 * mib))
        check "$on / not a qcow2: let through" "$status, $(reason)" "passed, none"
        check "$on / not a qcow2: says so" "$(said "Could not read the image's virtual size")" yes

        run "$shell" "$tools" "$work/missing.qcow2" $((1 * gib)) $((400 * mib))
        check "$on / header unreachable: let through" "$status, $(reason)" "passed, none"
        check "$on / header unreachable: says so" "$(said "Could not read the image's virtual size")" yes
    done
done

finish
