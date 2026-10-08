#!/bin/bash
# Runs create_part against loop devices and checks the partition roles against the
# numbers install_qcow_by_copy hard-codes (1 = efi, 2 = os, 3 = installer) and the
# "installer" label dd_qcow relies on. Needs root, loop devices and parted; else SKIP.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"


[ "$(id -u)" = 0 ] || skip "not root"
[ -e /dev/loop-control ] || skip "no loop devices"
for cmd in losetup parted partprobe blkid mkfs.ext4 mkfs.fat truncate; do
    command -v "$cmd" >/dev/null || skip "missing $cmd"
done

harness=$(mktemp -d)
trap 'losetup -d "${dev:-}" 2>/dev/null || true; rm -rf "$harness"' EXIT

# Faked inputs: the real part size asks the mirror for a Content-Length, and the
# real update_part drives Alpine's mdev. Neither is what is under test.
cat >"$harness/create_part.sh" <<'STUBS'
info() { echo "  create_part: $*"; }
apk() { :; }
get_cloud_image_part_size() { echo "$fake_part_size"; }
update_part() {
    sync
    partprobe "/dev/$xda" >/dev/null 2>&1 || true
    # The kernel publishes the partition nodes asynchronously; the next mkfs
    # globs for them, and an unmatched glob would silently format nothing.
    for n in $(parted -ms "/dev/$xda" print 2>/dev/null | awk -F: 'NR > 2 {print $1}'); do
        i=0
        while ! [ -e "/dev/${xda}p$n" ] && [ "$i" -lt 40 ]; do
            sleep 0.25
            i=$((i + 1))
        done
    done
}
STUBS
for fn in is_efi is_use_cloud_image get_disk_size is_xda_gt_2t create_part; do
    extract_fn "$trans" "$fn" >>"$harness/create_part.sh"
done

# The table is read from the image file, not the loop device: parted opens a device
# for writing, and udev answers that close by re-reading the partition table, which
# drops the partition nodes the label checks below are about to probe.
# parted -ms fields: num:start:end:size:fs:name:flags
part_field() { parted -ms "$harness/disk.img" print | awk -F: -v n="$1" -v f="$2" '$1 == n {sub(/;$/, "", $f); print $f}'; }
table_format() { parted -ms "$harness/disk.img" print | awk -F: 'NR == 2 {print $6}'; }
# -p probes the device instead of trusting the blkid cache, which outlives the
# loop device number and would answer for the previous case's partition table.
part_label() { blkid -p -s LABEL -o value "$1" 2>/dev/null || true; }
part_fstype() { blkid -p -s TYPE -o value "$1" 2>/dev/null || true; }

# 3 TiB is sparse: only the installer partition at the far end is ever written.
run_case() {
    export distro=$2 force_boot_mode=$3
    export cloud_image=1 fake_part_size=1GiB

    echo "== $1 =="
    truncate -s "$4" "$harness/disk.img"
    dev=$(losetup -f --show -P "$harness/disk.img")
    export xda=${dev#/dev/}

    # shellcheck disable=SC1091
    if ! (. "$harness/create_part.sh" && create_part) >"$harness/log" 2>&1; then
        cat "$harness/log" >&2
        echo "    FAIL create_part exited non-zero" >&2
        failures=$((failures + 1))
    fi
    # mkfs closing the device makes udev re-read the table; read labels only once it settles.
    udevadm settle 2>/dev/null || true
}

end_case() {
    losetup -d "$dev"
    rm -f "$harness/disk.img"
}

for boot_mode in efi bios; do
    run_case "ubuntu / $boot_mode / 8 GiB" ubuntu "$boot_mode" 8G
    check "partition table" "$(table_format)" gpt
    check "p3 label" "$(part_label "${dev}p3")" installer
    check "p3 filesystem" "$(part_fstype "${dev}p3")" ext4
    check "p2 left to the target's mkfs" "$(part_fstype "${dev}p2")" ""
    if [ "$boot_mode" = efi ]; then
        check "p1 filesystem" "$(part_fstype "${dev}p1")" vfat
        check "p1 label" "$(part_label "${dev}p1")" efi
        check "p1 size" "$(part_field 1 4)" 105MB
    else
        check "p1 flags" "$(part_field 1 7)" bios_grub
        check "p1 size" "$(part_field 1 4)" 1049kB
    fi
    end_case
done

run_case "ubuntu / bios / 3 TiB" ubuntu bios 3T
check "partition table" "$(table_format)" gpt
check "p3 label" "$(part_label "${dev}p3")" installer
check "p2 left to the target's mkfs" "$(part_fstype "${dev}p2")" ""
check "p1 flags" "$(part_field 1 7)" bios_grub
end_case

for boot_mode in efi bios; do
    run_case "debian / $boot_mode / 8 GiB" debian "$boot_mode" 8G
    check "partition table" "$(table_format)" gpt
    check "p1 label" "$(part_label "${dev}p1")" os
    check "p2 label" "$(part_label "${dev}p2")" installer
    check "no third partition" "$(part_field 3 1)" ""
    end_case
done

finish
