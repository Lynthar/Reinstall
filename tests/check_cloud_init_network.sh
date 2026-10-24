#!/bin/bash
# Runs trans.sh's warn_static_network and create_cloud_init_network_v2 (also the netplan file of
# ubuntu and debian 12 / 13) on stubbed probes: /dev/netconf, an rdisc6 answer, resolv.conf. It is
# all the system learns of this network: match NICs by MAC without renaming them, routes on-link.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
trans=$repo/trans.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# trans.sh's collaborators, replaced. ip answers the one question the probes ask it
# (does the NIC hold a global IPv6 address) from $work/v6addr.
cat >"$work/stubs.sh" <<STUBS
info() { :; }
warn() { echo "Warning: \$*" >&2; }
apk() { :; }
rdisc6() { cat "$work/ra"; }
ip() { case "\$*" in *"-6 -o addr show scope global"*) cat "$work/v6addr" ;; esac; }
TRUE=0
FALSE=1
STUBS
for fn in get_eths get_netconf_to get_ra_to show_netconf get_current_dns \
    is_dhcpv4 is_staticv4 is_staticv6 is_dhcpv6_or_slaac is_ipv4_has_internet is_ipv6_has_internet \
    should_disable_dhcpv4 should_disable_accept_ra should_disable_autoconf is_slaac is_dhcpv6 \
    is_have_ipv6 is_enable_other_flag is_have_rdnss is_need_manual_set_dnsv6 \
    create_cloud_init_network_v2 create_netplan_config warn_static_network; do
    extract_fn "$trans" "$fn"
done | sed -e "s|/dev/netconf|$work/netconf|g" -e "s|/etc/resolv.conf|$work/resolv.conf|g" \
    -e "s|/tmp/network-config|$work/tmp-network-config|g" >"$work/fns.sh"

cat >"$work/case.sh" <<CASE
set -eE
. "$work/stubs.sh"
. "$work/fns.sh"
case "\$1" in
config) create_cloud_init_network_v2 "$work/network-config" ;;
netplan) create_netplan_config "$work/50-cloud-init.yaml" ;;
warn) cloud_init_network=\$2 warn_static_network ;;
esac
CASE

printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\n' >"$work/resolv.conf"

