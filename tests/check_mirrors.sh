#!/usr/bin/env bash
# 探测 reinstall.sh 所有支持的 distro / version 组合实际下载链接是否可达。
# Weekly 跑一次（.github/workflows/check-mirrors.yml）。
#
# 版本表跟 reinstall.sh:verify_os_name 同步。升级 reinstall.sh 后请也更新这里。

set -u

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

debian_codename() {
    case "$1" in
    11) echo bullseye ;;
    12) echo bookworm ;;
    13) echo trixie ;;
    esac
}

ubuntu_codename() {
    case "$1" in
    20.04) echo focal ;;
    22.04) echo jammy ;;
    24.04) echo noble ;;
    25.10) echo questing ;;
    esac
}

echo '=== Alpine (virt kernel; reinstall only runs in VMs) ==='
for v in 3.20 3.21 3.22 3.23; do
    for arch in x86_64 aarch64; do
        probe "http://dl-cdn.alpinelinux.org/alpine/v$v/releases/$arch/netboot/vmlinuz-virt"
        probe "http://dl-cdn.alpinelinux.org/alpine/v$v/releases/$arch/netboot/initramfs-virt"
    done
done

echo
echo '=== Debian cloud images ==='
for v in 11 12 13; do
    codename=$(debian_codename "$v")
    for arch in amd64 arm64; do
        probe "https://cdimage.debian.org/images/cloud/$codename/latest/debian-$v-nocloud-$arch.qcow2"
    done
    probe "https://cdimage.debian.org/images/cloud/$codename/latest/SHA512SUMS"
done

echo
echo '=== Ubuntu cloud images (server) ==='
for v in 20.04 22.04 24.04 25.10; do
    codename=$(ubuntu_codename "$v")
    for arch in amd64 arm64; do
        probe "https://cloud-images.ubuntu.com/releases/$codename/release/ubuntu-$v-server-cloudimg-$arch.img"
    done
    probe "https://cloud-images.ubuntu.com/releases/$codename/release/SHA256SUMS"
    probe "https://cloud-images.ubuntu.com/releases/$codename/release/SHA256SUMS.gpg"
done

echo
echo '=== Ubuntu cloud images (minimal; arm64 only for 24+) ==='
for v in 20.04 22.04 24.04 25.10; do
    codename=$(ubuntu_codename "$v")
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
