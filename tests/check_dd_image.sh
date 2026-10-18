#!/bin/bash
# Runs stage 1's dd checks from reinstall.sh: --img takes only http(s), what stage 2's wget
# fetches; --cloud-init-network goes with dd alone; and the image's last partition must end
# inside the disk, the rule stage 2 also applies when the write runs past the disk's end.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
reinstall=$repo/reinstall.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

command -v parted >/dev/null || skip "needs parted"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# reinstall.sh's collaborators, replaced. The target disk is /dev/vdz and lsblk
# reports $disk_size for it; error_and_exit keeps the reason it was given in reason.
cat >"$work/stubs.sh" <<STUBS
error_and_exit() {
    printf '%s\n' "\$*" >"$work/reason"
    exit 1
}
is_in_windows() { false; }
find_main_disk() { xda=vdz; }
lsblk() { echo "\$disk_size"; }
STUBS
for fn in to_upper to_lower verify_os_args get_img_parts_end bytes_to_gib check_img_fits_disk; do
    extract_fn "$reinstall" $fn
done >"$work/fns.sh"

cat >"$work/case.sh" <<CASE
set -eE
. "$work/stubs.sh"
. "$work/fns.sh"
tmp=$work/tmp
case "\$1" in
args) distro=dd img=\$2 verify_os_args ;;
switch) distro=\$2 img=https://example.com/a.raw cloud_init_network=1 verify_os_args ;;
ends) get_img_parts_end "\$tmp/img-test" ;;
fits) disk_size=\$2 check_img_fits_disk ;;
esac
CASE
mkdir "$work/tmp"

# Toolsets: the host's od and awk, then busybox's in front of them on PATH.
toolsets=(host)
if busybox awk 'BEGIN {}' 2>/dev/null && busybox od /dev/null >/dev/null 2>&1; then
    mkdir "$work/bb"
    ln -s "$(command -v busybox)" "$work/bb/od"
    ln -s "$(command -v busybox)" "$work/bb/awk"
    toolsets+=(busybox)
fi

# run <toolset> <case args...>: exit status, stdout in out, reason in reason.
run() {
    local path=$PATH
    [ "$1" = busybox ] && path=$work/bb:$PATH
    shift
    rm -f "$work/reason"
    PATH=$path bash "$work/case.sh" "$@" >"$work/out" 2>&1
}

# image <name> <size> <parted commands...>: an image partitioned by parted, and the
# end of its last partition as parted lists it.
image() {
    local name=$1 size=$2
    shift 2
    truncate -s "$size" "$work/$name.img"
    parted -s "$work/$name.img" "$@"
    parted -sm "$work/$name.img" unit B print |
        awk -F: 'NR > 2 { sub("B", "", $3); if ($3 + 1 > m) m = $3 + 1 } END { print m }' >"$work/$name.end"
}

# use <image>: what stage 1 has of it, the first MiB.
use() {
    head -c 1048576 "$work/$1.img" >"$work/tmp/img-test"
}

# put_le <file> <offset> <bytes> <value>: writes <value> little-endian.
put_le() {
    local i hex=
    for ((i = 0; i < $3; i++)); do
        hex+=$(printf '\\x%02x' $((($4 >> (8 * i)) & 255)))
    done
    # shellcheck disable=SC2059
    printf "$hex" | dd of="$1" bs=1 seek="$2" conv=notrunc status=none
}

image mbr 64MiB mklabel msdos mkpart primary 1MiB 100%
image logical 64MiB mklabel msdos mkpart primary 1MiB 8MiB mkpart extended 8MiB 60MiB mkpart logical 9MiB 59MiB
# like a Debian cloud image: partition 1 is the last one on the disk; the image is
# larger than its partitions
image gpt 64MiB mklabel gpt mkpart root 32MiB 48MiB mkpart esp 1MiB 8MiB

# gpt with its header wiped: the MBR still says GPT
cp "$work/gpt.img" "$work/nohdr.img"
dd if=/dev/zero of="$work/nohdr.img" bs=512 seek=1 count=1 conv=notrunc status=none

# 4 KiB sectors: protective MBR, header at LBA 1, one entry at LBA 2 ending at LBA 4095
truncate -s 1MiB "$work/gpt4k.img"
put_le "$work/gpt4k.img" 446 1 0
put_le "$work/gpt4k.img" 450 1 238
put_le "$work/gpt4k.img" 454 4 1
put_le "$work/gpt4k.img" 458 4 4294967295
put_le "$work/gpt4k.img" 510 2 43605
printf 'EFI PART' | dd of="$work/gpt4k.img" bs=1 seek=4096 conv=notrunc status=none
put_le "$work/gpt4k.img" $((4096 + 72)) 8 2
put_le "$work/gpt4k.img" $((4096 + 80)) 4 128
put_le "$work/gpt4k.img" $((4096 + 84)) 4 128
put_le "$work/gpt4k.img" $((8192 + 0)) 8 1
put_le "$work/gpt4k.img" $((8192 + 32)) 8 256
put_le "$work/gpt4k.img" $((8192 + 40)) 8 4095
echo 16777216 >"$work/gpt4k.end"

# a boot sector with an empty partition table
truncate -s 1MiB "$work/empty.img"
put_le "$work/empty.img" 510 2 43605

said() { grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no; }
status() { "$@" && echo pass || echo fail; }

for t in "${toolsets[@]}"; do
    for name in mbr logical gpt gpt4k; do
        use $name
        want=$(<"$work/$name.end")
        table=gpt
        [[ $name = gpt* ]] || table=mbr
        run "$t" ends
        check "$t / $name: last partition end" "$(<"$work/out")" "$table $want"
        check "$t / $name: fits a disk of exactly that size" "$(status run "$t" fits "$want")" pass
        check "$t / $name: refused one sector short" "$(status run "$t" fits $((want - 512)))" fail
        check "$t / $name: reason gives both sizes" \
            "$(said "$work/reason" "at least $want bytes; /dev/vdz has $((want - 512))")" yes
    done

    # the partitions fit although the image is larger than the disk
    use gpt
    check "$t / gpt: image larger than the disk, partitions inside" "$(status run "$t" fits $((56 << 20)))" pass
    check "$t / gpt: says where they end" "$(said "$work/out" "GPT partitions end at")" yes

    use nohdr
    run "$t" ends
    check "$t / GPT header missing" "$(<"$work/out")" broken
    check "$t / GPT header missing: refused" "$(status run "$t" fits $((1 << 30)))" fail
    check "$t / GPT header missing: reason" "$(said "$work/reason" 'no GPT header')" yes

    use empty
    run "$t" ends
    check "$t / empty table" "$(<"$work/out")" none
    check "$t / empty table: not checked, not refused" "$(status run "$t" fits 1024)" pass
    check "$t / empty table: says so" "$(said "$work/out" 'No partitions found')" yes
done

for url in https://example.com/a.raw.xz HTTP://example.com/a.raw; do
    check "--img $url" "$(status run host args "$url")" pass
done
for url in file:///root/a.raw 'magnet:?xt=urn:btih:0000000000000000000000000000000000000000' ftp://example.com/a.raw; do
    check "--img $url" "$(status run host args "$url")" fail
    check "--img $url: reason" "$(said "$work/reason" '--img takes an http:// or https:// URL')" yes
done

check "--cloud-init-network with dd" "$(status run host switch dd)" pass
check "--cloud-init-network with alpine" "$(status run host switch alpine)" fail
check "--cloud-init-network with alpine: reason" "$(said "$work/reason" '--cloud-init-network only works with dd')" yes

finish
