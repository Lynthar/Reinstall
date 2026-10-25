#!/bin/bash
# Runs trans.sh's vendor quirks against a stubbed sysfs. On Tencent Cloud a virtio
# disk taking requests over 512 KiB fails heavy writes, so the Live OS limits it
# before the first write and the installed system keeps the limit; a disk that
# refuses the value must not stop the install, and other vendors are left alone.
# On Azure an NVMe disk behind Hyper-V's virtual PCI bus needs pci-hyperv in the
# installed alpine's initramfs, or it boots without finding its root.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
sys=$work/sys
os=$work/os

{
    for fn in warn insert_into_file get_drivers is_tencent_cloud limit_tencent_disk_requests \
        persist_tencent_disk_limit add_pci_hyperv_to_initramfs_if_needed; do
        extract_fn "$trans" "$fn"
    done
} | sed -e "s|/sys/class/|$sys/class/|" -e "s|/sys/block/vd|$sys/block/vd|" -e "s|/sys/block/\\\$xda|$sys/block/\$xda|" \
    -e "s|/os/|$os/|g" -e "s|chroot /os |chroot $os |" >"$work/fns.sh"

cat >"$work/case.sh" <<CASE
set -eE
. "$work/fns.sh"
info() { echo "info \$*"; }
error_and_exit() { echo "error: \$*"; exit 1; }
chroot() { echo "chroot \$*" >>"$work/chroot"; }
distro=\$2
xda=\$3
case \$1 in
live) limit_tencent_disk_requests ;;
persist) persist_tencent_disk_limit "$os" ;;
drivers) get_drivers "$sys/block/\$xda" ;;
hyperv) add_pci_hyperv_to_initramfs_if_needed ;;
esac
echo "end"
CASE

# disk <name> <device dir under sys/devices>: a disk with max_sectors_kb at 4096
disk() {
    mkdir -p "$sys/devices/$2/$1/queue" "$sys/block"
    echo 4096 >"$sys/devices/$2/$1/queue/max_sectors_kb"
    ln -s "$sys/devices/$2/$1" "$sys/block/$1"
}

# bind <device dir under sys/devices> <bus> <driver> [module]
bind() {
    mkdir -p "$sys/bus/$2/drivers/$3"
    ln -s "$sys/bus/$2/drivers/$3" "$sys/devices/$1/driver"
    if [ -n "${4-}" ]; then
        mkdir -p "$sys/module/$4"
        ln -s "$sys/module/$4" "$sys/bus/$2/drivers/$3/module"
    fi
}

# fixture <sys_vendor or "none">: three disks and, unless none, a DMI vendor
fixture() {
    rm -rf "$sys" "$os" "$work/chroot"
    disk vda pci0000:00/0000:00:04.0/virtio1/block
    disk vdb pci0000:00/0000:00:05.0/virtio2/block
    disk sda pci0000:00/0000:00:06.0/host0/target0:0:0/0:0:0:0/block
    if [ "$1" != none ]; then
        mkdir -p "$sys/class/dmi/id"
        echo "$1" >"$sys/class/dmi/id/sys_vendor"
    fi
    mkdir -p "$os/etc/udev/rules.d" "$os/etc/mkinitfs/features.d" "$os/lib/modules/6.18.58-0-virt"
    printf 'sd[a-z].*\troot:disk 0660 */lib/mdev/persistent-storage\nvd[a-z].*\troot:disk 0660 */lib/mdev/persistent-storage\n' \
        >"$os/etc/mdev.conf"
    cp "$os/etc/mdev.conf" "$work/mdev.conf.orig"
    echo 'features="ata base ext4 nvme virtio"' >"$os/etc/mkinitfs/mkinitfs.conf"
}

# azure: an NVMe disk on a Hyper-V virtual PCI bus, the bus driver given as <driver> [module]
azure() {
    local bus=LNXSYSTM:00/VMBUS:00/f8b3781b-1e82-4818-a1c3-63d806ec15bb
    local nvme=$bus/pci1e82:00/1e82:00:00.0
    disk nvme0n1 "$nvme/nvme/nvme0"
    bind "$bus" vmbus "$@"
    bind "$nvme" pci nvme nvme
}

# run_case <shell command> <case> <distro> [xda]: sets out
run_case() {
    # shellcheck disable=SC2086
    out=$($1 "$work/case.sh" "$2" "$3" "${4-}" 2>&1) || out="$out (exit $?)"
}

kb() { cat "$sys/block/$1/queue/max_sectors_kb"; }
has() { grep -qF -- "$2" <<<"$1" && echo yes || echo no; }
chroot_calls() { cat "$work/chroot" 2>/dev/null || echo none; }

rule='SUBSYSTEM=="block", KERNEL=="vd*[a-z]", ACTION=="add|change", ATTR{queue/max_sectors_kb}="512"'
# shellcheck disable=SC2016
mdev_line='-vd[a-z]+ root:disk 0660 @echo 512 >/sys/block/$MDEV/queue/max_sectors_kb'

