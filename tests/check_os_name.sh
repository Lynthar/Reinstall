#!/bin/bash
# Runs stage 1's verify_os_name on the target names it should take and refuse. Without a
# version a target gets the newest one listed, except Ubuntu, which gets the newest LTS.
# check_ram then holds debian and ubuntu to 512 MiB, alpine and dd to 256.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

{
    cat <<STUBS
error() { printf '%s\n' "\$*" >"$work/reason"; }
error_and_exit() { printf '%s\n' "\$*" >"$work/reason"; exit 1; }
usage_and_exit() { exit 1; }
is_in_windows() { false; }
install_pkg() { :; }
lsmem() { echo "Total online memory: \$((ram_mib * 1024 * 1024))"; }
STUBS
    for fn in to_lower verify_os_name is_digit is_valid_ram_size check_ram; do
        extract_fn "$repo/reinstall.sh" $fn
    done
} >"$work/stage1.sh"

# parsed <words…>: "<distro> <releasever>", or "refused" when verify_os_name gives up
parsed() {
    rm -f "$work/reason"
    bash -c '. "$1"; shift; verify_os_name "$@"; echo "$distro $releasever"' _ "$work/stage1.sh" "$@" ||
        echo refused
}
said() { grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no; }
# ram <MiB> <target>: "ok", or "refused" when check_ram stops the install
ram() {
    rm -f "$work/reason"
    bash -c '. "$1"; ram_mib=$2; distro=$3; check_ram' _ "$work/stage1.sh" "$1" "$2" && echo ok ||
        echo refused
}

check "ubuntu takes the newest LTS, not 26.10" "$(parsed ubuntu)" "ubuntu 26.04"
check "debian takes the newest" "$(parsed debian)" "debian 13"
check "alpine takes the newest" "$(parsed alpine)" "alpine 3.24"
check "dd has no version" "$(parsed dd)" "dd "

check "ubuntu 26.10 named" "$(parsed ubuntu 26.10)" "ubuntu 26.10"
check "ubuntu-26.10" "$(parsed ubuntu-26.10)" "ubuntu 26.10"
check "Ubuntu:24.04" "$(parsed Ubuntu:24.04)" "ubuntu 24.04"
check "debian 10" "$(parsed debian 10)" "debian 10"

check "ubuntu 25.10, not listed" "$(parsed ubuntu 25.10)" refused
check "ubuntu 25.10: reason" "$(said "$work/reason" 'Please specify a proper os')" yes

check "debian at 512 MiB" "$(ram 512 debian)" ok
check "debian at 511 MiB" "$(ram 511 debian)" refused
check "debian at 511 MiB: reason" "$(said "$work/reason" 'Could not install debian: RAM < 512 MB.')" yes
check "ubuntu at 448 MiB" "$(ram 448 ubuntu)" refused
check "ubuntu at 448 MiB: reason" "$(said "$work/reason" 'Could not install ubuntu: RAM < 512 MB.')" yes
check "alpine at 256 MiB" "$(ram 256 alpine)" ok
check "dd at 256 MiB" "$(ram 256 dd)" ok
check "alpine at 255 MiB" "$(ram 255 alpine)" refused
check "alpine at 255 MiB: reason" "$(said "$work/reason" 'Could not install alpine: RAM < 256 MB.')" yes

finish
