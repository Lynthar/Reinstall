#!/bin/bash
# Runs install_boot_entry from reinstall.sh down the three Linux boot paths with the
# bootloader tools stubbed. The one-time boot entry must be set last: armed before a
# later write fails, the next reboot starts a half-written boot instead of the old system.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
reinstall=$repo/reinstall.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root=$work/root

# Prints "<function>\t<code|doc>\t<line>" for every line of reinstall.sh; <function> is
# empty at top level, and "doc" marks a here-doc body, whose "}" must not end a function.
label_lines() {
    awk '
        doc != "" {
            print fn "\tdoc\t" $0
            probe = $0
            sub(/^[\t ]+/, "", probe)
            if (probe == doc) doc = ""
            next
        }
        fn == "" && /^[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ { fn = substr($0, 1, index($0, "(") - 1) }
        { print fn "\tcode\t" $0 }
        fn != "" && $0 == "}" { fn = "" }
        !/^[[:space:]]*#/ && /<<-?[ ]*['"'"'"]?[A-Za-z_]/ && !/<<</ {
            doc = $0
            sub(/.*<<-?[ ]*['"'"'"]?/, "", doc)
            sub(/[^A-Za-z0-9_].*/, "", doc)
        }
    ' "$reinstall"
}

echo "== only arm_boot_* sets a one-time boot =="
armed=$(label_lines | awk -F'\t' '
    $2 == "code" && $3 !~ /^[[:space:]]*#/ &&
        $3 ~ /--bootnext|bootsequence[[:space:]]+[^[:space:]'"'"']|grub2?-reboot|extlinux[[:space:]]+--once/ {
        print ($1 == "" ? "(top level)" : $1)
    }' | sort -u | paste -sd' ' -)
check "functions that arm" "$armed" \
    "arm_boot_linux_efi arm_boot_linux_extlinux arm_boot_linux_grub arm_boot_win_bios arm_boot_win_efi"

# Every function of reinstall.sh and none of its top-level code.
label_lines | awk -F'\t' '$1 != ""' | cut -f3- >"$work/fns.sh"

# Stubs log their arguments to $work/calls. PATH holds nothing else besides the plain
# tools linked below, so no real bootloader tool on this machine is ever reached.
mkdir "$work/bin"
for tool in awk basename cut dirname find grep head mkdir sed seq sort tail tee tr wc; do
    ln -s "$(command -v "$tool")" "$work/bin/$tool"
done

# stub <name> [shell body run after logging]
stub() {
    cat >"$work/bin/$1" <<STUB
#!/bin/sh
printf '%s\n' "$1 \$*" >>"$work/calls"
${2:-}
STUB
    chmod +x "$work/bin/$1"
}
# shellcheck disable=SC2016 # expands when the stub runs
stub curl 'while [ $# -gt 0 ]; do [ "$1" = -Lo ] && echo efi >"$2"; shift; done'
stub efibootmgr 'case " $* " in *" --create-only "*) printf "%s\n" "Boot0002* debian" "Boot0003* reinstall (debian 13)" ;; esac'
stub findmnt 'echo /dev/vda15'
stub lsblk 'printf "%s\n" "vda15 252:15 0 124M 0 part" "vda 252:0 0 10G 0 disk"'
stub update-grub ": grub-mkconfig -o $root/boot/grub/grub.cfg"
stub grub-mkconfig
stub grub-reboot
stub update-extlinux
stub extlinux
# The kernel files sit in / on a real host, so only their copy is faked.
stub cp "case \"\$*\" in
'-f /reinstall-vmlinuz /reinstall-initrd '*)
    [ -z \"\$KERNEL_COPY_FAILS\" ] && exit 0
    echo 'cp: error writing: No space left on device' >&2
    exit 1 ;;
esac
exec $(command -v cp) \"\$@\""

cat >"$work/case.sh" <<CASE
set -eE
. "$work/fns.sh"
is_in_windows() { return 1; }
is_efi() { [ "\$firmware" = efi ]; }
is_mbr_using_grub() { [ "\$bios_loader" = grub ]; }
is_os_in_btrfs() { return 1; }
is_boot_in_separate_partition() { return 0; }
install_pkg() { :; }
# a vfat /boot holding no .efi file comes first, as /boot sorts before /efi
get_maybe_efi_dirs_in_linux() { printf '%s\n' "$root/boot" "$root/efi"; }
eval "real_\$(declare -f find_grub_extlinux_cfg)"
find_grub_extlinux_cfg() { real_find_grub_extlinux_cfg "$root\$1" "\$2" "\$3"; }
PATH=$work/bin
basearch=x86_64 tmp=$work/tmp distro=debian releasever=13
cmdline="alpine_repo=r modloop=m extra_main_disk=d"
firmware=\$1 bios_loader=\$2
install_boot_entry
CASE

reset() {
    rm -rf "$root" "$work/tmp"
    : >"$work/calls"
    mkdir -p "$root/boot/grub" "$root/boot/extlinux" "$root/efi/EFI/ubuntu" "$work/tmp"
    : >"$root/efi/EFI/ubuntu/shimx64.efi"
    printf '%s\n' 'DEFAULT debian' 'MENU HIDDEN' 'TIMEOUT 50' 'LABEL debian' '  LINUX /vmlinuz' \
        >"$root/boot/extlinux/extlinux.conf"
}

# run <firmware> <bios loader>; sets $status, stderr lands in $work/err.
run() {
    status=0
    bash "$work/case.sh" "$1" "$2" >/dev/null 2>"$work/err" || status=$?
}

said() { grep -q -- "$1" "$work/err" && echo yes || echo no; }
called() { grep -q -- "$1" "$work/calls" && echo yes || echo no; }
has_line() { grep -qxF -- "$2" "$1" && echo yes || echo no; }

entry='menuentry "reinstall (debian 13)" --unrestricted {'
kernel='    linux /reinstall-vmlinuz alpine_repo=r modloop=m extra_main_disk=d'

echo "== linux efi =="
reset
run efi ''
check "exit status" "$status" 0
check "grub.efi goes to the partition holding .efi files" \
    "$(cd "$root/efi/EFI/reinstall" && echo *)" "grub.cfg grubx64.efi"
check "grub.cfg menu entry" "$(has_line "$root/efi/EFI/reinstall/grub.cfg" "$entry")" yes
check "grub.cfg kernel line" "$(has_line "$root/efi/EFI/reinstall/grub.cfg" "$kernel")" yes
check "last call" "$(tail -n1 "$work/calls")" "efibootmgr --bootnext 0003"

echo "== linux efi, grub.cfg cannot be written =="
reset
mkdir -p "$root/efi/EFI/reinstall/grub.cfg"
run efi ''
check "exit status" "$status" 1
check "says grub.cfg is a directory" "$(said 'grub.cfg: Is a directory')" yes
check "BootNext set" "$(called --bootnext)" no

echo "== linux bios, grub =="
reset
run bios grub
check "exit status" "$status" 0
check "custom.cfg menu entry" "$(has_line "$root/boot/grub/custom.cfg" "$entry")" yes
check "grub.cfg regenerated" "$(called update-grub)" yes
check "last call" "$(tail -n1 "$work/calls")" "grub-reboot reinstall (debian 13)"

echo "== linux bios, grub, custom.cfg cannot be written =="
reset
mkdir -p "$root/boot/grub/custom.cfg"
run bios grub
check "exit status" "$status" 1
check "says custom.cfg is a directory" "$(said 'custom.cfg: Is a directory')" yes
check "grub-reboot run" "$(called grub-reboot)" no

echo "== linux bios, extlinux, separate /boot =="
reset
run bios extlinux
conf=$root/boot/extlinux/extlinux.conf
check "exit status" "$status" 0
check "extlinux.conf label" "$(has_line "$conf" 'LABEL reinstall')" yes
check "kernel beside extlinux.conf" "$(has_line "$conf" '  LINUX reinstall-vmlinuz')" yes
check "kernel files copied" "$(called "cp -f /reinstall-vmlinuz /reinstall-initrd $root/boot/extlinux")" yes
check "last call" "$(tail -n1 "$work/calls")" "extlinux --once=reinstall $root/boot/extlinux"

echo "== linux bios, extlinux, kernel copy fails =="
reset
export KERNEL_COPY_FAILS=1
run bios extlinux
unset KERNEL_COPY_FAILS
check "exit status" "$status" 1
check "says no space left" "$(said 'No space left on device')" yes
check "extlinux --once run" "$(called 'extlinux --once')" no

finish