# netconf <nic> <mac> <key=value>...: what initrd-network.sh wrote for one NIC; unset
# flags are 0. The first call of a case clears the NICs of the previous one.
netconf() {
    local nic=$1 key
    [ "$nic" = eth1 ] || rm -rf "$work/netconf"
    mkdir -p "$work/netconf/$nic"
    for key in dhcpv4 dhcpv6_or_slaac should_disable_dhcpv4 should_disable_accept_ra \
        should_disable_autoconf ipv4_has_internet ipv6_has_internet; do
        echo 0 >"$work/netconf/$nic/$key"
    done
    for key in ipv4_addr ipv4_gateway ipv6_addr ipv6_gateway; do
        : >"$work/netconf/$nic/$key"
    done
    echo "$2" >"$work/netconf/$nic/mac_addr"
    shift 2
    for key in "$@"; do
        echo "${key#*=}" >"$work/netconf/$nic/${key%%=*}"
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

# expect <label> <shell> <expected network-config>
expect() {
    local got
    # shellcheck disable=SC2086
    if $2 "$work/case.sh" config >/dev/null 2>"$work/log"; then
        got=$(cat "$work/network-config")
    else
        cat "$work/log" >&2
        got="exited non-zero"
    fi
    check "$2 / $1" "$got" "$(sed '1{/^$/d;}' <<<"$3")"
}

# warned <shell> <cloud_init_network>: what warn_static_network printed.
warned() {
    # shellcheck disable=SC2086
    { $1 "$work/case.sh" warn "$2" >/dev/null; } 2>&1 || echo "exited non-zero"
}

for shell in "${shells[@]}"; do
    # a /48 with a gateway outside it, as on a machine seen in the field
    netconf eth0 00:d4:06:4b:10:3e ipv4_has_internet=1 ipv6_has_internet=1 \
        ipv4_addr=45.145.75.78/24 ipv4_gateway=45.145.75.1 \
        ipv6_addr=2604:9cc0:1ca8::a/48 ipv6_gateway=2604:9cc0:f::1
    : >"$work/v6addr"
    expect "static ipv4 + ipv6 with an off-link gateway" "$shell" '
version: 2
ethernets:
  eth0:
    match:
      macaddress: "00:d4:06:4b:10:3e"
    addresses:
      - "45.145.75.78/24"
      - "2604:9cc0:1ca8::a/48"
    routes:
      - to: "0.0.0.0/0"
        via: "45.145.75.1"
        on-link: true
      - to: "::/0"
        via: "2604:9cc0:f::1"
        on-link: true
    nameservers:
      addresses:
        - "1.1.1.1"
        - "8.8.8.8"
        - "2606:4700:4700::1111"'
    w=$(warned "$shell" "")
    check "$shell / warning names the ipv4 address" "$(grep -cF 'eth0 IPv4 45.145.75.78/24 via 45.145.75.1' <<<"$w")" 1
    check "$shell / warning names the ipv6 address" "$(grep -cF 'eth0 IPv6 2604:9cc0:1ca8::a/48 via 2604:9cc0:f::1' <<<"$w")" 1
    check "$shell / switch off: warning points at it" "$(grep -cF -- '--cloud-init-network writes them' <<<"$w")" 1
    check "$shell / switch on: warning says so" "$(warned "$shell" 1 | grep -cF -- '--cloud-init-network is on')" 1

    netconf eth0 00:20:14:63:c1:08 dhcpv4=1 ipv4_has_internet=1 ipv6_has_internet=1 \
        ipv6_addr=2406:ef80:4:ffb4::1/64 ipv6_gateway=fe80::1
    expect "dhcp4 + static ipv6 behind a link-local gateway" "$shell" '
version: 2
ethernets:
  eth0:
    match:
      macaddress: "00:20:14:63:c1:08"
    dhcp4: true
    addresses:
      - "2406:ef80:4:ffb4::1/64"
    routes:
      - to: "::/0"
        via: "fe80::1"
        on-link: true
    nameservers:
      addresses:
        - "2606:4700:4700::1111"'
    w=$(warned "$shell" "")
    check "$shell / dhcp4 + static ipv6: only ipv6 is named" \
        "$(grep -c 'IPv4' <<<"$w"),$(grep -cF 'eth0 IPv6 2406:ef80:4:ffb4::1/64 via fe80::1' <<<"$w")" 0,1

    netconf eth0 52:54:00:12:34:56 dhcpv4=1 dhcpv6_or_slaac=1 ipv4_has_internet=1 ipv6_has_internet=1
    ra Yes No No 2606:4700:4700::1111
    # cloud-init writes every dynamic IPv6 type as dhcp6 when it turns v1 into netplan
    expect "dhcp4 + slaac with rdnss" "$shell" '
version: 2
ethernets:
  eth0:
    match:
      macaddress: "52:54:00:12:34:56"
    dhcp4: true
    dhcp6: true'
    check "$shell / dhcp4 + slaac: no warning" "$(warned "$shell" "")" ""

    ra No Yes No
    echo "2: eth0    inet6 2001:db8::5/128 scope global dynamic" >"$work/v6addr"
    expect "dhcp4 + dhcpv6" "$shell" '
version: 2
ethernets:
  eth0:
    match:
      macaddress: "52:54:00:12:34:56"
    dhcp4: true
    dhcp6: true'
    : >"$work/v6addr"

    netconf eth0 52:54:00:12:34:56 dhcpv6_or_slaac=1 should_disable_accept_ra=1 should_disable_autoconf=1 \
        ipv6_has_internet=1 ipv6_addr=2001:db8::10/64 ipv6_gateway=2001:db8::1
    ra Yes No No
    expect "slaac address replaced by the old static one, ra off" "$shell" '
version: 2
ethernets:
  eth0:
    match:
      macaddress: "52:54:00:12:34:56"
    accept-ra: false
    addresses:
      - "2001:db8::10/64"
    routes:
      - to: "::/0"
        via: "2001:db8::1"
        on-link: true
    nameservers:
      addresses:
        - "2606:4700:4700::1111"'

    netconf eth0 52:54:00:00:00:01 ipv4_has_internet=1 ipv4_addr=203.0.113.10/24 ipv4_gateway=203.0.113.1
    netconf eth1 52:54:00:00:00:02 dhcpv4=1 ipv4_has_internet=1
    expect "two nics, each matched by its own mac" "$shell" '
version: 2
ethernets:
  eth0:
    match:
      macaddress: "52:54:00:00:00:01"
    addresses:
      - "203.0.113.10/24"
    routes:
      - to: "0.0.0.0/0"
        via: "203.0.113.1"
        on-link: true
    nameservers:
      addresses:
        - "1.1.1.1"
        - "8.8.8.8"
  eth1:
    match:
      macaddress: "52:54:00:00:00:02"
    dhcp4: true'
    check "$shell / no set-name anywhere" "$(grep -c set-name "$work/network-config" || true)" 0

    # ubuntu's netplan file: the same config one level down under network:, readable by root only
    rm -f "$work/50-cloud-init.yaml"
    # shellcheck disable=SC2086
    $shell "$work/case.sh" netplan >/dev/null 2>"$work/log" || cat "$work/log" >&2
    check "$shell / netplan file nests the config under network:" \
        "$(sed 1d "$work/50-cloud-init.yaml" | sed 's/^  //')" "$(cat "$work/network-config")"
    check "$shell / netplan file: first line" "$(head -1 "$work/50-cloud-init.yaml")" "network:"
    check "$shell / netplan file: mode" "$(stat -c %a "$work/50-cloud-init.yaml")" 600
done

finish
