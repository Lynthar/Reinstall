#!/bin/bash
# Runs trans.sh's write_cloud_init_seed against loop devices: the seed goes onto the root with
# cloud-init on ext4, xfs or btrfs (a subvolume too); otherwise it says why and writes nothing.
# Needs root, loop devices, the mkfs tools and Alpine's lsblk (Ubuntu's asks udev); else SKIP.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

[ "$(id -u)" = 0 ] || skip "not root"
[ -e /dev/loop-control ] || skip "no loop devices"
for cmd in losetup parted partprobe lsblk mkfs.ext4 mkfs.xfs mkfs.btrfs btrfs mkfs.fat pvcreate truncate; do
    command -v "$cmd" >/dev/null || skip "missing $cmd"
done

work=$(mktemp -d)
devs=()
trap 'umount "$work/mnt" "$work/os" 2>/dev/null || true
for d in "${devs[@]}"; do losetup -d "$d" 2>/dev/null || true; done
rm -rf "$work"' EXIT
mkdir "$work/mnt"

# trans.sh's collaborators, replaced. The network-config is create_cloud_init_network_v2's
# business and has its own harness; error_and_exit keeps its reason.
cat >"$work/stubs.sh" <<STUBS
info() { :; }
warn() { echo "Warning: \$*" >&2; }
error_and_exit() {
    printf '%s\n' "\$*" >"$work/reason"
    exit 1
}
create_cloud_init_network_v2() { echo "stub network-config" >"\$1"; }
STUBS
for fn in is_have_cmd_on_disk find_cloud_init_root write_cloud_init_seed; do
    extract_fn "$trans" "$fn"
done | sed "s| /os| $work/os|g" >"$work/fns.sh"

cat >"$work/case.sh" <<CASE
set -eE
. "$work/stubs.sh"
. "$work/fns.sh"
write_cloud_init_seed
CASE

# disk <name> <parted mkpart args...>: a fresh sparse image on a loop device, as xda.
disk() {
    local img=$work/$1.img n i
    shift
    truncate -s $((1 << 30)) "$img"
    parted -s "$img" mklabel gpt "$@"
    dev=$(losetup -f --show -P "$img")
    devs+=("$dev")
    for n in $(parted -ms "$img" print | awk -F: 'NR > 2 {print $1}'); do
        i=0
        while ! [ -e "${dev}p$n" ] && [ "$i" -lt 40 ]; do
            sleep 0.25
            i=$((i + 1))
        done
    done
}

# root_on <part> [dir]: the bits of a system with cloud-init installed, on <part> or in <dir> there.
root_on() {
    local d=$work/mnt/${2:-}
    mount "$1" "$work/mnt"
    mkdir -p "$d/etc/cloud" "$d/usr/bin"
    ln -s usr/bin "$d/bin"
    : >"$d/usr/bin/cloud-init"
    chmod +x "$d/usr/bin/cloud-init"
    umount "$work/mnt"
}

