#!/bin/bash
# Runs create_ifupdown_config from trans.sh on stubbed probe results: /dev/netconf as
# initrd-network.sh leaves it, an rdisc6 answer and resolv.conf. The file it writes is
# the only network config alpine and debian get, so a wrong stanza means no network.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# trans.sh's collaborators, replaced. ip answers the one question create_ifupdown_config
# asks it (does the NIC hold a global IPv6 address) from $work/v6addr.
cat >"$work/stubs.sh" <<STUBS
info() { :; }
apk() { :; }
rdisc6() { cat "$work/ra"; }
ip() { case "\$*" in *"-6 -o addr show scope global"*) cat "$work/v6addr" ;; esac; }
TRUE=0
FALSE=1
STUBS
for fn in get_eths get_netconf_to get_ra_to show_netconf get_current_dns is_distro_like_debian \
    is_dhcpv4 is_staticv4 is_staticv6 is_dhcpv6_or_slaac is_ipv4_has_internet is_ipv6_has_internet \
    should_disable_dhcpv4 should_disable_accept_ra should_disable_autoconf is_slaac is_dhcpv6 \
    is_have_ipv6 is_enable_other_flag is_have_rdnss is_need_manual_set_dnsv6 create_ifupdown_config; do
    extract_fn "$trans" "$fn"
done | sed -e "s|/dev/netconf|$work/netconf|g" -e "s|/etc/resolv.conf|$work/resolv.conf|g" >"$work/fns.sh"

cat >"$work/case.sh" <<CASE
set -eE
. "$work/stubs.sh"
. "$work/fns.sh"
distro=\$1
releasever=\$2
create_ifupdown_config "$work/interfaces"
CASE

printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\n' >"$work/resolv.conf"

# netconf <key=value>...: what initrd-network.sh wrote for eth0; unset flags are 0.
netconf() {
    rm -rf "$work/netconf"
    mkdir -p "$work/netconf/eth0"
    local key
    for key in dhcpv4 dhcpv6_or_slaac should_disable_dhcpv4 should_disable_accept_ra \
        should_disable_autoconf ipv4_has_internet ipv6_has_internet; do
        echo 0 >"$work/netconf/eth0/$key"
    done
    for key in ipv4_addr ipv4_gateway ipv6_addr ipv6_gateway; do
        : >"$work/netconf/eth0/$key"
    done
    echo 52:54:00:12:34:56 >"$work/netconf/eth0/mac_addr"
    for key in "$@"; do
        echo "${key#*=}" >"$work/netconf/eth0/${key%%=*}"
    done
}

# ra <autonomous> <stateful address> <stateful other> [rdnss]: the rdisc6 answer.
ra() {
    {
        echo " Stateful address conf.    :           $2"
        echo " Stateful other conf.      :           $3"
        echo " Autonomous address conf.  :           $1"
        if [ -n "${4:-}" ]; then echo " Recursive DNS server     : $4"; fi
    } >"$work/ra"
}

# expect <label> <shell> <distro> <release> <expected lines after "iface lo inet loopback">;
# both sides are compared with their lines joined by " | ".
expect() {
    local label=$1 shell=$2 want got
    want=$(sed '/^$/d' <<<"$5" | paste -sd'|' - | sed 's/|/ | /g')
    # shellcheck disable=SC2086
    if $shell "$work/case.sh" "$3" "$4" >/dev/null 2>"$work/log"; then
        got=$(sed '1,/^iface lo inet loopback$/d; /^$/d' "$work/interfaces" | paste -sd'|' - | sed 's/|/ | /g')
    else
        cat "$work/log" >&2
        got="exited non-zero"
    fi
    check "$shell / $label" "$got" "$want"
}

for shell in "${shells[@]}"; do
    netconf dhcpv4=1 dhcpv6_or_slaac=1 ipv4_has_internet=1 ipv6_has_internet=1
    ra Yes No No 2606:4700:4700::1111
    : >"$work/v6addr"
    expect "dhcp4 + slaac with rdnss" "$shell" debian 12 "
# mac 52:54:00:12:34:56
auto eth0
iface eth0 inet dhcp
iface eth0 inet6 auto"
    check "$shell / debian sources interfaces.d" "$(head -1 "$work/interfaces")" "source /etc/network/interfaces.d/*"
    expect "alpine gets no interfaces.d line" "$shell" alpine 3.23 "
# mac 52:54:00:12:34:56
auto eth0
iface eth0 inet dhcp
iface eth0 inet6 auto"
    check "$shell / alpine starts at lo" "$(head -1 "$work/interfaces")" "auto lo"

    netconf ipv4_addr=203.0.113.10/24 ipv4_gateway=203.0.113.1 ipv4_has_internet=1
    expect "static ipv4 takes the live ipv4 resolvers" "$shell" debian 12 "
# mac 52:54:00:12:34:56
auto eth0
iface eth0 inet static
    address 203.0.113.10/24
    gateway 203.0.113.1
    dns-nameservers 1.1.1.1
    dns-nameservers 8.8.8.8"

    netconf dhcpv4=1 dhcpv6_or_slaac=1 ipv4_has_internet=1 ipv6_has_internet=1
    ra No Yes No
    echo "2: eth0    inet6 2001:db8::5/128 scope global dynamic" >"$work/v6addr"
    expect "dhcpv6 on debian 12" "$shell" debian 12 "
# mac 52:54:00:12:34:56
auto eth0
iface eth0 inet dhcp
iface eth0 inet6 dhcp"
    expect "dhcpv6 on debian 13 uses auto" "$shell" debian 13 "
# mac 52:54:00:12:34:56
auto eth0
iface eth0 inet dhcp
iface eth0 inet6 auto"
    : >"$work/v6addr"
    expect "dhcpv6 flag without an address is not dhcpv6" "$shell" debian 12 "
# mac 52:54:00:12:34:56
auto eth0
iface eth0 inet dhcp"

    netconf dhcpv6_or_slaac=1 should_disable_accept_ra=1 should_disable_autoconf=1 ipv6_has_internet=1 \
        ipv6_addr=2001:db8::10/64 ipv6_gateway=2001:db8::1
    ra Yes No No
    expect "slaac address replaced by the old static one" "$shell" debian 12 "
# mac 52:54:00:12:34:56
auto eth0
iface eth0 inet6 static
    address 2001:db8::10/64
    gateway 2001:db8::1
    dns-nameserver 2606:4700:4700::1111
    accept_ra 0
    autoconf 0"
    expect "alpine turns ra and autoconf off with pre-up" "$shell" alpine 3.23 "
# mac 52:54:00:12:34:56
auto eth0
iface eth0 inet6 static
    address 2001:db8::10/64
    gateway 2001:db8::1
    dns-nameserver 2606:4700:4700::1111
    pre-up echo 0 >/proc/sys/net/ipv6/conf/eth0/accept_ra
    pre-up echo 0 >/proc/sys/net/ipv6/conf/eth0/autoconf"

    netconf dhcpv4=1 dhcpv6_or_slaac=1 ipv6_has_internet=1
    ra Yes No No 2606:4700:4700::1111
    expect "ipv4 without internet gets no stanza" "$shell" debian 12 "
# mac 52:54:00:12:34:56
auto eth0
iface eth0 inet6 auto"
done

finish