for shell in "${shells[@]}"; do
    echo "== $shell: the Live OS before the first write =="
    fixture 'Tencent Cloud'
    run_case "$shell" live debian
    check "$shell / Tencent: vda" "$(kb vda)" 512
    check "$shell / Tencent: vdb" "$(kb vdb)" 512
    check "$shell / Tencent: a non-virtio disk is left alone" "$(kb sda)" 4096
    check "$shell / Tencent: says what it found and did" "$(has "$out" "Tencent Cloud (DMI sys_vendor): limiting virtio disks")" yes
    check "$shell / Tencent: debian gets no dd warning" "$(has "$out" "dd image")" no

    fixture 'Tencent Cloud'
    run_case "$shell" live dd
    check "$shell / Tencent dd: the disk is limited" "$(kb vda)" 512
    check "$shell / Tencent dd: says the image is not touched" "$(has "$out" "The dd image is written as is")" yes

    fixture 'Tencent Cloud'
    rm "$sys/block/vdb/queue/max_sectors_kb"
    mkdir "$sys/block/vdb/queue/max_sectors_kb"
    run_case "$shell" live debian
    check "$shell / a disk that refuses 512 is named" "$(has "$out" "Could not set $sys/block/vdb/queue/max_sectors_kb")" yes
    check "$shell / ... and the install goes on" "$(tail -n 1 <<<"$out")" end
    check "$shell / ... with the other disk limited" "$(kb vda)" 512

    fixture QEMU
    run_case "$shell" live debian
    check "$shell / another vendor: untouched" "$(kb vda)" 4096
    check "$shell / another vendor: silent" "$out" end

    fixture none
    run_case "$shell" live debian
    check "$shell / no DMI: untouched" "$(kb vda)" 4096

    echo "== $shell: the installed system =="
    fixture 'Tencent Cloud'
    run_case "$shell" persist debian
    check "$shell / Tencent debian: the udev rule" "$(cat "$os/etc/udev/rules.d/80-max-sectors-blk.rules")" "$rule"
    check "$shell / Tencent debian: the initramfs is rebuilt" "$(chroot_calls)" "chroot $os update-initramfs -u -k all"

    fixture 'Tencent Cloud'
    run_case "$shell" persist alpine
    check "$shell / Tencent alpine: the mdev line comes first" "$(head -n 1 "$os/etc/mdev.conf")" "$mdev_line"
    check "$shell / Tencent alpine: the rest of mdev.conf is unchanged" \
        "$(tail -n +2 "$os/etc/mdev.conf" | cmp -s - "$work/mdev.conf.orig" && echo same)" same
    check "$shell / Tencent alpine: no udev rule" "$(ls "$os/etc/udev/rules.d")" ""
    check "$shell / Tencent alpine: no rebuild" "$(chroot_calls)" none

    fixture QEMU
    run_case "$shell" persist debian
    check "$shell / another vendor: no udev rule" "$(ls "$os/etc/udev/rules.d")" ""
    check "$shell / another vendor: no rebuild" "$(chroot_calls)" none

    echo "== $shell: Azure NVMe behind Hyper-V's virtual PCI bus =="
    fixture QEMU
    azure hv_pci pci_hyperv
    run_case "$shell" drivers alpine nvme0n1
    check "$shell / drivers from the disk up" "$(head -n 2 <<<"$out" | paste -sd ' ' -)" "nvme pci_hyperv"
    run_case "$shell" hyperv alpine nvme0n1
    check "$shell / the module joins the initramfs features" \
        "$(cat "$os/etc/mkinitfs/features.d/pci-hyperv.modules")" 'kernel/drivers/pci/controller/pci-hyperv.ko*'
    check "$shell / ... and the features line" "$(cat "$os/etc/mkinitfs/mkinitfs.conf")" 'features="ata base ext4 nvme virtio pci-hyperv"'
    check "$shell / ... for the installed kernel" "$(chroot_calls)" "chroot $os mkinitfs -k 6.18.58-0-virt"
    check "$shell / says what it found and did" "$(has "$out" "Azure: the disk sits behind")" yes

    fixture QEMU
    azure hv_pci
    run_case "$shell" drivers alpine nvme0n1
    check "$shell / a built-in driver is listed by its own name" "$(head -n 2 <<<"$out" | paste -sd ' ' -)" "nvme hv_pci"
    run_case "$shell" hyperv alpine nvme0n1
    check "$shell / built in: the initramfs is left alone" "$(chroot_calls)" none

    fixture QEMU
    bind pci0000:00/0000:00:04.0/virtio1 virtio virtio_blk virtio_blk
    bind pci0000:00/0000:00:04.0 pci virtio-pci virtio_pci
    run_case "$shell" hyperv alpine vda
    check "$shell / a virtio disk: the initramfs is left alone" "$(chroot_calls)" none
    check "$shell / a virtio disk: no features file" "$(ls "$os/etc/mkinitfs/features.d")" ""
done

finish
