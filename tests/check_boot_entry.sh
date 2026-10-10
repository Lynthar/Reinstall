#!/bin/bash
# Runs install_boot_entry and undo_boot_changes from reinstall.sh down every boot path with
# the bootloader tools stubbed. The one-time boot entry must be set last: armed before a
# later write fails, the next reboot starts a half-written boot instead of the old system.
# Undo must put back every file the install changed, byte for byte, and only those.
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
for tool in awk basename cat cut dirname find grep head mkdir sed seq sort tail tee tr wc xargs; do
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
# Without arguments it lists $work/efi_list, the NVRAM state a case sets up.
stub efibootmgr "[ \$# -eq 0 ] && cat '$work/efi_list' 2>/dev/null
case \" \$* \" in *' --create-only '*) printf '%s\n' 'Boot0002* debian' 'Boot0003* reinstall (debian 13)' ;; esac
exit 0"
stub findmnt 'echo /dev/vda15'
stub lsblk 'printf "%s\n" "vda15 252:15 0 124M 0 part" "vda 252:0 0 10G 0 disk"'
stub update-grub ": grub-mkconfig -o $root/boot/grub/grub.cfg"
stub grub-mkconfig
# grub-reboot writes next_entry where grub-editenv reads it; GRUB_REBOOT_SILENT_FAIL makes it
# write nothing and still exit 0, as the real script does when grubenv is read-only.
stub grub-reboot "[ -z \"\${GRUB_REBOOT_SILENT_FAIL:-}\" ] && echo \"next_entry=\$1\" >'$work/grubenv'
exit 0"
# shellcheck disable=SC2016 # expands when the stub runs
stub grub-probe 'case "$*" in
*--target=fs*) echo "${PROBE_FS:-ext4}" ;;
*--target=abstraction*) echo "${PROBE_LAYERS:-}" ;;
esac'
# EDITENV_LIST adds a next_entry someone else set.
stub grub-editenv "case \$2 in
list) cat '$work/grubenv' 2>/dev/null; [ -n \"\${EDITENV_LIST:-}\" ] && echo \"\$EDITENV_LIST\" ;;
unset) rm -f '$work/grubenv' ;;
esac
exit 0"
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
# Removes only what lies in $work: the kernel files and the Windows paths stay logged.
stub rm "for a; do case \$a in -*) ;; $work/*) ;; *) exit 0 ;; esac; done
exec $(command -v rm) \"\$@\""
# A firmware entry and the win_bios entry, both ours, as bcdedit lists them.
# shellcheck disable=SC2016 # expands when the stub runs
stub bcdedit 'case "$*" in
"/enum bootmgr") printf "%s\n" "Windows Boot Manager" "identifier {bootmgr}" "" \
    "Firmware Application (101fffff)" "identifier {2b7f5d3a-0000-4000-8000-000000000001}" \
    "description reinstall (debian 13)" ;;
"/enum all") printf "%s\n" "identifier {1c41f649-1637-52f1-aea8-f96bfebeecc8}" ;;
esac'
stub cmd

# case.sh <firmware> <bios loader> <step>...: runs each step, a command line, in order.
cat >"$work/case.sh" <<CASE
set -eE
. "$work/fns.sh"
is_in_windows() { [ "\${WINDOWS:-}" = 1 ]; }
is_efi() { [ "\$firmware" = efi ]; }
is_mbr_using_grub() { [ "\$bios_loader" = grub ]; }
is_os_in_btrfs() { return 1; }
is_boot_in_separate_partition() { return 0; }
install_pkg() { :; }
# a vfat /boot holding no .efi file comes first, as /boot sorts before /efi
get_maybe_efi_dirs_in_linux() { printf '%s\n' "$root/boot" "$root/efi"; }
eval "real_\$(declare -f find_cfgs)"
find_cfgs() { real_find_cfgs "$root\$1" "\$2" "\$3"; }
PATH=$work/bin
basearch=x86_64 tmp=$work/tmp distro=debian releasever=13 c=c
cmdline="alpine_repo=r modloop=m extra_main_disk=d"
firmware=\$1 bios_loader=\$2
shift 2
for step; do eval "\$step"; done
CASE

fresh() {
    rm -rf "$root" "$work/tmp" "$work/efi_list" "$work/grubenv"
    : >"$work/calls"
    mkdir -p "$root/boot/grub" "$root/boot/extlinux" "$root/efi/EFI/ubuntu" "$work/tmp"
    : >"$root/efi/EFI/ubuntu/shimx64.efi"
    printf '%s\n' 'DEFAULT debian' 'MENU HIDDEN' 'TIMEOUT 50' 'LABEL debian' '  LINUX /vmlinuz' \
        >"$root/boot/extlinux/extlinux.conf"
}

# run <firmware> <bios loader> <step>...; sets $status, stderr lands in $work/err.
run() {
    status=0
    bash "$work/case.sh" "$@" >/dev/null 2>"$work/err" || status=$?
}

