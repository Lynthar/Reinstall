#!/bin/bash
# Runs --hostname through both stages: stage 1's check of the name and its refusal with dd,
# then trans.sh's set_hostname on a stub root. Without the option only a Debian image with no
# name of its own gets one; a given name goes into /etc/hostname cut to its first label.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# stage 1, with error_and_exit keeping the reason it was given in reason
{
    cat <<STUBS
error_and_exit() {
    printf '%s\n' "\$*" >"$work/reason"
    exit 1
}
STUBS
    for fn in to_lower is_hostname_valid verify_os_args; do
        extract_fn "$repo/reinstall.sh" $fn
    done
} >"$work/stage1.sh"

valid() { bash -c '. "$1"; is_hostname_valid "$2"' _ "$work/stage1.sh" "$1" && echo pass || echo fail; }
os_args() {
    rm -f "$work/reason"
    bash -c '. "$1"; distro=$2 img=https://example.com/a.raw hostname=web verify_os_args' _ "$work/stage1.sh" "$1" &&
        echo pass || echo fail
}
said() { grep -qF -- "$2" "$1" 2>/dev/null && echo yes || echo no; }

l63=$(printf 'a%.0s' $(seq 63))
for name in web1 web-1.example.com a "$l63" "$l63.$l63.$l63.${l63:2}"; do
    check "valid ${name:0:20}… (${#name})" "$(valid "$name")" pass
done
check "leading hyphen" "$(valid -web)" fail
check "trailing hyphen" "$(valid web-)" fail
check "underscore" "$(valid we_b)" fail
check "upper case (stage 1 lowers it first)" "$(valid Web)" fail
check "64-character label" "$(valid "${l63}a")" fail
check "empty label" "$(valid a..b)" fail
check "trailing dot" "$(valid web.)" fail
check "254 characters" "$(valid "$l63.$l63.$l63.${l63:1}")" fail

check "--hostname with debian" "$(os_args debian)" pass
check "--hostname with dd" "$(os_args dd)" fail
check "--hostname with dd: reason" "$(said "$work/reason" '--hostname does not work with dd')" yes

# stage 2: set_hostname <root> with $distro and $hostname from the command line
extract_fn "$repo/trans.sh" set_hostname >"$work/fns.sh"
cat >"$work/case.sh" <<CASE
set -eE
. "$work/fns.sh"
distro=\$1
hostname=\$2
set_hostname "$work/root"
CASE

# root <hostname file content, or - for none> <extra hosts line, may be empty>
root() {
    rm -rf "$work/root"
    mkdir -p "$work/root/etc"
    [ "$1" = - ] || printf '%b' "$1" >"$work/root/etc/hostname"
    printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' >"$work/root/etc/hosts"
    [ -z "$2" ] || printf '%b\n' "$2" >>"$work/root/etc/hosts"
}
# result: the name file (or "none") | every 127.0.x.1 line of hosts
result() {
    local name=none
    [ -f "$work/root/etc/hostname" ] && name=$(cat "$work/root/etc/hostname")
    echo "$name | $(grep '^127\.0\.[01]\.1' "$work/root/etc/hosts" | paste -sd, -)"
}

for shell in "${shells[@]}"; do
    root "" ""
    $shell "$work/case.sh" debian ""
    check "$shell / debian with an empty name file gets debian" "$(result)" \
        "debian | $(printf '127.0.0.1\tlocalhost,127.0.1.1\tdebian')"

    root '\n' ""
    $shell "$work/case.sh" debian ""
    check "$shell / a name file with only a newline counts as empty" "$(result)" \
        "debian | $(printf '127.0.0.1\tlocalhost,127.0.1.1\tdebian')"

    root 'debian\n' ""
    $shell "$work/case.sh" debian ""
    check "$shell / debian keeps the name its image has" "$(result)" "debian | $(printf '127.0.0.1\tlocalhost')"

    root 'ubuntu\n' ""
    $shell "$work/case.sh" ubuntu ""
    check "$shell / ubuntu without the option is left alone" "$(result)" "ubuntu | $(printf '127.0.0.1\tlocalhost')"

    root - ""
    $shell "$work/case.sh" alpine ""
    check "$shell / alpine without the option is left alone" "$(result)" "none | $(printf '127.0.0.1\tlocalhost')"

    root 'debian\n' '127.0.1.1\tdebian'
    $shell "$work/case.sh" debian web1.example.com
    check "$shell / a full name: first label, both in hosts, the old 127.0.1.1 line gone" "$(result)" \
        "web1 | $(printf '127.0.0.1\tlocalhost,127.0.1.1\tweb1.example.com web1')"

    root - ""
    $shell "$work/case.sh" alpine box
    check "$shell / alpine with the option" "$(result)" "box | $(printf '127.0.0.1\tlocalhost,127.0.1.1\tbox')"
done

finish
