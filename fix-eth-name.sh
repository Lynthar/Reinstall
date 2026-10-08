#!/usr/bin/env bash
# shellcheck shell=dash
# shellcheck disable=SC3001,SC3010
# alpine 使用 busybox ash

set -eE

# openeuler 需等待 udev 将网卡名从 eth0 改为 enp3s0
sleep 10
# 不知道有没有用
if command -v udevadm >/dev/null; then
    # udevadm trigger
    udevadm settle
elif command -v mdev >/dev/null; then
    mdev -sf
fi

# 本脚本在首次进入新系统后运行
# 将 trans 阶段生成的网络配置中的网卡名(eth0) 改为正确的网卡名，也适用于以下情况
# 1. alpine 要运行此脚本，因为安装后的内核可能有 netboot 没有的驱动
# 2. dmit debian 普通内核(安装时)和云内核网卡名不一致
#    https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=928923

# todo: 删除 cloud-init

to_lower() {
    tr '[:upper:]' '[:lower:]'
}

retry() {
    local max_try=$1
    shift

    for i in $(seq "$max_try"); do
        if "$@"; then
            return
        else
            ret=$?
            if [ "$i" -ge "$max_try" ]; then
                return $ret
            fi
            sleep 1
        fi
    done
}

# openeuler 本脚本运行一秒后才有 enp3s0
# 用 systemd-analyze plot >a.svg 发现 sys-subsystem-net-devices-enp3s0.device 也是出现在 NetworkManager 之后
# 因此需要等待网卡出现
get_ethx_by_mac() {
    retry 10 _get_ethx_by_mac "$@"
}

_get_ethx_by_mac() {
    mac=$(echo "$1" | to_lower)

    if true; then
        # 过滤 azure vf (带 master ethx)
        ip -o link | grep -i "$mac" | grep -v master | awk '{print $2}' | cut -d: -f1 | grep .
    else
        for i in $(cd /sys/class/net && echo *); do
            if [ "$(cat "/sys/class/net/$i/address")" = "$mac" ] &&
                [ $(($(cat "/sys/class/net/$i/flags") & 0x800)) -eq 0 ]; then
                echo "$i"
                return
            fi
        done
        return 1
    fi
}

# auto lo
# iface lo inet loopback

# # mac 11:22:33:44:55:66    # 用此行匹配网卡
# auto eth0
# iface eth0 inet static
#     address 1.1.1.1/25
#     gateway 1.1.1.1
#     dns-nameservers 1.1.1.1
#     dns-nameservers 8.8.8.8
# iface eth0 inet6 static
#     address 2602:1:0:80::100/64
#     gateway 2602:1:0:80::1
#     dns-nameserver 2606:4700:4700::1111
#     dns-nameserver 2001:4860:4860::8888

fix_ifupdown() {
    file=/etc/network/interfaces
    tmp_file=$file.tmp

    rm -f "$tmp_file"

    if [ -f "$file" ]; then
        while IFS= read -r line; do
            del_this_line=false
            if [[ "$line" = "# mac "* ]]; then
                ethx=
                if mac=$(echo "$line" | awk '{print $NF}'); then
                    ethx=$(get_ethx_by_mac "$mac") ||
                        echo "fix-eth-name: no interface has MAC $mac, leaving its names in $file as they are" >&2
                fi
                del_this_line=true
            elif [[ "$line" = "iface e"* ]] ||
                [[ "$line" = "auto e"* ]] ||
                [[ "$line" = "allow-hotplug e"* ]]; then
                if [ -n "$ethx" ]; then
                    line=$(echo "$line" | awk "{\$2=\"$ethx\"; print \$0}")
                fi
            fi
            if ! $del_this_line; then
                echo "$line" >>"$tmp_file"
            fi
        done <"$file"

        mv "$tmp_file" "$file"
    fi
}

fix_netplan() {
    file=/etc/netplan/50-cloud-init.yaml
    tmp_file=$file.tmp

    rm -f "$tmp_file"

    if [ -f "$file" ]; then
        while IFS= read -r line; do
            if echo "$line" | grep -Eq '^[[:space:]]+macaddress:'; then
                # 得到正确的网卡名
                mac=$(echo "$line" | awk '{print $NF}' | sed 's/"//g')
                ethx=$(get_ethx_by_mac "$mac") ||
                    echo "fix-eth-name: no interface has MAC $mac, leaving its names in $file as they are" >&2
            elif echo "$line" | grep -Eq '^[[:space:]]+eth[0-9]+:'; then
                # 改成正确的网卡名
                if [ -n "$ethx" ]; then
                    line=$(echo "$line" | sed -E "s/[^[:space:]]+/$ethx:/")
                fi
            fi
            echo "$line" >>"$tmp_file"

            # 删除 set-name 不过这一步在 trans 已完成
            # 因为 netplan-generator 会在 systemd generator 阶段就根据 netplan 配置重命名网卡
            # systemd generator 阶段比本脚本和 systemd-networkd 更早运行

            # 倒序
        done < <(grep -Ev "^[[:space:]]+set-name:" "$file" | tac)

        # 再倒序回来
        tac "$tmp_file" >"$file"
        rm -f "$tmp_file"

        # 通过 systemd netplan generator 生成 /run/systemd/network/10-netplan-enp3s0.network
        systemctl daemon-reload
    fi
}

fix_ifupdown
fix_netplan