said() { grep -q -- "$1" "$work/err" && echo yes || echo no; }
called() { grep -q -- "$1" "$work/calls" && echo yes || echo no; }
has_line() { grep -qxF -- "$2" "$1" && echo yes || echo no; }
exists() { [ -e "$1" ] && echo yes || echo no; }

# Every directory and every file's checksum under $root.
snap() { (cd "$root" && find . -type d | sort && find . -type f -exec cksum {} + | sort); }
same_tree() {
    if [ "$(snap)" = "$1" ]; then
        echo yes
    else
        diff <(echo "$1") <(snap) >&2 || true
        echo no
    fi
}

entry='menuentry "reinstall (debian 13)" --unrestricted {'
kernel='    linux /reinstall-vmlinuz alpine_repo=r modloop=m extra_main_disk=d'
custom=$root/boot/grub/custom.cfg
conf=$root/boot/extlinux/extlinux.conf

echo "== linux efi =="
fresh
before=$(snap)
run efi '' install_boot_entry
check "exit status" "$status" 0
check "grub.efi goes to the partition holding .efi files" \
    "$(cd "$root/efi/EFI/reinstall" && echo *)" "grub.cfg grubx64.efi"
check "grub.cfg menu entry" "$(has_line "$root/efi/EFI/reinstall/grub.cfg" "$entry")" yes
check "grub.cfg kernel line" "$(has_line "$root/efi/EFI/reinstall/grub.cfg" "$kernel")" yes
check "last call" "$(tail -n1 "$work/calls")" "efibootmgr --bootnext 0003"

echo "== linux efi, undo =="
printf '%s\n' 'BootNext: 0003' 'Boot0002* debian' 'Boot0003* reinstall (debian 13)' >"$work/efi_list"
run efi '' undo_boot_changes
check "exit status" "$status" 0
check "tree as before" "$(same_tree "$before")" yes
check "BootNext deleted" "$(called 'efibootmgr --quiet --delete-bootnext')" yes
check "our entry deleted" "$(called 'efibootmgr --quiet --bootnum 0003 --delete-bootnum')" yes
check "other entry kept" "$(called 'bootnum 0002')" no
check "kernel files removed" "$(called 'rm -f /reinstall-vmlinuz /reinstall-initrd')" yes

echo "== linux efi, undo keeps a BootNext someone else set =="
printf '%s\n' 'BootNext: 0002' 'Boot0002* debian' 'Boot0003* reinstall (debian 13)' >"$work/efi_list"
: >"$work/calls"
run efi '' undo_boot_changes
check "exit status" "$status" 0
check "BootNext kept" "$(called delete-bootnext)" no
check "our entry deleted" "$(called 'efibootmgr --quiet --bootnum 0003 --delete-bootnum')" yes

echo "== linux efi, grub.cfg cannot be written =="
fresh
mkdir -p "$root/efi/EFI/reinstall/grub.cfg"
run efi '' install_boot_entry
check "exit status" "$status" 1
check "says grub.cfg is a directory" "$(said 'grub.cfg: Is a directory')" yes
check "BootNext set" "$(called --bootnext)" no

echo "== linux bios, grub =="
fresh
echo 'set user_setting=1' >"$custom"
before=$(snap)
run bios grub install_boot_entry
check "exit status" "$status" 0
check "custom.cfg menu entry" "$(has_line "$custom" "$entry")" yes
check "the user's custom.cfg line kept" "$(has_line "$custom" 'set user_setting=1')" yes
check "grub.cfg regenerated" "$(called update-grub)" yes
check "armed last" "$(tail -n2 "$work/calls" | head -n1)" "grub-reboot reinstall (debian 13)"
check "next_entry read back" "$(tail -n1 "$work/calls")" "grub-editenv - list"

echo "== linux bios, grub, undo =="
run bios grub undo_boot_changes
check "exit status" "$status" 0
check "tree as before" "$(same_tree "$before")" yes
check "next_entry cleared" "$(exists "$work/grubenv")" no
export EDITENV_LIST='next_entry=1'
: >"$work/calls"
run bios grub undo_boot_changes
check "a next_entry someone else set is kept" "$(called 'unset next_entry')" no
unset EDITENV_LIST

echo "== linux bios, grub, grub-reboot fails without saying so =="
fresh
export GRUB_REBOOT_SILENT_FAIL=1
run bios grub install_boot_entry
unset GRUB_REBOOT_SILENT_FAIL
check "exit status" "$status" 1
check "says next_entry was not set" "$(said 'grub-reboot did not set next_entry')" yes

echo "== linux bios, grub, a second run leaves one entry =="
fresh
run bios grub install_boot_entry undo_boot_changes install_boot_entry
check "exit status" "$status" 0
check "menu entries" "$(grep -c '^menuentry "reinstall' "$custom")" 1

