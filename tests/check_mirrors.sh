#!/usr/bin/env bash
# 探测 reinstall.sh 支持的每个 distro / version 组合的下载链接是否可达，由 check-mirrors.yml 每周跑。
# 版本与代号从 reinstall.sh 原文抽取（verify_os_name 的版本清单、setos_<distro> 的 codename case）；
# 抽不到或对不上就停下，不带着旧表去探。

set -u

repo=$(cd "$(dirname "$0")/.." && pwd)
reinstall=$repo/reinstall.sh
# shellcheck source=lib.sh
. "$repo/tests/lib.sh"

# Versions verify_os_name() accepts for a distro, one per line.
versions_of() {
    extract_fn "$reinstall" verify_os_name | sed -n -E "s/^ *'$1 +([0-9.|]+)'.*/\\1/p" | tr '|' '\n' | grep . || {
        echo "no version list for $1 in verify_os_name()" >&2
        exit 2
    }
}

# Codename setos_<distro>() maps a version to.
codename_of() {
    local v=${2//./\\.}
    extract_fn "$reinstall" "setos_$1" | sed -n -E "s/^ *$v\\) codename=([a-z]+) ;;.*/\\1/p" | grep . || {
        echo "no codename for $1 $2 in setos_$1()" >&2
        exit 2
    }
}

alpine_versions=$(versions_of alpine) || exit
debian_versions=$(versions_of debian) || exit
ubuntu_versions=$(versions_of ubuntu) || exit

failed=0
failed_urls=""

probe() {
    local url=$1 code attempt=1
    while [ $attempt -le 3 ]; do
        # HEAD 请求；30s 超时；失败重试间隔 5s
        # %{http_code} 对超时/连接错误返回 000
        code=$(curl -sSL --max-time 30 -o /dev/null -w "%{http_code}" -I "$url") || code=000
        if [ "$code" = 200 ]; then
            printf 'OK    %s\n' "$url"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done
    printf 'FAIL  %s (last HTTP %s after 3 tries)\n' "$url" "$code"
    failed=$((failed + 1))
    failed_urls="$failed_urls
$url"
}

echo '=== Alpine (virt kernel; reinstall only runs in VMs) ==='
for v in $alpine_versions; do
    for arch in x86_64 aarch64; do
        probe "http://dl-cdn.alpinelinux.org/alpine/v$v/releases/$arch/netboot/vmlinuz-virt"
        probe "http://dl-cdn.alpinelinux.org/alpine/v$v/releases/$arch/netboot/initramfs-virt"
    done
done

echo
echo '=== Debian cloud images ==='
for v in $debian_versions; do
    codename=$(codename_of debian "$v") || exit
    for arch in amd64 arm64; do
        probe "https://cdimage.debian.org/images/cloud/$codename/latest/debian-$v-nocloud-$arch.qcow2"
    done
    probe "https://cdimage.debian.org/images/cloud/$codename/latest/SHA512SUMS"
done

echo
echo '=== Ubuntu cloud images (server) ==='
for v in $ubuntu_versions; do
    codename=$(codename_of ubuntu "$v") || exit
    for arch in amd64 arm64; do
        probe "https://cloud-images.ubuntu.com/releases/$codename/release/ubuntu-$v-server-cloudimg-$arch.img"
    done
    probe "https://cloud-images.ubuntu.com/releases/$codename/release/SHA256SUMS"
    probe "https://cloud-images.ubuntu.com/releases/$codename/release/SHA256SUMS.gpg"
done

echo
echo '=== Ubuntu cloud images (minimal; arm64 only for 24+) ==='
for v in $ubuntu_versions; do
    codename=$(codename_of ubuntu "$v") || exit
    probe "https://cloud-images.ubuntu.com/minimal/releases/$codename/release/ubuntu-$v-minimal-cloudimg-amd64.img"
    minor=${v%.*}
    if [ "$minor" -ge 24 ]; then
        probe "https://cloud-images.ubuntu.com/minimal/releases/$codename/release/ubuntu-$v-minimal-cloudimg-arm64.img"
    fi
done

echo
echo "=== Summary ==="
if [ $failed -eq 0 ]; then
    echo "all probed URLs reachable"
    exit 0
else
    echo "$failed URL(s) failed:"
    # shellcheck disable=SC2086
    echo "$failed_urls"
    exit 1
fi
