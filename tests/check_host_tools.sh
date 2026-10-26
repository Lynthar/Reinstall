#!/bin/bash
# Runs install_pkg's is_need_reinstall from reinstall.sh on stand-in tools. On an Alpine host
# busybox's fdisk, grep, lsblk and tar lack what stage 1 asks of them (an MBR disk id, -oP,
# -rn --inverse, GNU sparse tar), so each is swapped for the full tool; the full ones, and
# busybox's on a host without apk, are left alone.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
reinstall=$repo/reinstall.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

base=/usr/bin:/bin:/usr/sbin:/sbin
busybox=$(command -v busybox) || skip "no busybox"
if PATH=$base command -v apk >/dev/null; then
    skip "an Alpine host, whose own tools may be busybox's"
fi
bash=$(command -v bash)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for fn in get_cmd_path is_have_cmd is_need_reinstall; do
    extract_fn "$reinstall" "$fn"
done >"$work/fns.sh"

mkdir "$work/apk" "$work/busybox"
printf '#!/bin/sh\n' >"$work/apk/apk"
for tool in fdisk grep tar; do
    ln -s "$busybox" "$work/busybox/$tool"
done
# busybox 1.38's lsblk, which this busybox may not have: called bare it lists the disks,
# and only --help prints the usage that names BusyBox.
cat >"$work/busybox/lsblk" <<'LSBLK'
#!/bin/sh
if [ "$1" = --help ]; then
    printf '%s\n' 'BusyBox v1.38.0 multi-call binary.' '' 'Usage: lsblk [BLOCKDEV]...' >&2
    exit 0
fi
printf '%s\n' 'NAME MAJ:MIN RM SIZE RO TYPE MOUNTPOINTS' 'vda  253:0    0  10G  0 disk'
LSBLK
chmod +x "$work/apk/apk" "$work/busybox/lsblk"

# swapped <PATH> <tool>: yes when is_need_reinstall wants the full tool.
swapped() {
    # shellcheck disable=SC2016 # expands in the inner bash
    PATH=$1 "$bash" -c '. "$0"; is_need_reinstall "$1" >/dev/null && echo yes || echo no' \
        "$work/fns.sh" "$2"
}

for tool in fdisk grep lsblk tar; do
    check "alpine host, busybox $tool" "$(swapped "$work/apk:$work/busybox:$base" $tool)" yes
    check "no apk, busybox $tool" "$(swapped "$work/busybox:$base" $tool)" no
    if PATH=$base command -v $tool >/dev/null; then
        check "alpine host, full $tool" "$(swapped "$work/apk:$base" $tool)" no
    fi
done

finish