echo "== linux bios, grub, undo removes a custom.cfg an old version wrote whole =="
fresh
printf '%s\n' 'set timeout=5' "$entry" '}' >"$custom"
mkdir "$root/boot/grub2"
echo 'set user_setting=1' >"$root/boot/grub2/custom.cfg"
run bios grub undo_boot_changes
check "exit status" "$status" 0
check "old custom.cfg removed" "$(exists "$custom")" no
check "custom.cfg without our entry kept" "$(cat "$root/boot/grub2/custom.cfg")" 'set user_setting=1'

echo "== linux bios, grub, custom.cfg cannot be written =="
fresh
mkdir -p "$custom"
run bios grub install_boot_entry
check "exit status" "$status" 1
check "says custom.cfg is a directory" "$(said 'custom.cfg: Is a directory')" yes
check "grub-reboot run" "$(called grub-reboot)" no

# Each reject case breaks one premise and checks that the refusal names it.
echo "== grubenv GRUB cannot write is refused =="
fresh
run bios grub assert_grubenv_writable
check "ext4 passes" "$status" 0
export PROBE_FS=btrfs
run bios grub assert_grubenv_writable
check "btrfs: exit status" "$status" 1
check "btrfs: says why" "$(said 'grubenv on btrfs')" yes
echo 'env_block=512+1' >"$root/boot/grub/grubenv"
run bios grub assert_grubenv_writable
check "btrfs with openSUSE's env_block passes" "$status" 0
unset PROBE_FS
export PROBE_LAYERS=lvm
run bios grub assert_grubenv_writable
check "lvm: exit status" "$status" 1
check "lvm: says why" "$(said 'grubenv through lvm')" yes
unset PROBE_LAYERS

echo "== linux bios, extlinux, separate /boot =="
fresh
before=$(snap)
run bios extlinux install_boot_entry
check "exit status" "$status" 0
check "extlinux.conf label" "$(has_line "$conf" 'LABEL reinstall')" yes
check "kernel beside extlinux.conf" "$(has_line "$conf" '  LINUX reinstall-vmlinuz')" yes
check "MENU HIDDEN set aside" "$(has_line "$conf" '# reinstall: MENU HIDDEN')" yes
check "kernel files copied" "$(called "cp -f /reinstall-vmlinuz /reinstall-initrd $root/boot/extlinux")" yes
check "last call" "$(tail -n1 "$work/calls")" "extlinux --once=reinstall $root/boot/extlinux"

echo "== linux bios, extlinux, undo =="
run bios extlinux undo_boot_changes
check "exit status" "$status" 0
check "tree as before" "$(same_tree "$before")" yes
check "once cleared" "$(called "extlinux --clear-once $root/boot/extlinux")" yes

echo "== linux bios, extlinux, kernel copy fails =="
fresh
export KERNEL_COPY_FAILS=1
run bios extlinux install_boot_entry
unset KERNEL_COPY_FAILS
check "exit status" "$status" 1
check "says no space left" "$(said 'No space left on device')" yes
check "extlinux --once run" "$(called 'extlinux --once')" no

echo "== kexec =="
printf '%s\n' '# Load a kexec kernel (true/false)' 'LOAD_KEXEC=true' >"$work/kexec"
cp "$work/kexec" "$work/kexec.orig"
run bios grub "disable_kexec_load $work/kexec"
check "disabled" "$(has_line "$work/kexec" 'LOAD_KEXEC=false # reinstall: was true')" yes
run bios grub "restore_kexec_load $work/kexec"
check "restored byte for byte" "$(cmp -s "$work/kexec" "$work/kexec.orig" && echo yes || echo no)" yes
echo 'LOAD_KEXEC=false' >"$work/kexec"
run bios grub "restore_kexec_load $work/kexec"
check "a false we did not set stays" "$(cat "$work/kexec")" 'LOAD_KEXEC=false'

echo "== windows, undo =="
fresh
export WINDOWS=1
run efi '' undo_boot_changes
check "efi: exit status" "$status" 0
check "efi: grub files removed" "$(called 'rm -f /cygdrive/c/grub.cfg /cygdrive/c/g2ldr')" yes
check "efi: bootsequence back to bootmgr" "$(called 'bcdedit /set {fwbootmgr} bootsequence {bootmgr}')" yes
check "efi: our entry deleted" \
    "$(called 'cmd /c bcdedit /delete {2b7f5d3a-0000-4000-8000-000000000001}')" yes
check "efi: Windows Boot Manager kept" "$(called 'delete {bootmgr}')" no
: >"$work/calls"
run bios '' undo_boot_changes
check "bios: exit status" "$status" 0
check "bios: our entry deleted" "$(called 'bcdedit /delete {1c41f649-1637-52f1-aea8-f96bfebeecc8}')" yes
unset WINDOWS

finish