# run <shell>: write_cloud_init_seed on xda; its status, warnings in log, reason in reason.
run() {
    rm -f "$work/reason"
    # shellcheck disable=SC2086
    if xda=${dev#/dev/} $1 "$work/case.sh" >"$work/log" 2>&1; then
        status=pass
    else
        status=fail
    fi
}

said() { grep -qF -- "$1" "$work/log" && echo yes || echo no; }
mounted() { grep -qF " $work/os " /proc/mounts && echo yes || echo no; }

# seed_of <part> [subdir]: the seed files on <part>, or "none".
seed_of() {
    local d=$work/mnt/${2:-}/var/lib/cloud/seed/nocloud
    mount -o ro "$1" "$work/mnt"
    if [ -d "$d" ]; then
        printf '%s | %s | %s' "$(sed 's/[0-9][0-9]*$/N/' "$d/meta-data")" "$(paste -sd' ' "$d/user-data")" "$(cat "$d/network-config")"
    else
        echo none
    fi
    umount "$work/mnt"
}

written="instance-id: reinstall-N | #cloud-config {} | stub network-config"

# with <part> <commands...>: run commands with <part> mounted on mnt.
with() {
    mount "$1" "$work/mnt"
    shift
    "$@"
    umount "$work/mnt"
}

disk probe mkpart a 1MiB 100%
mkfs.ext4 -q "${dev}p1"
[ "$(lsblk -dno FSTYPE "${dev}p1")" = ext4 ] || skip "lsblk does not see filesystem types here (it reads them from udev)"
losetup -d "$dev"

for shell in "${shells[@]}"; do
    echo "== $shell =="

    disk ext4 mkpart root 1MiB 100%
    mkfs.ext4 -q "${dev}p1"
    root_on "${dev}p1"
    run "$shell"
    check "$shell / ext4 root: written" "$status, $(seed_of "${dev}p1")" "pass, $written"
    check "$shell / ext4 root: unmounted afterwards" "$(mounted)" no
    check "$shell / ext4 root: no cidata notice" "$(said 'labelled cidata')" no

    # a separate /boot first, the root on xfs behind it
    disk xfs mkpart boot 1MiB 200MiB mkpart root 200MiB 100%
    mkfs.ext4 -q "${dev}p1"
    mkfs.xfs -q "${dev}p2"
    root_on "${dev}p2"
    run "$shell"
    check "$shell / xfs root behind /boot: written" "$status, $(seed_of "${dev}p2")" "pass, $written"
    check "$shell / xfs root behind /boot: /boot untouched" "$(seed_of "${dev}p1")" none

    # the root in a subvolume, as Fedora lays it out
    disk btrfs mkpart root 1MiB 100%
    mkfs.btrfs -q "${dev}p1" >/dev/null
    with "${dev}p1" btrfs subvolume create "$work/mnt/root" >/dev/null
    root_on "${dev}p1" root
    run "$shell"
    check "$shell / btrfs root subvolume: written there" "$status, $(seed_of "${dev}p1" root)" "pass, $written"

    disk nocloud mkpart root 1MiB 100%
    mkfs.ext4 -q "${dev}p1"
    with "${dev}p1" mkdir -p "$work/mnt/etc" "$work/mnt/usr/bin"
    run "$shell"
    check "$shell / no cloud-init: nothing written" "$status, $(seed_of "${dev}p1")" "pass, none"
    check "$shell / no cloud-init: says so" "$(said 'No cloud-init found')" yes

    disk lvm mkpart boot 1MiB 200MiB mkpart pv 200MiB 100%
    mkfs.ext4 -q "${dev}p1"
    pvcreate -ff -y "${dev}p2" >/dev/null 2>&1
    run "$shell"
    check "$shell / root on lvm: nothing written" "$status, $(seed_of "${dev}p1")" "pass, none"
    check "$shell / root on lvm: says so" "$(said "${dev}p2 (LVM2_member)")" yes

    disk disabled mkpart root 1MiB 100%
    mkfs.ext4 -q "${dev}p1"
    root_on "${dev}p1"
    with "${dev}p1" touch "$work/mnt/etc/cloud/cloud-init.disabled"
    run "$shell"
    check "$shell / cloud-init disabled: nothing written" "$status, $(seed_of "${dev}p1")" "pass, none"
    check "$shell / cloud-init disabled: says so" "$(said 'cloud-init is disabled in the image')" yes

    disk seeded mkpart root 1MiB 100%
    mkfs.ext4 -q "${dev}p1"
    root_on "${dev}p1"
    with "${dev}p1" mkdir -p "$work/mnt/var/lib/cloud/seed/nocloud-net"
    with "${dev}p1" sh -c "echo 'instance-id: theirs' >'$work/mnt/var/lib/cloud/seed/nocloud-net/meta-data'"
    run "$shell"
    check "$shell / image has its own seed: nothing written" "$status, $(seed_of "${dev}p1")" "pass, none"
    check "$shell / image has its own seed: theirs kept" \
        "$(with "${dev}p1" cat "$work/mnt/var/lib/cloud/seed/nocloud-net/meta-data")" "instance-id: theirs"
    check "$shell / image has its own seed: says so" "$(said 'already carries a NoCloud seed')" yes

    disk var mkpart root 1MiB 100%
    mkfs.ext4 -q "${dev}p1"
    root_on "${dev}p1"
    with "${dev}p1" sh -c "echo 'LABEL=var /var ext4 defaults 0 2' >'$work/mnt/etc/fstab'"
    run "$shell"
    check "$shell / separate /var: nothing written" "$status, $(seed_of "${dev}p1")" "pass, none"
    check "$shell / separate /var: says so" "$(said 'mounts /var separately')" yes

    # a provider's seed disk next to the target
    disk cidata mkpart seed 1MiB 100%
    mkfs.fat -n CIDATA "${dev}p1" >/dev/null
    cidata=${dev}p1
    disk withcidata mkpart root 1MiB 100%
    mkfs.ext4 -q "${dev}p1"
    root_on "${dev}p1"
    run "$shell"
    check "$shell / cidata attached: written" "$status, $(seed_of "${dev}p1")" "pass, $written"
    check "$shell / cidata attached: says it wins" "$(said "labelled cidata is attached ($cidata)")" yes

    for d in "${devs[@]}"; do losetup -d "$d" 2>/dev/null || true; done
    devs=()
    rm -f "$work"/*.img
done

finish
