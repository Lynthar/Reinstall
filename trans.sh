#!/bin/ash
# shellcheck shell=dash
# shellcheck disable=SC2086,SC3047,SC3036,SC3010,SC3001
# alpine 默认使用 busybox ash
# 注意 bash 和 ash 以下语句结果不同
# [[ a = '*a' ]] && echo 1

# 出错后停止运行，将进入到登录界面，防止失联
set -eE

# 用于判断 reinstall.sh 和 trans.sh 是否兼容
# shellcheck disable=SC2034
SCRIPT_VERSION=E65E8084-075D-4C7C-8DF5-9039E4CE3FDB

TRUE=0
FALSE=1
EFI_UUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B

error() {
    color='\e[31m'
    plain='\e[0m'
    echo -e "${color}***** ERROR *****${plain}" >&2
    echo -e "${color}$*${plain}" >&2
}

info() {
    color='\e[32m'
    plain='\e[0m'
    local msg

    if [ "$1" = false ]; then
        shift
        msg=$*
    else
        msg=$(echo "$*" | to_upper)
    fi

    echo -e "${color}***** $msg *****${plain}" >&2
}

warn() {
    color='\e[33m'
    plain='\e[0m'
    echo -e "${color}Warning: $*${plain}" >&2
}

error_and_exit() {
    error "$@"
    save_debug_bundle
    # 写盘之后重启就回不来了：原系统已没了，内存里的临时系统也一起没了
    if is_disk_written; then
        echo "The disk has already been rewritten. Do not reboot: the current system is gone," >&2
        echo "and this temporary system runs from memory. Fix the cause over SSH, then:" >&2
    else
        echo "The disk has not been touched. 'reboot' goes back to the current system, where" >&2
        echo "'bash reinstall.sh reset' removes the leftover boot entry. Or fix the cause, then:" >&2
    fi
    echo "Run '/trans.sh' to retry." >&2
    echo "Run '/trans.sh alpine' to install Alpine Linux instead." >&2
    exit 1
}

# 出错时打包现场给人排查。/configs 里有口令哈希与 key，不收；不装包，网络可能正是出错的原因。
# 收集本身的失败一律忽略：它在报错路径上，不能把原来的错误盖掉
save_debug_bundle() {
    local dir=/tmp/reinstall-debug bundle=/tmp/reinstall-debug.tar.gz
    rm -f $bundle
    (
        trap - ERR
        set +e
        rm -rf $dir
        mkdir -p $dir
        cp /reinstall.log /proc/cmdline /etc/resolv.conf $dir/
        dmesg >$dir/dmesg
        ip addr >$dir/ip-addr
        { ip -4 route; ip -6 route; } >$dir/ip-route
        show_netconf >$dir/netconf
        cat /proc/partitions >$dir/partitions
        blkid >$dir/blkid
        if is_have_cmd lsblk; then
            lsblk -f >$dir/lsblk
        fi
        mount >$dir/mount
        { free -m; df -h; } >$dir/free-df
        tar czf $bundle -C /tmp reinstall-debug
        rm -rf $dir
    ) >/dev/null 2>&1
    if [ -s $bundle ]; then
        echo "Diagnostics saved to $bundle (holds IP addresses and the install log; read it before sharing)." >&2
    fi
}

is_disk_written() {
    [ "$(get_config disk_written 2>/dev/null)" = 1 ]
}

# 第一次写盘之前调：说出要改写的是哪块盘，并记进 /configs，失败后手动重跑也知道盘已经动过
begin_disk_write() {
    local size model
    size=$(awk '{ printf "%.1f GiB", $1 / 2097152 }' /sys/block/$xda/size)
    model=$(sed 's/ *$//' /sys/block/$xda/device/model 2>/dev/null || true)
    set_config disk_written 1
    warn "Rewriting /dev/$xda ($size${model:+, $model}). The current system cannot come back after this."
}

trap_err() {
    line_no=$1
    ret_no=$2

    error_and_exit "$(
        echo "Line $line_no return $ret_no"
        if [ -f "/trans.sh" ]; then
            sed -n "$line_no"p /trans.sh
        fi
    )"
}

is_run_from_locald() {
    [[ "$0" = "/etc/local.d/*" ]]
}

add_community_repo() {
    # 先检查原来的repo是不是egde
    if grep -q '^http.*/edge/main$' /etc/apk/repositories; then
        alpine_ver=edge
    else
        alpine_ver=v$(cut -d. -f1,2 </etc/alpine-release)
    fi

    if ! grep -q "^http.*/$alpine_ver/community$" /etc/apk/repositories; then
        alpine_mirror=$(grep '^http.*/main$' /etc/apk/repositories | sed 's,/[^/]*/main$,,' | head -1)
        echo $alpine_mirror/$alpine_ver/community >>/etc/apk/repositories
    fi
}

# 有时网络问题下载失败，导致脚本中断
# 因此需要重试
apk() {
    retry 5 command apk "$@" >&2
}

show_url_in_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        [Hh][Tt][Tt][Pp][Ss]://* | [Hh][Tt][Tt][Pp]://*) echo "$1" ;;
        esac
        shift
    done
}

# 在没有设置 set +o pipefail 的情况下，限制下载大小：
# retry 5 command wget | head -c 1048576 会触发 retry，下载 5 次
# command wget "$@" --tries=5 | head -c 1048576 不会触发 wget 自带的 retry，只下载 1 次
wget() {
    show_url_in_args "$@" >&2
    if command wget 2>&1 | grep -q BusyBox; then
        # busybox wget 没有重试功能
        # 好像默认永不超时
        retry 5 command wget "$@" -T 10
    else
        # 原版 wget 自带重试功能
        command wget --tries=5 --progress=bar:force "$@"
    fi
}

is_have_cmd() {
    # command -v 包括脚本里面的方法
    is_have_cmd_on_disk / "$1"
}

is_have_cmd_on_disk() {
    local os_dir=$1
    local cmd=$2

    for bin_dir in /bin /sbin /usr/bin /usr/sbin; do
        if [ -f "$os_dir$bin_dir/$cmd" ]; then
            return
        fi
    done
    return 1
}

is_num() {
    echo "$1" | grep -Exq '[0-9]*\.?[0-9]*'
}

retry() {
    local max_try=$1
    shift

    if is_num "$1"; then
        local interval=$1
        shift
    else
        local interval=5
    fi

    for i in $(seq $max_try); do
        if "$@"; then
            return
        else
            ret=$?
            if [ $i -ge $max_try ]; then
                # 让失败的命令自己触发 ERR，别用 return $ret：busybox ash 里 return 非零触发的
                # 陷阱只跑 trap_err 的第一条命令就退出，报错与重试提示全丢。条件里调用时没有陷阱，
                # 由不带参数的 return 带回 $ret
                (exit $ret)
                return
            fi
            sleep $interval
        fi
    done
}

download() {
    url=$1
    path=$2

    # 有ipv4地址无ipv4网关的情况下，aria2可能会用ipv4下载，而不是ipv6
    # axel 在 lightsail 上会占用大量cpu
    # https://download.opensuse.org/distribution/leap/15.5/appliances/openSUSE-Leap-15.5-Minimal-VM.x86_64-kvm-and-xen.qcow2
    # https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-o

    # 阿里云源限速，而且检测 user-agent 禁止 axel/aria2 下载
    # aria2 默认 --max-tries 5

    # 默认 --max-tries=5，但以下情况服务器出错，aria2不会重试，而是直接返回错误
    # 因此添加 for 循环
    #     [ERROR] CUID#7 - Download aborted. URI=https://aka.ms/manawindowsdrivers
    # Exception: [AbstractCommand.cc:351] errorCode=1 URI=https://aka.ms/manawindowsdrivers
    #   -> [SocketCore.cc:1019] errorCode=1 SSL/TLS handshake failure:  `not signed by known authorities or invalid'

    # 用 if 的话，报错不会中断脚本
    # if aria2c xxx; then
    #     return
    # fi

    # --user-agent=Wget/1.21.1 \
    # --retry-wait 5

    # intel 禁止了 aria2 下载驱动
    # intel 禁止了 wget 下载网页内容
    # 腾讯云 virtio 驱动也禁止了 aria2 下载

    aria2c "$url" \
        -d "$(dirname "$path")" \
        -o "$(basename "$path")" \
        -U curl/7.54.1

    # opensuse 官方镜像支持 metalink
    # aira2 无法重命名用 metalink 下载的文件
    # 需用以下方法重命名
    if head -c 1024 "$path" | grep -Fq 'urn:ietf:params:xml:ns:metalink'; then
        real_file=$(tr -d '\n' <"$path" | sed -E 's|.*<file[[:space:]]+name="([^"]*)".*|\1|')
        mv "$(dirname "$path")/$real_file" "$path"
    fi
}

update_part() {
    sleep 1
    sync

    # partprobe
    # 有分区挂载中会报 Resource busy 错误
    if is_have_cmd partprobe; then
        partprobe /dev/$xda 2>/dev/null || true
    fi

    # partx
    # https://access.redhat.com/solutions/199573
    if is_have_cmd partx; then
        partx -u /dev/$xda
    fi

    # mdev
    # mdev 不会删除 /dev/disk/ 的旧分区，因此手动删除
    # 如果 rm -rf 的时候刚好 mdev 在创建链接，rm -rf 会报错 Directory not empty
    # 因此要先停止 mdev 服务
    # 还要删除 /dev/$xda*?
    ensure_service_stopped mdev
    # 即使停止了 mdev，有时也会报 Directory not empty，因此添加 retry
    retry 5 rm -rf /dev/disk/*

    # 没挂载 modloop 时会提示
    # modprobe: can't change directory to '/lib/modules': No such file or directory
    # 因此强制不显示上面的提示
    mdev -sf 2>/dev/null
    ensure_service_started mdev 2>/dev/null
    sleep 1
}

is_efi() {
    if [ -n "$force_boot_mode" ]; then
        [ "$force_boot_mode" = efi ]
    else
        [ -d /sys/firmware/efi/ ]
    fi
}

is_use_cloud_image() {
    [ -n "$cloud_image" ] && [ "$cloud_image" = 1 ]
}

setup_websocketd() {
    # 日志页只是另一种看日志的方式，装不上不该让整个安装失败
    if ! apk add websocketd coreutils; then
        warn "Could not install websocketd, so there is no web log viewer. Follow the log over SSH: tail -f /reinstall.log"
        return
    fi
    # 只服务这一个目录：开了 --web-public 时它对谁都敞开，/tmp 里有诊断包与校验和
    mkdir -p /logviewer
    cp /repo/logviewer.html /logviewer/index.html

    if [ -z "$web_port" ]; then
        web_port=80
    fi

    # 默认绑定到 loopback，公网不可达；--web-public 才监听所有接口
    # shellcheck disable=SC2154
    if [ "$web_public" = 1 ]; then
        web_addr=0.0.0.0
        warn "Web log viewer listening on $web_addr:$web_port (PUBLIC, no auth)"
    else
        web_addr=127.0.0.1
        info false "Web log viewer listening on $web_addr:$web_port (use SSH port forwarding to view)"
    fi

    # 重跑时先停掉上一次的。pkill 发完信号就返回，旧进程还没退出时新的绑不上端口，日志页就没了
    pkill websocketd || true
    for _ in 1 2 3 4 5; do
        pgrep -x websocketd >/dev/null || break
        sleep 1
    done
    # websocketd 遇到 \n 才推送，因此要转换 \r 为 \n
    websocketd --address "$web_addr" --port "$web_port" --loglevel=fatal --staticdir=/logviewer \
        stdbuf -oL -eL sh -c "tail -fn+0 /reinstall.log | tr '\r' '\n' | grep -Fiv -e password -e token" &
}

get_approximate_ram_size() {
    if [ -z $ram_size ]; then
        ram_size=$(free -m | awk '{print $2}' | sed -n '2p')
    fi

    echo "$ram_size"
}

setup_web_if_enough_ram() {
    # shellcheck disable=SC2154
    if [ "$no_web" = 1 ]; then
        info false "Web log viewer disabled by --no-web"
        return
    fi
    total_ram=$(get_approximate_ram_size)
    # 内存 < 400M 时跳过，节省 alpine live OS 内存
    if [ "$total_ram" -ge 400 ]; then
        setup_websocketd
    else
        info false "Web log viewer skipped: $total_ram MiB of RAM is under 400 MiB. Follow the log over SSH: tail -f /reinstall.log"
    fi
}

# get_ttys <前缀>：能写的串口与 tty0，最后一个是主控制台；有的机器有 ttyS0 却写不进
get_ttys() {
    prefix=$1
    if [ "$(uname -m)" = aarch64 ]; then
        ttys="ttyS0 ttyAMA0 tty0"
    else
        ttys="ttyS0 tty0"
    fi
    sep=
    for tty in $ttys; do
        if stty -g -F "/dev/$tty" >/dev/null 2>&1; then
            printf '%s%s%s' "$sep" "$prefix" "$tty"
            if [ "$prefix" = console= ] && [ "$tty" != tty0 ]; then
                printf ',115200n8'
            fi
            sep=' '
        fi
    done
}

find_xda() {
    # 出错后再运行脚本，硬盘可能已经格式化，之前记录的分区表 id 无效
    # 因此找到 xda 后要保存 xda 到 /configs/xda

    # 先读取之前保存的
    if xda=$(get_config xda 2>/dev/null) && [ -n "$xda" ]; then
        return
    fi

    # 防止 $main_disk 为空
    if [ -z "$main_disk" ]; then
        error_and_exit "cmdline main_disk is empty."
    fi

    # busybox 的 fdisk / lsblk / blkid 都不显示 mbr 分区表 id，sfdisk 占用最小
    is_have_cmd sfdisk && need_install_tool=false || need_install_tool=true
    if $need_install_tool; then
        apk add sfdisk
    fi

    for disk in $(get_all_disks); do
        if sfdisk --disk-id "/dev/$disk" | sed 's/0x//' | grep -ix "$main_disk"; then
            # 克隆盘的分区表 id 相同，取第一个匹配可能整盘擦错
            if [ -n "$xda" ]; then
                error_and_exit "Disk id $main_disk is on both $xda and $disk."
            fi
            xda=$disk
        fi
    done

    if [ -n "$xda" ]; then
        set_config xda "$xda"
    else
        error_and_exit "Could not find xda: $main_disk"
    fi

    if $need_install_tool; then
        apk del sfdisk
    fi
}

get_all_disks() {
    # shellcheck disable=SC2010
    ls /sys/block/ | grep -Ev '^(loop|sr|nbd)'
}

# get_drivers <sysfs 设备路径>：从设备往上逐级打出驱动，是模块的打模块名
get_drivers() {
    (
        cd "$(readlink -f $1)"
        while ! [ "$(pwd)" = / ]; do
            if [ -d driver ]; then
                if [ -d driver/module ]; then
                    basename "$(readlink -f driver/module)"
                else
                    basename "$(readlink -f driver)"
                fi
            fi
            cd ..
        done
    )
}

extract_env_from_cmdline() {
    # 提取 finalos/extra 到变量
    for prefix in finalos extra; do
        while read -r line; do
            if [ -n "$line" ]; then
                key=$(echo $line | cut -d= -f1)
                value=$(echo $line | cut -d= -f2-)
                eval "$key='$value'"
            fi
        done < <(xargs -n1 </proc/cmdline | grep "^${prefix}_" | sed "s/^${prefix}_//")
    done
}

ensure_service_started() {
    service=$1

    if ! rc-service -q $service status; then
        if ! retry 5 rc-service -q $service start; then
            error_and_exit "Failed to start $service."
        fi
    fi
}

# 低内存装 alpine 时删掉了 modloop；重跑时 modloop 服务会自己走明文重下、不核对。
# 这里先取回并按 stage 1 经 HTTPS 算的哈希核对，服务见 /lib 下已有同名文件就只挂载
start_modloop() {
    local url file
    url=$(xargs -n1 </proc/cmdline | sed -n 's/^modloop=//p')
    file=/lib/${url##*/}
    if ! rc-service -q modloop status && ! [ -f "$file" ]; then
        retry 5 wget -O "$file.part" "$url"
        if ! echo "$(get_config modloop_sha256)  $file.part" | sha256sum -c; then
            rm -f "$file.part"
            error_and_exit "modloop does not match the sha256 fetched over HTTPS: $url"
        fi
        mv "$file.part" "$file"
    fi
    ensure_service_started modloop
}

ensure_service_stopped() {
    service=$1

    if rc-service -q $service status; then
        if ! retry 5 rc-service -q $service stop; then
            error_and_exit "Failed to stop $service."
        fi
    fi
}

mod_motd() {
    # 安装后 alpine 后要恢复默认
    # 自动安装失败后，可能手动安装 alpine，因此无需判断 $distro
    file=/etc/motd
    if ! [ -e $file.orig ]; then
        cp $file $file.orig
        # shellcheck disable=SC2016
        echo "mv "\$mnt$file.orig" "\$mnt$file"" |
            insert_into_file "$(which setup-disk)" before 'cleanup_chroot_mounts "\$mnt"'

        cat <<EOF >$file
Reinstalling...
To view logs run:
tail -fn+1 /reinstall.log
EOF
    fi
}

umount_all() {
    dirs="/mnt /os /installer /nbd /nbd-boot /nbd-efi /nbd-test /root"
    regex=$(echo "$dirs" | sed 's, ,|,g')
    if mounts=$(mount | grep -Ew "on $regex" | awk '{print $3}' | tac); then
        for mount in $mounts; do
            echo "umount $mount"
            umount $mount
        done
    fi
}

# 杀掉根目录是 $1 的进程，等它们退出
kill_procs_rooted_in() {
    local pids proc
    for _ in 1 2 3 4 5; do
        pids=
        for proc in /proc/[0-9]*; do
            if [ "$(readlink $proc/root 2>/dev/null)" = "$1" ]; then
                pids="$pids ${proc#/proc/}"
            fi
        done
        if [ -z "$pids" ]; then
            return
        fi
        kill -9 $pids || true
        sleep 1
    done
}

# 可能脚本不是首次运行，先清理之前的残留
clear_previous() {
    disconnect_qcow
    # fetch_qcow_hash 验签后 gpg-agent 会驻留，重跑前清掉
    pkill gpg-agent || true
    # 上次装 alpine 时在 chroot 里起的 ntpd、dhcpcd 根目录在 /os，不先杀掉，/os 就卸不掉
    kill_procs_rooted_in /os
    swapoff -a
    umount_all

    # 以下情况 umount -R /1 会提示 busy
    # mount /file1 /1
    # mount /1/file2 /2
}

# virt-what 自动安装 dmidecode，因此同时缓存
cache_dmi_and_virt() {
    if ! [ "$_dmi_and_virt_cached" = 1 ]; then
        apk add virt-what

        # 区分 kvm 和 virtio，原因:
        # 1. 阿里云 c8y virt-what 不显示 kvm
        # 2. 不是所有 kvm 都需要 virtio 驱动，例如 aws nitro
        # 3. virt-what 不会检测 virtio
        _virt=$(
            virt-what

            # hyper-v 环境下 modprobe virtio_scsi 也会创建 /sys/bus/virtio/drivers/virtio_scsi
            # 因此用 devices 判断更准确，有设备时才有 /sys/bus/virtio/drivers/*
            # 或者加上 lspci 检测?

            # 不要用 ls /sys/bus/virtio/devices/* && echo virtio
            # 因为有可能返回值不为 0 而中断脚本
            if ls /sys/bus/virtio/devices/* >/dev/null 2>&1; then
                echo virtio
            fi
        )

        _dmi_and_virt_cached=1
        apk del virt-what
    fi
}

is_virt() {
    cache_dmi_and_virt
    [ -n "$_virt" ]
}

# 腾讯云部分机型的 virtio 盘，内核把 max_sectors_kb 设得比 512 大时，大块写入会出 I/O 错误；
# 腾讯自己的镜像用 udev 规则设回 512。CVM 与轻量的 sys_vendor 都是这个
is_tencent_cloud() {
    [ "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" = 'Tencent Cloud' ]
}

# 第一次写盘之前调：Live OS 的内核同样会把它设大
limit_tencent_disk_requests() {
    local f
    if is_tencent_cloud; then
        info false "Tencent Cloud (DMI sys_vendor): limiting virtio disks to 512 KiB requests, as Tencent's own images do"
        for f in /sys/block/vd*/queue/max_sectors_kb; do
            if [ -e "$f" ] && ! echo 512 >"$f"; then
                warn "Could not set $f to 512"
            fi
        done
        if [ "$distro" = dd ]; then
            warn "The dd image is written as is: unless it sets max_sectors_kb to 512 itself (Tencent's images do it with a udev rule), heavy writes on it may fail with I/O errors."
        fi
    fi
}

# 装好的系统开机后也要 512。initramfs-tools 与 dracut 都把 /etc/udev/rules.d 带进 initramfs，所以当场重建；
# alpine 用 mdev，mkinitfs 不带 mdev.conf，挂上根之后才生效
persist_tencent_disk_limit() {
    local os_dir=$1
    if is_tencent_cloud; then
        info false "Tencent Cloud: the installed system limits its virtio disks to 512 KiB requests too"
        if [ "$distro" = alpine ]; then
            # 开头的 - 让 mdev 接着往下匹配，权限仍由后面 vd 那行定；mdev 要整个名字匹配，分区不中
            insert_into_file $os_dir/etc/mdev.conf head '' <<'EOF'
-vd[a-z]+ root:disk 0660 @echo 512 >/sys/block/$MDEV/queue/max_sectors_kb
EOF
        else
            echo 'SUBSYSTEM=="block", KERNEL=="vd*[a-z]", ACTION=="add|change", ATTR{queue/max_sectors_kb}="512"' \
                >$os_dir/etc/udev/rules.d/80-max-sectors-blk.rules
            chroot $os_dir update-initramfs -u -k all
        fi
    fi
}

get_config() {
    cat "/configs/$1"
}

set_config() {
    printf '%s' "$2" >"/configs/$1"
}

get_password_linux_sha512() {
    get_config password-linux-sha512
}

show_netconf() {
    grep -r . /dev/netconf/
}

get_ra_to() {
    if [ -z "$_ra" ]; then
        apk add ndisc6
        # 有时会重复收取，所以设置收一份后退出
        echo "Gathering network info..."
        # shellcheck disable=SC2154
        _ra="$(rdisc6 -1 "$ethx")"
        apk del ndisc6

        # 显示网络配置
        info "Network info:"
        echo
        echo "$_ra" | cat -n
        echo
        ip addr | cat -n
        echo
        show_netconf | cat -n
        echo
    fi
    eval "$1='$_ra'"
}

get_netconf_to() {
    case "$1" in
    slaac | dhcpv6 | rdnss | other) get_ra_to ra ;;
    esac

    # shellcheck disable=SC2154
    # debian initrd 没有 xargs
    case "$1" in
    slaac) echo "$ra" | grep 'Autonomous address conf' | grep -q Yes && res=1 || res=0 ;;
    dhcpv6) echo "$ra" | grep 'Stateful address conf' | grep -q Yes && res=1 || res=0 ;;
    rdnss) res=$(echo "$ra" | grep 'Recursive DNS server' | cut -d: -f2-) ;;
    other) echo "$ra" | grep 'Stateful other conf' | grep -q Yes && res=1 || res=0 ;;
    *) res=$(cat /dev/netconf/$ethx/$1) ;;
    esac

    eval "$1='$res'"
}

# 有 dhcpv4 不等于有网关，例如 vultr 纯 ipv6
# 没有 dhcpv4 不等于是静态ip，可能是没有 ip
is_dhcpv4() {
    if ! is_ipv4_has_internet || should_disable_dhcpv4; then
        return 1
    fi

    get_netconf_to dhcpv4
    # shellcheck disable=SC2154
    [ "$dhcpv4" = 1 ]
}

is_staticv4() {
    if ! is_ipv4_has_internet; then
        return 1
    fi

    if ! is_dhcpv4; then
        get_netconf_to ipv4_addr
        get_netconf_to ipv4_gateway
        if [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ]; then
            return 0
        fi
    fi
    return 1
}

is_staticv6() {
    if ! is_ipv6_has_internet; then
        return 1
    fi

    if ! is_slaac && ! is_dhcpv6; then
        get_netconf_to ipv6_addr
        get_netconf_to ipv6_gateway
        if [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ]; then
            return 0
        fi
    fi
    return 1
}

is_dhcpv6_or_slaac() {
    get_netconf_to dhcpv6_or_slaac
    # shellcheck disable=SC2154
    [ "$dhcpv6_or_slaac" = 1 ]
}

is_ipv4_has_internet() {
    get_netconf_to ipv4_has_internet
    # shellcheck disable=SC2154
    [ "$ipv4_has_internet" = 1 ]
}

is_ipv6_has_internet() {
    get_netconf_to ipv6_has_internet
    # shellcheck disable=SC2154
    [ "$ipv6_has_internet" = 1 ]
}

should_disable_dhcpv4() {
    get_netconf_to should_disable_dhcpv4
    # shellcheck disable=SC2154
    [ "$should_disable_dhcpv4" = 1 ]
}

should_disable_accept_ra() {
    get_netconf_to should_disable_accept_ra
    # shellcheck disable=SC2154
    [ "$should_disable_accept_ra" = 1 ]
}

should_disable_autoconf() {
    get_netconf_to should_disable_autoconf
    # shellcheck disable=SC2154
    [ "$should_disable_autoconf" = 1 ]
}

is_slaac() {
    # 如果是静态（包括自动获取到 IP 但无法联网而切换成静态）直接返回 1，不考虑 ra
    # 防止部分机器slaac/dhcpv6获取的ip/网关无法上网

    # 有可能 ra 的 dhcpv6/slaac 是打开的，但实测无法获取到 ipv6 地址
    # is_dhcpv6_or_slaac 是实测结果，因此如果实测不通过，也返回 1

    # 不要判断 is_staticv6，因为这会导致死循环
    if ! is_ipv6_has_internet || ! is_dhcpv6_or_slaac || should_disable_accept_ra || should_disable_autoconf; then
        return 1
    fi
    get_netconf_to slaac
    # shellcheck disable=SC2154
    [ "$slaac" = 1 ]
}

is_dhcpv6() {
    # 如果是静态（包括自动获取到 IP 但无法联网而切换成静态）直接返回 1，不考虑 ra
    # 防止部分机器slaac/dhcpv6获取的ip/网关无法上网

    # 有可能 ra 的 dhcpv6/slaac 是打开的，但实测无法获取到 ipv6 地址
    # is_dhcpv6_or_slaac 是实测结果，因此如果实测不通过，也返回 1

    # 不要判断 is_staticv6，因为这会导致死循环
    if ! is_ipv6_has_internet || ! is_dhcpv6_or_slaac || should_disable_accept_ra || should_disable_autoconf; then
        return 1
    fi
    get_netconf_to dhcpv6

    # shellcheck disable=SC2154
    # 甲骨文即使没有添加 IPv6 地址，RA DHCPv6 标志也是开的
    # 部分系统开机需要等 DHCPv6 超时
    # 这种情况需要禁用 DHCPv6
    if [ "$dhcpv6" = 1 ] && ! ip -6 -o addr show scope global dev "$ethx" | grep -q .; then
        echo 'DHCPv6 flag is on, but DHCPv6 is not working.'
        return 1
    fi

    [ "$dhcpv6" = 1 ]
}

is_have_ipv6() {
    is_slaac || is_dhcpv6 || is_staticv6
}

is_enable_other_flag() {
    get_netconf_to other
    # shellcheck disable=SC2154
    [ "$other" = 1 ]
}

is_have_rdnss() {
    # rdnss 可能有几个
    get_netconf_to rdnss
    [ -n "$rdnss" ]
}

is_need_set_ssh_keys() {
    [ -s /configs/ssh_keys ]
}

is_need_change_ssh_port() {
    [ -n "$ssh_port" ] && ! [ "$ssh_port" = 22 ]
}

is_need_manual_set_dnsv6() {
    # 有没有可能是静态但是有 rdnss？
    ! is_have_ipv6 && return $FALSE
    is_dhcpv6 && return $FALSE
    is_staticv6 && return $TRUE
    is_slaac && ! is_enable_other_flag && ! is_have_rdnss
}

get_current_dns() {
    mark=$(
        case "$1" in
        4) echo . ;;
        6) echo : ;;
        esac
    )
    # debian 11 initrd 没有 xargs awk
    # debian 12 initrd 没有 xargs
    if false; then
        grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | grep -F "$mark" | cut -d '%' -f1
    else
        grep '^nameserver' /etc/resolv.conf | cut -d' ' -f2 | grep -F "$mark" | cut -d '%' -f1
    fi
}

to_upper() {
    tr '[:lower:]' '[:upper:]'
}

del_empty_lines() {
    sed '/^[[:space:]]*$/d'
}

get_part_num_by_part() {
    dev_part=$1
    echo "$dev_part" | grep -o '[0-9]*' | tail -1
}

get_fallback_efi_file_name() {
    case $(arch) in
    x86_64) echo bootx64.efi ;;
    aarch64) echo bootaa64.efi ;;
    *) error_and_exit ;;
    esac
}

del_invalid_efi_entry() {
    info "del invalid EFI entry"
    apk add lsblk efibootmgr

    efibootmgr --quiet --remove-dups

    while read -r line; do
        part_uuid=$(echo "$line" | awk -F ',' '{print $3}')
        efi_index=$(echo "$line" | grep_efi_index)
        if ! lsblk -o PARTUUID | grep -q "$part_uuid"; then
            echo "Delete invalid EFI Entry: $line"
            efibootmgr --quiet --bootnum "$efi_index" --delete-bootnum
        fi
    done < <(efibootmgr | grep 'HD(.*,GPT,')
}

# reinstall.sh 有同名方法
grep_efi_index() {
    awk '{print $1}' | sed -e 's/Boot//' -e 's/\*//'
}

# 某些机器可能不会回落到 bootx64.efi
# 阿里云 ECS 启动项有 EFI Shell
# 添加 bootx64.efi 到最后的话，会进入 EFI Shell
# 因此添加到最前面
add_default_efi_to_nvram() {
    info "add default EFI to nvram"

    apk add lsblk efibootmgr

    if efi_row=$(lsblk /dev/$xda -ro NAME,PARTTYPE,PARTUUID | grep -i "$EFI_UUID"); then
        efi_part_uuid=$(echo "$efi_row" | awk '{print $3}')
        efi_part_name=$(echo "$efi_row" | awk '{print $1}')
        efi_part_num=$(get_part_num_by_part "$efi_part_name")
        efi_file=$(get_fallback_efi_file_name)

        # 创建条目，先判断是否已经存在
        # 好像没必要先判断
        if true || ! efibootmgr | grep -i "HD($efi_part_num,GPT,$efi_part_uuid,.*)/File(\\\EFI\\\boot\\\\$efi_file)"; then
            efibootmgr --create \
                --disk "/dev/$xda" \
                --part "$efi_part_num" \
                --label "$efi_file" \
                --loader "\\EFI\\boot\\$efi_file"
        fi
    else
        # shellcheck disable=SC2154
        if [ "$confirmed_no_efi" = 1 ]; then
            echo 'Confirmed no EFI in previous step.'
        else
            # reinstall.sh 里确认过一遍，但是逻辑扇区大于 512 时，可能漏报？
            # 这里的应该会根据逻辑扇区来判断？
            echo "
Warning: This machine is currently using EFI boot, but the main hard drive does not have an EFI partition.
If this machine supports Legacy BIOS boot (CSM), you can safely restart into the new system by running the reboot command.
If this machine does not support Legacy BIOS boot (CSM), you will not be able to enter the new system after rebooting.

警告：本机目前使用 EFI 引导，但主硬盘没有 EFI 分区。
如果本机支持 Legacy BIOS 引导 (CSM)，你可以运行 reboot 命令安全地重启到新系统。
如果本机不支持 Legacy BIOS 引导 (CSM)，重启后将无法进入新系统。
"
            exit
        fi
    fi
}

unix2dos() {
    target=$1

    # 先原地unix2dos，出错再用cat，可最大限度保留文件权限
    if ! command unix2dos $target 2>/tmp/unix2dos.log; then
        # 出错后删除 unix2dos 创建的临时文件
        rm "$(awk -F: '{print $2}' /tmp/unix2dos.log | xargs)"
        tmp=$(mktemp)
        cp $target $tmp
        command unix2dos $tmp
        # cat 可以保留权限
        cat $tmp >$target
        rm $tmp
    fi
}

insert_into_file() {
    local file=$1
    local location=$2
    local regex_to_find=$3
    shift 3

    if ! [ -f "$file" ]; then
        error_and_exit "File not found: $file"
    fi

    # 默认 grep -E
    if [ $# -eq 0 ]; then
        set -- -E
    fi

    if [ "$location" = head ]; then
        bak=$(mktemp)
        cp $file $bak
        cat - $bak >$file
    else
        line_num=$(grep "$@" -n "$regex_to_find" "$file" | cut -d: -f1)

        # 零匹配时 line_num 为空，echo 出的空行也算一行，所以先判空
        if [ -z "$line_num" ] || [ "$(echo "$line_num" | wc -l)" -ne 1 ]; then
            error_and_exit "Expected exactly one line matching '$regex_to_find' in $file."
        fi

        case "$location" in
        before) line_num=$((line_num - 1)) ;;
        after) ;;
        *) error_and_exit "Unknown location: $location" ;;
        esac

        sed -i "${line_num}r /dev/stdin" "$file"
    fi
}

get_eths() {
    (
        cd /dev/netconf
        ls
    )
}

is_distro_like_debian() {
    [ "$distro" = debian ] || [ "$distro" = ubuntu ]
}

create_ifupdown_config() {
    conf_file=$1

    rm -f $conf_file

    if is_distro_like_debian; then
        cat <<EOF >>$conf_file
source /etc/network/interfaces.d/*

EOF
    fi

    # 生成 lo配置
    cat <<EOF >>$conf_file
auto lo
iface lo inet loopback
EOF

    # ethx
    for ethx in $(get_eths); do
        mode=auto
        # dmit debian 普通内核和云内核网卡名不一致，因此需要 rename
        # 安装系统时 ens18
        # 普通内核   ens18
        # 云内核     enp6s18
        # https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=928923

        # 头部
        get_netconf_to mac_addr
        {
            echo
            # 这是标记，fix-eth-name 要用，不要删除
            # shellcheck disable=SC2154
            echo "# mac $mac_addr"
            echo $mode $ethx
        } >>$conf_file

        # ipv4
        if is_dhcpv4; then
            echo "iface $ethx inet dhcp" >>$conf_file

        elif is_staticv4; then
            get_netconf_to ipv4_addr
            get_netconf_to ipv4_gateway
            cat <<EOF >>$conf_file
iface $ethx inet static
    address $ipv4_addr
    gateway $ipv4_gateway
EOF
            # dns
            if list=$(get_current_dns 4); then
                for dns in $list; do
                    cat <<EOF >>$conf_file
    dns-nameservers $dns
EOF
                done
            fi
        fi

        # ipv6
        has_inet6=true
        if is_slaac; then
            echo "iface $ethx inet6 auto" >>$conf_file

        elif is_dhcpv6; then
            echo "iface $ethx inet6 dhcp" >>$conf_file

        elif is_staticv6; then
            get_netconf_to ipv6_addr
            get_netconf_to ipv6_gateway
            cat <<EOF >>$conf_file
iface $ethx inet6 static
    address $ipv6_addr
    gateway $ipv6_gateway
EOF
        else
            has_inet6=false
        fi

        # accept_ra / autoconf 只能写在 inet6 段里：落在 inet 段下 ifupdown 报 misplaced option，网络起不来
        if ! $has_inet6 && [ "$distro" != alpine ] &&
            { should_disable_accept_ra || should_disable_autoconf; }; then
            echo "iface $ethx inet6 manual" >>$conf_file
        fi

        # dns
        # 有 ipv6 但需设置 dns 的情况
        if is_need_manual_set_dnsv6; then
            for dns in $(get_current_dns 6); do
                cat <<EOF >>$conf_file
    dns-nameserver $dns
EOF
            done
        fi

        # 禁用 ra
        if should_disable_accept_ra; then
            if [ "$distro" = alpine ]; then
                cat <<EOF >>$conf_file
    pre-up echo 0 >/proc/sys/net/ipv6/conf/$ethx/accept_ra
EOF
            else
                cat <<EOF >>$conf_file
    accept_ra 0
EOF
            fi
        fi

        # 禁用 autoconf
        if should_disable_autoconf; then
            if [ "$distro" = alpine ]; then
                cat <<EOF >>$conf_file
    pre-up echo 0 >/proc/sys/net/ipv6/conf/$ethx/autoconf
EOF
            else
                cat <<EOF >>$conf_file
    autoconf 0
EOF
            fi
        fi
    done
}

# 不够严谨，谨慎使用

install_alpine() {
    need_ram=512
    swap_size=$(get_need_swap_size $need_ram)
    [ "$swap_size" -gt 0 ] && hack_lowram=true || hack_lowram=false

    # alpine 安装时会自动检测安装需要的 firmware
    # https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-disk.in#L421
    # 但如果没有 modloop 则无法检测
    # 所以删除 modloop 前先记录用到的 firmware 包
    fw_pkgs=$(get_alpine_firmware_pkgs)

    if $hack_lowram; then
        # 预先加载需要的模块
        if rc-service -q modloop status; then
            modules="ext4 vfat nls_utf8 nls_cp437"
            for mod in $modules; do
                modprobe $mod
            done
            # crc32c 等于 crc32c-intel
            # 没有 sse4.2 的机器加载 crc32c 时会报错 modprobe: ERROR: could not insert 'crc32c_intel': No such device
            modprobe crc32c || modprobe crc32c-generic
        fi

        # 删除 modloop ，释放内存
        ensure_service_stopped modloop
        rm -f /lib/modloop-lts /lib/modloop-virt
    fi

    # bios机器用 setup-disk 自动分区会有 boot 分区
    # 因此手动分区安装
    step partition "partition the disk"
    create_part
    mount_part_basic_layout /os /os/boot/efi

    # 创建 swap
    if $hack_lowram; then
        create_swap $swap_size /os/swapfile
    fi

    # 网络配置
    create_ifupdown_config /etc/network/interfaces
    echo
    cat -n /etc/network/interfaces
    echo

    # 在 arm netboot initramfs init 中
    # 如果识别到rtc硬件，就往系统添加hwclock服务，否则添加swclock
    # 这个设置也被复制到安装的系统中
    # 但是从initramfs chroot到真正的系统后，是能识别rtc硬件的
    # 所以我们手动改用hwclock修复这个问题
    rc-update del swclock boot || true
    rc-update add hwclock boot

    # 通过 setup-alpine 安装会启用以下几个服务
    # https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-alpine.in#L229

    # boot
    rc-update add networking boot
    rc-update add seedrng boot

    # default
    rc-update add crond
    if [ -e /dev/input/event0 ]; then
        rc-update add acpid
    fi

    # 如果是 vm 就用 virt 内核
    if is_virt; then
        kernel_flavor="virt"
    else
        kernel_flavor="lts"
    fi

    # setup-disk 安装 grub 跳过了添加引导项到 nvram
    # 防止部分机器不会 fallback 到 bootx64.efi
    if is_efi; then
        apk add efibootmgr
        sed -i 's/--no-nvram//' "$(which setup-disk)"
    fi

    # 安装到硬盘
    # alpine默认使用 syslinux (efi 环境除外)，这里强制使用 grub，方便用脚本再次重装
    KERNELOPTS="$(get_ttys console=)"
    export KERNELOPTS
    export BOOTLOADER="grub"
    step install "install alpine"
    setup-disk -m sys -k $kernel_flavor /os

    # 删除 setup-disk 时自动安装的包
    apk del e2fsprogs dosfstools efibootmgr grub*

    step configure "configure the system"

    # setup-disk 经 lbu 把临时系统的 /etc/resolv.conf 带了进来
    del_search_domains /os
    set_hostname /os

    # 如果没有挂载 /proc

    # 1. chroot /os setup-keymap us us 会报错
    # grep: /proc/filesystems: No such file or directory

    # 2. 安装固件微码会触发 grub-probe，如果没挂载会报错
    # Executing grub-2.12-r5.trigger
    # /usr/sbin/grub-probe: error: failed to get canonical path of `/dev/vda1'.
    # ERROR: grub-2.12-r5.trigger: script exited with error 1

    mount_pseudo_fs /os

    add_pci_hyperv_to_initramfs_if_needed
    persist_tencent_disk_limit /os

    # 安装到硬盘后才安装各种应用
    # 避免占用 Live OS 内存

    # 网络
    # udhcpc
    # 坑1 ip -4 addr 无法知道是否是 dhcp
    # 坑2 networking 服务不会运行 udhcpc6
    # 坑3 h3c 移动云电脑 udhcpc6 无法获取 dhcpv6

    # dhcpcd
    # 坑1 slaac默认开了隐私保护，造成ip和后台面板不一致

    # slaac方案1: udhcpc + rdnssd
    # slaac方案2: dhcpcd + 关闭隐私保护
    # dhcpv6方案: dhcpcd

    # 综合使用dhcpcd方案
    # 1 无需改动/etc/network/interfaces，自动根据ra使用slaac和dhcpv6
    # 2 自带rdnss支持
    # 3 唯一要做的是关闭隐私保护

    # 安装 dhcpcd
    chroot /os apk add dhcpcd
    chroot /os sed -i '/^slaac private/s/^/#/' /etc/dhcpcd.conf
    chroot /os sed -i '/^#slaac hwaddr/s/^#//' /etc/dhcpcd.conf

    # 安装其他部件
    # Live OS 里重跑时它报「loadkmap failed to stop」，装好的系统不受影响，所以成功时不显示输出
    if ! chroot /os setup-keymap us us >/tmp/setup-keymap.log 2>&1; then
        cat /tmp/setup-keymap.log
        error_and_exit "setup-keymap failed"
    fi
    chroot /os setup-timezone -i "${timezone:-UTC}"
    # setup-ntp 先把 ntpd 加进运行级、最后在 chroot 里启动它，启动那一步常失败而返回非零；
    # 进了运行级就是配好了，装好的系统开机就跑
    if ! chroot /os setup-ntp busybox >/tmp/setup-ntp.log 2>&1 &&
        ! [ -e /os/etc/runlevels/default/ntpd ]; then
        cat /tmp/setup-ntp.log
        warn "setup-ntp failed; the installed system has no NTP client configured"
    fi
    if [ -f /os/etc/conf.d/ntpd ]; then
        sed -i "s/-p pool\.ntp\.org/-p $(get_ntp_server)/" /os/etc/conf.d/ntpd
    fi

    # 设置公钥
    if is_need_set_ssh_keys; then
        set_ssh_keys /os
        disable_root_password /os
    fi

    cp /repo/fix-eth-name.sh /os/fix-eth-name.sh
    cp /repo/fix-eth-name.initd /os/etc/init.d/fix-eth-name
    chmod +x /os/etc/init.d/fix-eth-name
    chroot /os rc-update add fix-eth-name boot

    # setup-disk 会自动选择固件，但不包括微码？
    # https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-disk.in#L421
    if fw_pkgs="$fw_pkgs $(get_ucode_firmware_pkgs)" && [ -n "$fw_pkgs" ]; then
        chroot /os apk add $fw_pkgs
    fi

    # 3.19 或以上，非 efi 需要手动安装 grub
    if ! is_efi; then
        chroot /os grub-install --target=i386-pc /dev/$xda
    fi

    # efi grub 添加 fwsetup 条目
    chroot /os update-grub

    # 是否保留 swap
    if [ -e /os/swapfile ]; then
        if false; then
            echo "/swapfile swap swap defaults 0 0" >>/os/etc/fstab
            ln -sf /etc/init.d/swap /os/etc/runlevels/boot/swap
        else
            swapoff -a
            rm /os/swapfile
        fi
    fi
}

# Azure 的 NVMe 盘挂在 Hyper-V 的虚拟 PCI 总线后面，mkinitfs 默认不带 pci-hyperv，装好的 alpine 开机找不到根
add_pci_hyperv_to_initramfs_if_needed() {
    if get_drivers /sys/block/$xda | grep -qx pci_hyperv; then
        info false "Azure: the disk sits behind Hyper-V's virtual PCI bus, adding pci-hyperv to the initramfs"
        echo 'kernel/drivers/pci/controller/pci-hyperv.ko*' >/os/etc/mkinitfs/features.d/pci-hyperv.modules
        sed -i '/^features="/s/"$/ pci-hyperv"/' /os/etc/mkinitfs/mkinitfs.conf
        chroot /os mkinitfs -k "$(basename /os/lib/modules/*-*)"
    fi
}

get_cpu_vendor() {
    cpu_vendor=$(grep 'vendor_id' /proc/cpuinfo | head -1 | awk '{print $NF}')
    case "$cpu_vendor" in
    GenuineIntel) echo intel ;;
    AuthenticAMD) echo amd ;;
    *) echo other ;;
    esac
}

add_systemd_service() {
    local os_dir=$1
    local service_name=$2

    cp "/repo/$service_name.service" "$os_dir/etc/systemd/system/$service_name.service"
    chroot "$os_dir" systemctl enable "$service_name.service"

    # aosc 首次开机会执行 preset-all
    # 因此需要设置 fix-eth-name 的 preset 状态
    # 不然首次开机 /etc/systemd/system/multi-user.target.wants/fix-eth-name.service 会被删除
    # 通常 /etc/systemd/system-preset/ 文件夹要新建，因此不放在这里

    # 可能是 /usr/lib/systemd/system-preset/ 或者 /lib/systemd/system-preset/
    if [ -d "$os_dir/usr/lib/systemd/system-preset" ]; then
        echo "enable $service_name.service" >"$os_dir/usr/lib/systemd/system-preset/01-$service_name.preset"
    else
        echo "enable $service_name.service" >"$os_dir/lib/systemd/system-preset/01-$service_name.preset"
    fi
}

add_fix_eth_name_systemd_service() {
    local os_dir=$1

    # 无需执行 systemctl daemon-reload
    # 因为 chroot 下执行会提示 Running in chroot, ignoring command 'daemon-reload'
    cp /repo/fix-eth-name.sh "$os_dir/fix-eth-name.sh"
    add_systemd_service "$os_dir" fix-eth-name
}

# --hostname 给了就用它；没给时只给没带主机名的 Debian 镜像（12 / 13）填 debian，不然开机成了 localhost。
# /etc/hostname 只写第一段，全名与短名写进 hosts 的 127.0.1.1 行：没有 nss-myhostname 的系统靠它解析本机名
set_hostname() {
    # shellcheck disable=SC2154
    local os_dir=$1 name=$hostname short
    if [ -z "$name" ]; then
        if [ "$distro" != debian ] || grep -qs '[^[:space:]]' "$os_dir/etc/hostname"; then
            return 0
        fi
        name=debian
    fi
    short=${name%%.*}
    echo "$short" >"$os_dir/etc/hostname"
    sed -i '/^127\.0\.1\.1[[:space:]]/d' "$os_dir/etc/hosts"
    if [ "$short" = "$name" ]; then
        printf '127.0.1.1\t%s\n' "$name" >>"$os_dir/etc/hosts"
    else
        printf '127.0.1.1\t%s %s\n' "$name" "$short" >>"$os_dir/etc/hosts"
    fi
}

basic_init() {
    os_dir=$1

    # 此时不能用
    # chroot $os_dir timedatectl set-timezone $timezone
    # Failed to create bus connection: No such file or directory

    # debian 11 没有 systemd-firstboot
    if is_have_cmd_on_disk $os_dir systemd-firstboot; then
        if chroot $os_dir systemd-firstboot --help | grep -wq '\--force'; then
            chroot $os_dir systemd-firstboot --timezone="${timezone:-UTC}" --force
        else
            chroot $os_dir systemd-firstboot --timezone="${timezone:-UTC}"
        fi
    fi

    set_hostname $os_dir

    # gentoo 不会自动创建 machine-id
    clear_machine_id $os_dir

    # sshd
    chroot $os_dir ssh-keygen -A

    sshd_enabled=false
    sshs="sshd.service ssh.service sshd.socket ssh.socket"
    for i in $sshs; do
        if chroot $os_dir systemctl -q is-enabled $i; then
            sshd_enabled=true
            break
        fi
    done
    if ! $sshd_enabled; then
        for i in $sshs; do
            if chroot $os_dir systemctl -q enable $i; then
                break
            fi
        done
    fi

    if is_need_change_ssh_port; then
        change_ssh_port $os_dir $ssh_port
    fi

    # 公钥/密码
    if is_need_set_ssh_keys; then
        set_ssh_keys $os_dir
        disable_root_password $os_dir
    else
        change_root_password $os_dir
        allow_root_password_login $os_dir
        allow_password_login $os_dir
    fi

    # 下载 fix-eth-name.service
    # 即使开了 net.ifnames=0 也需要
    # 因为 alpine live 和目标系统的网卡顺序可能不同
    add_fix_eth_name_systemd_service $os_dir
}

get_http_file_size() {
    url=$1

    # 网址重定向可能得到多个 Content-Length, 选最后一个
    wget --spider -S "$url" 2>&1 | grep 'Content-Length:' |
        tail -1 | awk '{print $2}' | grep .
}

aria2c() {
    if ! is_have_cmd aria2c; then
        apk add aria2
    fi

    # stdbuf 在 coreutils 包里面
    if ! is_have_cmd stdbuf; then
        apk add coreutils
    fi

    # 显示 url
    show_url_in_args "$@" >&2

    retry 5 5 stdbuf -oL -eL aria2c \
        -x4 \
        --allow-overwrite=true \
        --summary-interval=0 \
        --max-tries 1 \
        "$@"
}

pipe_extract() {
    # alpine busybox 自带 gzip，但官方版也许性能更好
    case "$img_type_warp" in
    xz | gzip | zstd)
        apk add $img_type_warp
        "$img_type_warp" -dc
        ;;
    # 经 cat 出去：GNU tar 的 stdout 可 seek 时（块设备）解稀疏成员会跳过空洞不写零，
    # 盘上留下旧数据（Debian 的 tar.xz 镜像就是稀疏的）。调用方须开 pipefail，否则 tar
    # 失败被 cat 的 0 盖掉
    tar)
        apk add tar
        tar x -O | cat
        ;;
    tar.*)
        type=$(echo "$img_type_warp" | cut -d. -f2)
        apk add tar "$type"
        tar x "--$type" -O | cat
        ;;
    '') cat ;;
    *) error_and_exit "Not supported img_type_warp: $img_type_warp" ;;
    esac
}

dd_raw_with_extract() {
    # 用官方 wget，一来带进度条，二来自带重试功能
    apk add wget
    begin_disk_write

    # 管道默认只看最后一段的退出码：下载中途断开时 cat 照样返回 0，半张镜像会被当成 dd 成功。
    # wget 的输出照常上屏，经 tee 另存一份给报错原因用；tee 在管道里同步跑完，读文件时已写完
    # shellcheck disable=SC2154
    if ! (set -o pipefail &&
        { wget $img -O- 2>&1 >&3 | tee /tmp/dd_wget_stderr >&2; } 3>&1 |
        pipe_extract >/dev/$xda 2>/tmp/dd_stderr); then
        # vhd 文件结尾有 512 字节额外信息，可以忽略
        if grep -iq 'No space' /tmp/dd_stderr; then
            apk add parted
            disk_size=$(get_disk_size /dev/$xda)
            disk_end=$((disk_size - 1))

            # 如果报错，那大概是因为镜像比硬盘大
            if last_part_end=$(parted -sf /dev/$xda 'unit b print' ---pretend-input-tty |
                del_empty_lines | tail -1 | awk '{print $3}' | sed 's/B//' | grep .); then

                echo "Last part end: $last_part_end"
                echo "Disk end:      $disk_end"

                if [ "$last_part_end" -le "$disk_end" ]; then
                    echo "Safely ignore no space error."
                    return
                fi
            fi
        fi
        # 进度条用 \r 刷新，换成换行后取最后几行，就是 wget 自己说的失败原因
        error_and_exit "Writing $img to /dev/$xda failed:
$(cat /tmp/dd_stderr; tr '\r' '\n' </tmp/dd_wget_stderr | grep . | tail -n 3)"
    fi
}

# dd 照原样写镜像：这台机器静态配置的那一族，镜像得自己配上，否则重启后起不来（全静态就失联）
warn_static_network() {
    local ethx list='' hint
    for ethx in $(get_eths); do
        if is_staticv4; then
            get_netconf_to ipv4_addr
            get_netconf_to ipv4_gateway
            list="$list
  $ethx IPv4 $ipv4_addr via $ipv4_gateway"
        fi
        if is_staticv6; then
            get_netconf_to ipv6_addr
            get_netconf_to ipv6_gateway
            list="$list
  $ethx IPv6 $ipv6_addr via $ipv6_gateway"
        fi
    done
    if [ -z "$list" ]; then
        return
    fi
    # shellcheck disable=SC2154
    if [ "$cloud_init_network" = 1 ]; then
        hint="--cloud-init-network is on: after the write they go into the image's cloud-init seed."
    else
        hint="For an image with cloud-init, --cloud-init-network writes them into its seed after the write."
    fi
    warn "This machine's network is configured statically:$list
dd writes the image as it is, so the image must set these up itself or they stay down after the reboot.
$hint"
}

# 镜像的根：挂载点本身，或其下一层（btrfs 的根可以在子卷里，如 Fedora 的 root、Ubuntu 的 @）
find_cloud_init_root() {
    local dir
    for dir in "$1" "$1"/*; do
        if [ -d "$dir/etc/cloud" ] && is_have_cmd_on_disk "$dir" cloud-init; then
            echo "$dir"
            return
        fi
    done
    return 1
}

# 只写网络：user-data 是空映射（只有表头时 cloud-init 报 empty cloud config、状态成 degraded），
# meta-data 只给 instance-id（每次不同，开过机的镜像也当新实例重套网络）。ds-identify 见到这两个
# 文件才认 NoCloud；cidata 盘上的后读，带 network-config 就整份顶掉这里的
write_cloud_init_seed() {
    local part fstype root='' unsupported='' seed dir cidata
    update_part
    mkdir -p /os
    for part in $(lsblk -lnpo NAME /dev/$xda); do
        fstype=$(lsblk -dno FSTYPE "$part")
        case "$fstype" in
        ext4 | xfs | btrfs) ;;
        LVM2_member | crypto_LUKS)
            unsupported="$unsupported $part ($fstype)"
            continue
            ;;
        *) continue ;;
        esac
        if ! mount -o ro -t "$fstype" "$part" /os; then
            error_and_exit "Could not mount $part ($fstype) to look for cloud-init in the image."
        fi
        if root=$(find_cloud_init_root /os); then
            break
        fi
        umount /os
    done

    if [ -z "$root" ]; then
        if [ -n "$unsupported" ]; then
            warn "The image keeps partitions on LVM or LUKS, which are not looked into:$unsupported. No cloud-init seed written."
        else
            warn "No cloud-init found on the image's ext4, xfs or btrfs partitions. No cloud-init seed written."
        fi
        return
    fi

    for dir in nocloud nocloud-net; do
        if [ -f "$root/var/lib/cloud/seed/$dir/meta-data" ]; then
            warn "The image already carries a NoCloud seed (/var/lib/cloud/seed/$dir); left as it is."
            umount /os
            return
        fi
    done
    if [ -f "$root/etc/cloud/cloud-init.disabled" ]; then
        warn "cloud-init is disabled in the image (/etc/cloud/cloud-init.disabled). No cloud-init seed written."
    elif [ -f "$root/etc/fstab" ] &&
        awk '$1 !~ /^#/ && ($2 == "/var" || $2 == "/var/lib" || $2 == "/var/lib/cloud")' "$root/etc/fstab" | grep -q .; then
        warn "The image mounts /var separately, which is not followed. No cloud-init seed written."
    else
        mount -o remount,rw /os
        seed=$root/var/lib/cloud/seed/nocloud
        mkdir -p "$seed"
        echo "instance-id: reinstall-$(date +%s)" >"$seed/meta-data"
        printf '#cloud-config\n{}\n' >"$seed/user-data"
        create_cloud_init_network_v2 "$seed/network-config"
        info "Cloud-init seed network-config"
        cat -n "$seed/network-config" >&2
        if cidata=$(lsblk -lnpo NAME,LABEL | awk 'tolower($2) == "cidata" {print $1; exit}' | grep .); then
            warn "A seed disk labelled cidata is attached ($cidata). cloud-init in the image reads it as well, and its network config, if it has one, replaces the one written here."
        fi
    fi
    umount /os
}

get_disk_size() {
    blockdev --getsize64 "$1"
}

is_xda_gt_2t() {
    disk_size=$(get_disk_size /dev/$xda)
    disk_2t=$((2 * 1024 * 1024 * 1024 * 1024))
    [ "$disk_size" -gt "$disk_2t" ]
}

create_part() {
    # 除了 dd 都会用到
    # 分区工具
    apk add parted e2fsprogs
    if is_efi; then
        apk add dosfstools
    fi

    # 先清掉整块盘上的旧签名：旧的分区表、文件系统、RAID 签名留着，新分区会被认错，alpine 会装不上
    apk add wipefs
    begin_disk_write
    wipefs -a -f /dev/$xda
    apk del wipefs

    # xda*1 星号用于 nvme0n1p1 的字母 p
    # shellcheck disable=SC2154
    if is_use_cloud_image; then
        installer_part_size="$(get_cloud_image_part_size)"
        if [ "$distro" = ubuntu ]; then
            # install_qcow_by_copy 写死 1=efi 2=os 3=installer
            # 三种固件/容量下编号必须一致，所以一律 gpt，且 os 分区留给目标系统自己的 mkfs
            if is_efi; then
                parted /dev/$xda -s -- \
                    mklabel gpt \
                    mkpart '" "' fat32 1MiB 101MiB \
                    mkpart '" "' ext4 101MiB -$installer_part_size \
                    mkpart '" "' ext4 -$installer_part_size 100% \
                    set 1 esp on
                update_part

                mkfs.fat -n efi /dev/$xda*1           #1 efi
                echo                                  #2 os 用目标系统的格式化工具
                mkfs.ext4 -F -L installer /dev/$xda*3 #3 installer
            else
                parted /dev/$xda -s -- \
                    mklabel gpt \
                    mkpart '" "' ext4 1MiB 2MiB \
                    mkpart '" "' ext4 2MiB -$installer_part_size \
                    mkpart '" "' ext4 -$installer_part_size 100% \
                    set 1 bios_grub on
                update_part

                echo                                  #1 bios_boot
                echo                                  #2 os 用目标系统的格式化工具
                mkfs.ext4 -F -L installer /dev/$xda*3 #3 installer
            fi
        else
            # debian 把整个 qcow2 dd 到硬盘，分区表随之被覆盖，只需要 os + installer
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' ext4 1MiB -$installer_part_size \
                mkpart '" "' ext4 -$installer_part_size 100%
            update_part

            mkfs.ext4 -F -L os /dev/$xda*1        #1 os
            mkfs.ext4 -F -L installer /dev/$xda*2 #2 installer
        fi
    else
        # alpine 本身关闭了 64bit ext4
        # https://gitlab.alpinelinux.org/alpine/alpine-conf/-/blob/3.18.1/setup-disk.in?ref_type=tags#L908
        # 而且 alpine 的 extlinux 不兼容 64bit ext4
        ext4_opts="-O ^64bit"
        if is_efi; then
            # efi
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' fat32 1MiB 101MiB \
                mkpart '" "' ext4 101MiB 100% \
                set 1 boot on
            update_part

            mkfs.fat /dev/$xda*1                #1 efi
            mkfs.ext4 -F $ext4_opts /dev/$xda*2 #2 os
        elif is_xda_gt_2t; then
            # bios > 2t
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' ext4 1MiB 2MiB \
                mkpart '" "' ext4 2MiB 100% \
                set 1 bios_grub on
            update_part

            echo                                #1 bios_boot
            mkfs.ext4 -F $ext4_opts /dev/$xda*2 #2 os
        else
            # bios
            parted /dev/$xda -s -- \
                mklabel msdos \
                mkpart primary ext4 1MiB 100% \
                set 1 boot on
            update_part

            mkfs.ext4 -F $ext4_opts /dev/$xda*1 #1 os
        fi
    fi

    update_part

    # alpine 删除分区工具，防止 256M 小机爆内存
    # setup-disk /dev/sda 会保留格式化工具，我们也保留
    if [ "$distro" = alpine ]; then
        apk del parted
    fi
}

mount_pseudo_fs() {
    os_dir=$1

    mkdir -p $os_dir/proc/ $os_dir/sys/ $os_dir/dev/ $os_dir/run/

    # https://wiki.archlinux.org/title/Chroot#Using_chroot
    mount -t proc /proc $os_dir/proc/
    mount -t sysfs /sys $os_dir/sys/
    mount --rbind /dev $os_dir/dev/
    mount --rbind /run $os_dir/run/
    if is_efi; then
        mount --rbind /sys/firmware/efi/efivars $os_dir/sys/firmware/efi/efivars/
    fi
}

# cloud-init 的 v2 网络配置，也就是 netplan 的格式：按 MAC 匹配、不写 set-name，网卡保留系统起的名字；
# 默认路由一律 on-link（见过 /48 配网段外的 v6 网关）；SLAAC 也写 dhcp6，同 cloud-init 把 v1 转 netplan。
# 探测会往 stdout 打字（rdisc6 的结果等），所以先探完再成段写进 $1
create_cloud_init_network_v2() {
    local file=$1 ethx v4 v6 accept_ra dns cur ns driver
    echo 'version: 2' >"$file"
    echo 'ethernets:' >>"$file"
    for ethx in $(get_eths); do
        get_netconf_to mac_addr
        v4='' v6='' accept_ra='' dns='' driver=''
        # Azure 加速网络的 VF 与合成网卡同一个 MAC、挂在它下面。只认 MAC 的话 networkd 把 VF 也配上，
        # 卡在 configuring，ubuntu 等 wait-online 超时、开机 degraded。有这样的网卡时再按驱动认
        if ip -o link | grep -i "$mac_addr" | grep -q "master $ethx " &&
            [ -e /sys/class/net/$ethx/device/driver ]; then
            driver=$(basename "$(readlink -f /sys/class/net/$ethx/device/driver)")
            info false "$ethx has a NIC with its MAC under it (Azure's accelerated networking VF): matching $ethx by driver $driver as well"
        fi
        if is_dhcpv4; then
            v4=dhcp
        elif is_staticv4; then
            v4=static
            get_netconf_to ipv4_addr
            get_netconf_to ipv4_gateway
            dns=$(get_current_dns 4)
        fi
        if is_slaac || is_dhcpv6; then
            v6=dhcp
        elif is_staticv6; then
            v6=static
            get_netconf_to ipv6_addr
            get_netconf_to ipv6_gateway
        fi
        if should_disable_accept_ra; then
            accept_ra=false
        fi
        if is_need_manual_set_dnsv6; then
            dns="$dns $(get_current_dns 6)"
        fi

        {
            echo "  $ethx:"
            echo "    match:"
            echo "      macaddress: \"$mac_addr\""
            if [ -n "$driver" ]; then
                echo "      driver: \"$driver\""
            fi
            if [ "$v4" = dhcp ]; then
                echo "    dhcp4: true"
            fi
            if [ "$v6" = dhcp ]; then
                echo "    dhcp6: true"
            fi
            if [ -n "$accept_ra" ]; then
                echo "    accept-ra: $accept_ra"
            fi
            if [ "$v4" = static ] || [ "$v6" = static ]; then
                echo "    addresses:"
                if [ "$v4" = static ]; then
                    echo "      - \"$ipv4_addr\""
                fi
                if [ "$v6" = static ]; then
                    echo "      - \"$ipv6_addr\""
                fi
                echo "    routes:"
                if [ "$v4" = static ]; then
                    echo "      - to: \"0.0.0.0/0\""
                    echo "        via: \"$ipv4_gateway\""
                    echo "        on-link: true"
                fi
                if [ "$v6" = static ]; then
                    echo "      - to: \"::/0\""
                    echo "        via: \"$ipv6_gateway\""
                    echo "        on-link: true"
                fi
            fi
            ns=''
            for cur in $dns; do
                ns="$ns
        - \"$cur\""
            done
            if [ -n "$ns" ]; then
                echo "    nameservers:"
                echo "      addresses:$ns"
            fi
        } >>"$file"
    done
}

# netplan 的配置就是 v2 网络配置外面套一层 network:；文件里有地址与路由，netplan 见别人可读会告警
create_netplan_config() {
    create_cloud_init_network_v2 /tmp/network-config
    {
        echo 'network:'
        sed 's/^/  /' /tmp/network-config
    } >"$1"
    chmod 600 "$1"
}

# 实测没用，生成的 machine-id 是固定的
# 而且 lightsail centos 9 模板 machine-id 也是相同的，显然相同 id 不是个问题
clear_machine_id() {
    os_dir=$1

    # https://www.freedesktop.org/software/systemd/man/latest/machine-id.html
    # gentoo 不会自动创建该文件
    echo uninitialized >$os_dir/etc/machine-id

    # https://build.opensuse.org/projects/Virtualization:Appliances:Images:openSUSE-Leap-15.5/packages/kiwi-templates-Minimal/files/config.sh?expand=1
    rm -f $os_dir/var/lib/systemd/random-seed
}

get_axx64() {
    case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
    esac
}

is_file_or_link() {
    # -e / -f 坏软连接，返回 false
    # -L 坏软连接，返回 true
    [ -f $1 ] || [ -L $1 ]
}

cp_resolv_conf() {
    os_dir=$1
    if is_file_or_link $os_dir/etc/resolv.conf &&
        ! is_file_or_link $os_dir/etc/resolv.conf.orig; then
        mv $os_dir/etc/resolv.conf $os_dir/etc/resolv.conf.orig
    fi
    cp -f /etc/resolv.conf $os_dir/etc/resolv.conf
}

restore_resolv_conf() {
    os_dir=$1
    if is_file_or_link $os_dir/etc/resolv.conf.orig; then
        mv -f $os_dir/etc/resolv.conf.orig $os_dir/etc/resolv.conf
    fi
}

keep_now_resolv_conf() {
    os_dir=$1
    rm -f $os_dir/etc/resolv.conf.orig
    del_search_domains $os_dir
}

# 临时系统 resolv.conf 里的 search / domain（见过 search installer）不属于新系统，
# 留着的话短主机名的查询都会补上它发给公共解析器
del_search_domains() {
    if [ -f $1/etc/resolv.conf ]; then
        sed -Ei '/^(search|domain)([[:space:]]|$)/d' $1/etc/resolv.conf
    fi
}

# 抄 https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-disk.in#L421
get_alpine_firmware_pkgs() {
    # 需要有 modloop，不然 modinfo 会报错
    start_modloop >&2

    # 如果不在单独的文件夹，则用 linux-firmware-other
    # 如果在单独的文件夹，则用 linux-firmware-xxx
    # 如果不需要 firmware，则用 linux-firmware-none
    firmware_pkgs=$(
        cd /sys/module && modinfo -F firmware -- * 2>/dev/null |
            awk -F/ '{print $1 == $0 ? "linux-firmware-other" : "linux-firmware-"$1}' |
            sort -u
    )

    # 使用 command 因为自己覆盖了 apk 添加了 >&2
    retry 5 command apk search --quiet --exact ${firmware_pkgs:-linux-firmware-none}
}

get_ucode_firmware_pkgs() {
    is_virt && return

    case "$distro-$(get_cpu_vendor)" in
    # alpine 的 linux-firmware 以文件夹进行拆分
    # setup-alpine 会自动安装需要的 firmware（modloop 没挂载则无效）
    # https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-disk.in#L421
    alpine-intel) echo intel-ucode ;;
    alpine-amd) echo amd-ucode ;;
    alpine-*) ;;

    debian-intel) echo firmware-linux intel-microcode ;;
    debian-amd) echo firmware-linux amd64-microcode ;;
    debian-*) echo firmware-linux ;;

    ubuntu-intel) echo linux-firmware intel-microcode ;;
    ubuntu-amd) echo linux-firmware amd64-microcode ;;
    ubuntu-*) echo linux-firmware ;;
    esac
}

# 只禁用不删：ubuntu-server-minimal、ubuntu-cloud-minimal 依赖 cloud-init，删它会连带 autoremove 掉这些元包
disable_cloud_init() {
    os_dir=$1

    if is_have_cmd_on_disk $os_dir cloud-init; then
        info "Disable Cloud-Init"
        touch $os_dir/etc/cloud/cloud-init.disabled
    fi
}

modify_linux() {
    os_dir=$1
    info "Modify Linux"

    find_and_mount() {
        mount_point=$1
        mount_dev=$(awk "\$2==\"$mount_point\" {print \$1}" $os_dir/etc/fstab)
        if [ -n "$mount_dev" ]; then
            mount $mount_dev $os_dir$mount_point
        fi
    }

    # debian
    # 1. 修复网络问题
    # 2. 添加微码+固件
    if [ "$distro" = debian ]; then
        # 修复 onlink 网关
        # add_onlink_script_if_need

        mount_pseudo_fs $os_dir
        cp_resolv_conf $os_dir
        find_and_mount /boot
        find_and_mount /boot/efi

        # 安装期间只用 prepare_debian_sources 探过的源；≤11 装完也用它，≥12 装完用回镜像自带的
        cp $apt_dir/sources.list $os_dir/etc/apt/reinstall.list
        apt_opts="-o Dir::Etc::SourceList=/etc/apt/reinstall.list -o Dir::Etc::SourceParts=-"
        # shellcheck disable=SC2154
        if [ "$releasever" -le 11 ]; then
            cp $apt_dir/keyring.gpg $os_dir/usr/share/keyrings/freexian-archive-extended-lts.gpg
            cp $apt_dir/sources.list $os_dir/etc/apt/sources.list
        fi

        disable_cloud_init $os_dir

        # 获取当前开启的 Components, 后面要用
        if [ -f $os_dir/etc/apt/sources.list.d/debian.sources ]; then
            comps=$(grep ^Components: $os_dir/etc/apt/sources.list.d/debian.sources | head -1 | cut -d' ' -f2-)
        else
            comps=$(grep '^deb ' $os_dir/etc/apt/sources.list | head -1 | cut -d' ' -f4-)
        fi

        # 镜像自带的就是通用内核，只把它升到源里的最新版：镜像构建之后发的内核安全更新也装上
        chroot_apt_install $os_dir "linux-image-$(get_axx64)"

        # 微码+固件
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            #  debian 10 11 的 iucode-tool 在 contrib 里面
            #  debian 12 的 iucode-tool 在 main 里面
            [ "$releasever" -ge 12 ] &&
                comps_to_add=non-free-firmware ||
                comps_to_add="contrib non-free"

            if [ -f $os_dir/etc/apt/sources.list.d/debian.sources ]; then
                file=$os_dir/etc/apt/sources.list.d/debian.sources
                search='^[# ]*Components:'
            else
                file=$os_dir/etc/apt/sources.list
                search='^[# ]*deb'
            fi

            for c in $comps_to_add; do
                if ! echo "$comps" | grep -wq "$c"; then
                    sed -Ei "/$search/s/$/ $c/" $file
                fi
            done

            chroot_apt_install $os_dir $fw_pkgs
        fi

        # genericcloud 删除以下文件开机时才会显示 grub 菜单
        # https://salsa.debian.org/cloud-team/debian-cloud-images/-/tree/master/config_space/bookworm/files/etc/default/grub.d
        rm -f $os_dir/etc/default/grub.d/10_cloud.cfg
        rm -f $os_dir/etc/default/grub.d/15_timeout.cfg
        chroot $os_dir update-grub

        if true; then
            # 如果使用 nocloud 镜像
            chroot_apt_install $os_dir openssh-server
        else
            # 如果使用 genericcloud 镜像

            # 还原默认配置并创建 key
            # cat $os_dir/usr/share/openssh/sshd_config $os_dir/etc/ssh/sshd_config
            # chroot $os_dir ssh-keygen -A
            rm -rf $os_dir/etc/ssh/sshd_config
            UCF_FORCE_CONFFMISS=1 chroot $os_dir dpkg-reconfigure openssh-server
        fi

        # 网络：12 起镜像自带 netplan + networkd + resolved，就用它们；10 / 11 是 ifupdown
        if [ "$releasever" -ge 12 ]; then
            # 镜像自带的 netplan 文件（现在是 90-default.yaml）按网卡名全开 DHCP，生成的 .network 按文件名
            # 排在按 MAC 匹配的那份前面：留下任何一份，静态配置都会被它盖掉
            rm -f $os_dir/etc/netplan/*.yaml
            create_netplan_config $os_dir/etc/netplan/50-cloud-init.yaml

            # Debian 编译时默认开 LLMNR：resolved 向同网段应答主机名；13 起单标签名只发 LLMNR 组播，
            # 同网段谁都能抢答，查不到要等约 8 秒
            mkdir -p $os_dir/etc/systemd/resolved.conf.d
            cat <<EOF >$os_dir/etc/systemd/resolved.conf.d/90-disable-llmnr-mdns.conf
[Resolve]
LLMNR=no
MulticastDNS=no
EOF
            # resolv.conf 要还回 resolved 的符号链接，否则 DNS 冻结在临时系统的那几个
            restore_resolv_conf $os_dir
        else
            create_ifupdown_config $os_dir/etc/network/interfaces

            # 镜像的 cloud-ifupdown-helper 给 interfaces 里没有的网卡往 /run/network/interfaces.d 写 DHCP 配置、启动 ifup@，
            # 我们的 interfaces 不引用那里；首启时 interfaces 里还是临时系统的 eth0，ifup@ 必然失败，系统成了 degraded
            rm -f $os_dir/etc/udev/rules.d/75-cloud-ifupdown.rules \
                $os_dir/etc/network/cloud-ifupdown-helper $os_dir/etc/network/cloud-interfaces-template

            chroot_apt_install $os_dir ifupdown
            chroot $os_dir systemctl enable networking

            # networking 服务静态时不更新 resolv.conf，也没装 rdnssd，留临时系统那份
            keep_now_resolv_conf $os_dir
        fi
        chroot_apt_autoremove $os_dir
        persist_tencent_disk_limit $os_dir

        chroot $os_dir apt-get clean
        rm $os_dir/etc/apt/reinstall.list
        apt_opts=
    fi

    basic_init $os_dir

    # 删除 swap
    swapoff -a
    rm -f $os_dir/swapfile
}

modify_os_on_disk() {
    info "Modify disk"

    update_part

    # dd 镜像时不修改硬盘内容（用户镜像应自带配置）
    if [ "$distro" = "dd" ]; then
        return
    fi

    mkdir -p /os
    # 按分区容量大到小，依次寻找系统分区
    for part in $(lsblk /dev/$xda*[0-9] --sort SIZE -no NAME | tac); do
        # btrfs挂载的是默认子卷，如果没有默认子卷，挂载的是根目录
        # fedora 云镜像没有默认子卷，且系统在root子卷中
        if mount -o ro /dev/$part /os; then
            if etc_dir=$({ ls -d /os/etc/ || ls -d /os/*/etc/; } 2>/dev/null); then
                os_dir=$(dirname $etc_dir)
                # 重新挂载为读写
                mount -o remount,rw /os
                modify_linux $os_dir
                return
            fi
            umount /os
        fi
    done
    error_and_exit "Can't find os partition."
}

get_need_swap_size() {
    need_ram=$1
    phy_ram=$(get_approximate_ram_size)

    if [ $need_ram -gt $phy_ram ]; then
        echo $((need_ram - phy_ram))
    else
        echo 0
    fi
}

create_swap_if_ram_less_than() {
    need_ram=$1
    swapfile=$2

    swapsize=$(get_need_swap_size $need_ram)
    if [ $swapsize -gt 0 ]; then
        create_swap $swapsize $swapfile
    fi
}

create_swap() {
    swapsize=$1
    swapfile=$2

    if ! grep $swapfile /proc/swaps; then
        # 不要 chattr +C：它只对 btrfs 有意义，目标根分区都是 ext4，
        # Live OS 的 e2fsprogs chattr 在 ext4 上返回 1，低内存机器会在擦盘后中止
        fallocate -l ${swapsize}M $swapfile
        chmod 0600 $swapfile
        mkswap $swapfile
        swapon $swapfile
    fi
}

set_ssh_keys() {
    os_dir=$1
    info 'set ssh keys'

    (
        umask 077
        mkdir -p $os_dir/root/.ssh
        cat /configs/ssh_keys >$os_dir/root/.ssh/authorized_keys
    )
}

# 装好的系统只留 key 登录：空密码会让控制台与 su 不问密码直接进 root。
# 用 * 而不用 passwd -l 的 !：不走 PAM 的 sshd（alpine）把 ! 当锁定，连 key 都拒
disable_root_password() {
    sed -i 's/^root:[^:]*:/root:*:/' $1/etc/shadow
}

# 除了 alpine 都会用到
change_ssh_conf() {
    os_dir=$1
    key=$2
    value=$3
    sub_conf=$4

    if line="^$key .*" && grep -Exq "$line" $os_dir/etc/ssh/sshd_config 2>/dev/null; then
        # 如果 sshd_config 存在此 key（非注释状态），则替换
        sed -Ei "s/$line/$key $value/" $os_dir/etc/ssh/sshd_config
    elif include_line='^Include.*/etc/ssh/sshd_config.d' &&
        # arch 没有 /etc/ssh/sshd_config.d/ 文件夹
        # opensuse tumbleweed 没有 /etc/ssh/sshd_config
        #                       有 /etc/ssh/sshd_config.d/ 文件夹
        #                       有 /usr/etc/ssh/sshd_config
        { grep -q "$include_line" $os_dir/etc/ssh/sshd_config ||
            grep -q "$include_line" $os_dir/usr/etc/ssh/sshd_config; } 2>/dev/null; then
        mkdir -p $os_dir/etc/ssh/sshd_config.d/
        echo "$key $value" >"$os_dir/etc/ssh/sshd_config.d/$sub_conf"
    else
        # 如果 sshd_config 存在此 key (无论是否已注释)，则替换，包括删除注释
        # 否则追加
        line="^[# ]*$key .*"
        if grep -Exq "$line" $os_dir/etc/ssh/sshd_config; then
            sed -Ei "s/$line/$key $value/" $os_dir/etc/ssh/sshd_config
        else
            echo "$key $value" >>$os_dir/etc/ssh/sshd_config
        fi
    fi
}

allow_password_login() {
    os_dir=$1
    change_ssh_conf "$os_dir" PasswordAuthentication yes 01-PasswordAuthentication.conf
}

allow_root_password_login() {
    os_dir=$1

    # opensuse 16/tumbleweed 安装 openssh-server-config-rootlogin
    # 会生成 /usr/etc/ssh/sshd_config.d/50-permit-root-login.conf
    # 但是如果用户删除了此文件，包有更新的话，可能会重新创建这个文件？
    # 因此先不用这个方法
    if false && [ -f $os_dir/etc/os-release ] &&
        grep -iq opensuse $os_dir/etc/os-release &&
        ! grep -iq 15.6 $os_dir/etc/os-release; then
        chroot $os_dir zypper install -y openssh-server-config-rootlogin
    else
        change_ssh_conf "$os_dir" PermitRootLogin yes 01-permitrootlogin.conf
    fi
}

change_ssh_port() {
    os_dir=$1
    ssh_port=$2

    change_ssh_conf "$os_dir" Port "$ssh_port" 01-change-ssh-port.conf
}

change_root_password() {
    os_dir=$1

    info 'change root password'
    echo "root:$(get_password_linux_sha512)" | chroot $os_dir chpasswd -e
}

download_qcow() {
    apk add qemu-img

    mkdir -p /installer
    mount /dev/disk/by-label/installer /installer

    qcow_file=/installer/cloud_image.qcow2
    if [ -n "$img_type_warp" ]; then
        # 边下载边解压，单线程下载
        # 用官方 wget ，带进度条
        apk add wget
        (set -o pipefail && wget $img -O- | pipe_extract >$qcow_file)
    else
        # 多线程下载
        download "$img" "$qcow_file"
    fi

    verify_qcow
}

# 校验分两步：签名过的校验和在动硬盘之前取回验过，镜像哈希在下载完之后比对
# Ubuntu: GPG 签名 + SHA256（防御 mirror 入侵）
# Debian: SHA512 完整性（防止下载损坏；Debian Cloud team 不发布 GPG 签名）
ubuntu_image_key_fpr=D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81
# Debian ≤11 装完用 Freexian ELTS 的源；它的 key 有到期日、续期后指纹不变，所以每次从 Freexian 现取、只认这个指纹
freexian_key_url=https://deb.freexian.com/extended-lts/archive-key.gpg
freexian_key_fpr=AB597C4F6F3380BD4B2BEBC2A07310D369055D5A

# 导进 /tmp/verify 下的临时 keyring，不污染系统；用完 unset GNUPGHOME、apk del gnupg
import_verify_key() {
    apk add gnupg
    GNUPGHOME=/tmp/verify/gpg
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    export GNUPGHOME
    gpg --batch --import "$1"
}

# is_signed_by <指纹> <签名> [<数据>]：只认钉住的那把 key 出的签名，key 文件里混进第二把 key 也签不过
is_signed_by() {
    fpr=$1
    shift
    gpg --batch --status-fd 1 --verify "$@" |
        awk -v fpr="$fpr" \
            '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && ($3 == fpr || $NF == fpr) { ok = 1 } END { exit !ok }'
}

# 验签失败必须发生在 create_part 之前：那之后原系统已被擦掉、新系统又装不上
fetch_qcow_hash() {
    # shellcheck disable=SC2154
    img_dir_url=$(dirname "$img")
    img_basename=$(basename "$img")

    rm -rf /tmp/verify
    mkdir -p /tmp/verify

    case "$distro" in
    ubuntu)
        info "Verify Ubuntu cloud image checksums (GPG)"
        download "$img_dir_url/SHA256SUMS" /tmp/verify/SHA256SUMS
        download "$img_dir_url/SHA256SUMS.gpg" /tmp/verify/SHA256SUMS.gpg

        import_verify_key /repo/keys/ubuntu-cloud.asc
        if ! is_signed_by "$ubuntu_image_key_fpr" /tmp/verify/SHA256SUMS.gpg /tmp/verify/SHA256SUMS; then
            error_and_exit "SHA256SUMS is not signed by the Ubuntu cloud image key $ubuntu_image_key_fpr"
        fi
        info false "GPG signature OK ($ubuntu_image_key_fpr)"

        unset GNUPGHOME
        apk del gnupg
        qcow_hash_cmd=sha256sum
        qcow_expected_hash=$(awk -v name="$img_basename" \
            '$2 == "*"name || $2 == name {print $1; exit}' /tmp/verify/SHA256SUMS)
        ;;
    debian)
        info "Fetch Debian cloud image checksums (SHA512; upstream provides no GPG signature)"
        download "$img_dir_url/SHA512SUMS" /tmp/verify/SHA512SUMS
        qcow_hash_cmd=sha512sum
        qcow_expected_hash=$(awk -v name="$img_basename" \
            '$2 == "*"name || $2 == name {print $1; exit}' /tmp/verify/SHA512SUMS)
        ;;
    esac

    if [ -z "$qcow_expected_hash" ]; then
        error_and_exit "$img_basename not listed in the checksum file"
    fi
    rm -rf /tmp/verify
}

# 到这里硬盘已经重新分区，不一致只能中止——所以签名那一半提前到了 fetch_qcow_hash
verify_qcow() {
    actual_hash=$($qcow_hash_cmd "$qcow_file" | awk '{print $1}')
    if [ "$qcow_expected_hash" != "$actual_hash" ]; then
        error_and_exit "Image hash mismatch: expected $qcow_expected_hash, got $actual_hash"
    fi
    info false "Image hash OK: $actual_hash"
}

# Debian 安装期间 apt 只读这里备好的源清单（apt_opts），不读镜像自带的：
# 镜像里的 suite 被撤（如 *-backports）会让 apt-get update 失败，而那时盘已改写
apt_dir=/apt-sources
apt_opts=

# 安装期间用的源，每行「地址 suite 组件」；≤11 官方已停止支持，用 Freexian ELTS 的完整镜像
get_debian_suites() {
    # shellcheck disable=SC2154
    if [ "$releasever" -le 11 ]; then
        echo "https://deb.freexian.com/extended-lts $codename main contrib non-free"
    else
        echo "https://deb.debian.org/debian $codename main non-free-firmware"
        echo "https://deb.debian.org/debian $codename-updates main non-free-firmware"
        echo "https://deb.debian.org/debian-security $codename-security main non-free-firmware"
    fi
}

# 盘还没动时探好每个 suite、核好 Freexian 的 key：哪个取不到都该在这里停，而不是停在擦过的盘上
prepare_debian_sources() {
    rm -rf $apt_dir /tmp/verify
    mkdir -p $apt_dir /tmp/verify

    keyring=/usr/share/keyrings/debian-archive-keyring.gpg
    if [ "$releasever" -le 11 ]; then
        keyring=/usr/share/keyrings/freexian-archive-extended-lts.gpg
        download "$freexian_key_url" /tmp/verify/freexian.gpg
        download "https://deb.freexian.com/extended-lts/dists/$codename/InRelease" /tmp/verify/InRelease
        import_verify_key /tmp/verify/freexian.gpg
        if ! is_signed_by "$freexian_key_fpr" /tmp/verify/InRelease; then
            error_and_exit "Freexian $codename InRelease is not signed by $freexian_key_fpr"
        fi
        # 只导出钉住的那把，取回的文件里混进别的 key 也带不进新系统
        gpg --batch --export "$freexian_key_fpr" >$apt_dir/keyring.gpg
        unset GNUPGHOME
        apk del gnupg
    fi

    while read -r uri suite comps; do
        url=$uri/dists/$suite/InRelease
        wget --spider "$url" || error_and_exit "Debian $suite is not available: $url"
        echo "deb [signed-by=$keyring] $uri $suite $comps" >>$apt_dir/sources.list
    done < <(get_debian_suites)
    cat $apt_dir/sources.list
    rm -rf /tmp/verify
}

connect_qcow() {
    modprobe nbd nbds_max=1
    qemu-nbd -c /dev/nbd0 $qcow_file

    # 需要等待一下
    # https://github.com/canonical/cloud-utils/blob/main/bin/mount-image-callback
    while ! blkid /dev/nbd0; do
        echo "Waiting for qcow file to be mounted..."
        sleep 5
    done
}

disconnect_qcow() {
    if [ -f /sys/block/nbd0/pid ]; then
        qemu-nbd -d /dev/nbd0

        # 需要等待一下
        while fuser -sm $qcow_file; do
            echo "Waiting for qcow file to be unmounted..."
            sleep 5
        done
    fi
}

get_part_size_mb_for_file_size_b() {
    local file_b=$1
    local file_mb=$((file_b / 1024 / 1024))

    # ext4 默认参数下
    #  分区大小   可用大小   利用率
    #  100 MiB      86 MiB   86.0%
    #  200 MiB     177 MiB   88.5%
    #  500 MiB     454 MiB   90.8%
    #  512 MiB     476 MiB   92.9%
    # 1024 MiB     957 MiB   93.4%
    # 2000 MiB    1914 MiB   95.7%
    # 2048 MiB    1929 MiB   94.1% 这里反而下降了
    # 5120 MiB    4938 MiB   96.4%

    # 文件系统大约占用 5% 空间

    # 假设 1929M 的文件，计算得到需要创建 2031M 的分区
    # 但是实测 2048M 的分区才能存放 1929M 的文件
    # 因此预留不足 150M 时补够 150M
    local reserve_mb=$((file_mb * 100 / 95 - file_mb))
    if [ $reserve_mb -lt 150 ]; then
        reserve_mb=150
    fi

    part_mb=$((file_mb + reserve_mb))
    echo "File size:      $file_mb MiB" >&2
    echo "Part size need: $part_mb MiB" >&2
    echo $part_mb
}

get_cloud_image_part_size() {
    # https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2 500m
    # https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img 500m
    if size_bytes=$(get_http_file_size "$img"); then
        echo "$(get_part_size_mb_for_file_size_b $size_bytes)MiB"
    else
        # 如果没获取到文件大小
        echo "Could not get cloud image size in http response." >&2
        echo 2GiB
    fi
}

chroot_apt_update() {
    os_dir=$1

    current_hash=$(cat $os_dir/etc/apt/sources.list $os_dir/etc/apt/sources.list.d/*.sources 2>/dev/null | md5sum)
    if ! [ "$saved_hash" = "$current_hash" ]; then
        chroot $os_dir apt-get $apt_opts update
        saved_hash="$current_hash"
    fi
}

chroot_apt_install() {
    os_dir=$1
    shift

    chroot_apt_update $os_dir
    DEBIAN_FRONTEND=noninteractive chroot $os_dir apt-get $apt_opts install -y "$@"
}

chroot_apt_remove() {
    os_dir=$1
    shift

    # minimal 镜像 删除 grub-pc 时会安装 grub-efi-amd64
    # 因此需要先更新索引
    chroot_apt_update $os_dir

    # 不能用 apt remove --purge -y xxx yyy
    # 因为如果索引里没有其中一个，会报错，另一个也不会删除
    local pkgs=
    for pkg in "$@"; do
        # apt list 会提示 WARNING: apt does not have a stable CLI interface. Use with caution in scripts.
        # 但又不能用 apt-get list
        if chroot $os_dir apt $apt_opts list --installed "$pkg" | grep -q installed; then
            pkgs="$pkgs $pkg"
        fi
    done

    # 清除 grub 包时 debconf 会问要不要删掉 /boot/grub，没人答，因此添加 noninteractive
    DEBIAN_FRONTEND=noninteractive chroot $os_dir apt-get $apt_opts remove --purge --allow-remove-essential -y $pkgs
}

chroot_apt_autoremove() {
    os_dir=$1

    change_confs() {
        action=$1

        # 只有 16.04 有 01autoremove-kernels
        # 16.04 结束支持后删除
        for conf in 01autoremove 01autoremove-kernels; do
            file=$os_dir/etc/apt/apt.conf.d/$conf
            case "$action" in
            change)
                if [ -f $file ]; then
                    sed -i.orig 's/VersionedKernelPackages/x/; s/NeverAutoRemove/x/' $file
                fi
                ;;
            restore)
                if [ -f $file.orig ]; then
                    mv $file.orig $file
                fi
                ;;
            esac
        done
    }

    change_confs change
    DEBIAN_FRONTEND=noninteractive chroot $os_dir apt-get $apt_opts autoremove --purge -y
    change_confs restore
}

install_qcow_by_copy() {
    modify_ubuntu() {
        os_dir=/os
        info "Modify Ubuntu"

        cp_resolv_conf $os_dir

        # 关闭 os prober，因为 os prober 有时很慢
        cp $os_dir/etc/default/grub $os_dir/etc/default/grub.orig
        echo 'GRUB_DISABLE_OS_PROBER=true' >>$os_dir/etc/default/grub

        # 16.04 arm64 镜像没有 grub 引导文件
        if is_efi && ! [ -d $os_dir/boot/efi/EFI/ubuntu ]; then
            chroot_apt_install $os_dir efibootmgr shim "grub-efi-$(get_axx64)"
            # 创建 ubuntu 文件夹和 grubaa64.efi
            DEBIAN_FRONTEND=noninteractive chroot $os_dir dpkg-reconfigure "grub-efi-$(get_axx64)"

            cat <<EOF >"$os_dir/boot/efi/EFI/ubuntu/grub.cfg"
search.fs_uuid $os_part_uuid root
set prefix=(\$root)'/boot/grub'
configfile \$prefix/grub.cfg
EOF
        fi

        # 避免 do-release-upgrade 时自动执行 dpkg-reconfigure grub-xx 但是 efi/biosgrub 分区不存在而导致报错
        # shellcheck disable=SC2046
        chroot_apt_remove $os_dir $(is_efi && echo 'grub-pc' || echo 'grub-efi*' 'shim*')
        chroot_apt_autoremove $os_dir

        # 安装 mbr
        if ! is_efi; then
            if false; then
                # debconf-show grub-pc
                # 每次开机硬盘名字可能不一样，但是 debian netboot 安装后也是设置了 grub-pc/install_devices
                echo grub-pc grub-pc/install_devices multiselect /dev/$xda | chroot $os_dir debconf-set-selections # 22.04
                echo grub-pc grub-pc/cloud_style_installation boolean true | chroot $os_dir debconf-set-selections # 24.04
                chroot $os_dir dpkg-reconfigure -f noninteractive grub-pc
            else
                chroot $os_dir grub-install /dev/$xda
            fi
        fi

        # 标记所有内核为自动安装
        # 注意排除 linux-base
        # 返回值始终为 0
        pkgs=$(chroot $os_dir apt-mark showmanual \
            linux-generic linux-virtual linux-kvm \
            linux-image* linux-headers*)
        chroot $os_dir apt-mark auto $pkgs

        # 安装最佳内核
        flavor=$(get_ubuntu_kernel_flavor)
        echo "Use kernel flavor: $flavor"
        # 如果镜像自带内核跟最佳内核是同一种且有更新
        # 则 apt install 只会进行更新，不会将包设置成 manual
        # 需要再运行 apt install 才会将包设置成 manual
        chroot_apt_install $os_dir "linux-image-$flavor"
        chroot_apt_install $os_dir "linux-image-$flavor"

        # 使用 autoremove 删除多余内核
        chroot_apt_autoremove $os_dir

        # 安装固件+微码
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            chroot_apt_install $os_dir $fw_pkgs
        fi

        persist_tencent_disk_limit $os_dir

        # 网络配置：18.04 起都是 netplan
        # 避免 minimal 镜像的 netplan.io 被 autoremove
        chroot $os_dir apt-mark manual netplan.io
        create_netplan_config $os_dir/etc/netplan/50-cloud-init.yaml

        # 更改 efi 目录的 grub.cfg 写死的 fsuuid
        # 因为 24.04 fsuuid 对应 boot 分区
        efi_grub_cfg=$os_dir/boot/efi/EFI/ubuntu/grub.cfg
        if is_efi; then
            os_uuid=$(lsblk -rno UUID /dev/$xda*2)
            sed -Ei "s|[0-9a-f-]{36}|$os_uuid|i" $efi_grub_cfg

            # 24.04 移除 boot 分区后，需要添加 /boot 路径
            if grep "'/grub'" $efi_grub_cfg; then
                sed -i "s|'/grub'|'/boot/grub'|" $efi_grub_cfg
            fi
        fi

        # 处理 40-force-partuuid.cfg
        force_partuuid_cfg=$os_dir/etc/default/grub.d/40-force-partuuid.cfg
        if [ -e $force_partuuid_cfg ]; then
            if is_virt; then
                # 更改写死的 partuuid
                os_part_uuid=$(lsblk -rno PARTUUID /dev/$xda*2)
                sed -i "s/^GRUB_FORCE_PARTUUID=.*/GRUB_FORCE_PARTUUID=$os_part_uuid/" $force_partuuid_cfg
            else
                # 独服不应该使用 initrdless boot
                sed -i "/^GRUB_FORCE_PARTUUID=/d" $force_partuuid_cfg
            fi
        fi

        # 要重新生成 grub.cfg，因为
        # 1 我们删除了 boot 分区
        # 2 改动了 /etc/default/grub.d/40-force-partuuid.cfg
        chroot $os_dir update-grub

        # 还原 grub 配置（os prober）
        mv $os_dir/etc/default/grub.orig $os_dir/etc/default/grub

        # fstab
        # 24.04 镜像有boot分区，但我们不需要
        sed -i '/[[:space:]]\/boot[[:space:]]/d' $os_dir/etc/fstab
        if ! is_efi; then
            # bios 删除 efi 条目
            sed -i '/[[:space:]]\/boot\/efi[[:space:]]/d' $os_dir/etc/fstab
        fi

        # generic 带进来的 linux-firmware 约 600 MB，下载的 .deb 不清会再占同样大
        chroot $os_dir apt-get clean
        restore_resolv_conf $os_dir
    }

    efi_mount_opts=umask=0077

    # apt 安装软件时需要的内存总大小
    need_ram=1024

    connect_qcow

    info "qcow2 Partitions check"

    partition_table_format=$(get_partition_table_format /dev/nbd0)

    # 通过检测文件判断是什么分区
    os_part='' boot_part='' efi_part=''
    mkdir -p /nbd-test
    for part in $(lsblk /dev/nbd0p* --sort SIZE -no NAME,FSTYPE |
        grep -E ' (ext4|fat|vfat)$' | awk '{print $1}' | tac); do
        if mount -o ro /dev/$part /nbd-test; then
            if { ls /nbd-test/etc/os-release || ls /nbd-test/*/etc/os-release; } 2>/dev/null; then
                os_part=$part
            fi
            # shellcheck disable=SC2010
            # 当 boot 作为独立分区时，vmlinuz 等文件在根目录
            # 当 boot 不是独立分区时，vmlinuz 等文件在 /boot 目录
            if ls /nbd-test/ /nbd-test/boot/ 2>/dev/null | grep -Ei '^(vmlinuz|initrd|initramfs)'; then
                boot_part=$part
            fi
            # efi 文件可能在 efi 目录的子目录，子目录层数不定
            if find /nbd-test/ -type f -ipath '/nbd-test/EFI/*.efi' 2>/dev/null | grep .; then
                efi_part=$part
            fi
            umount /nbd-test
        fi
    done

    info "qcow2 Partitions"
    lsblk -f /dev/nbd0 -o +PARTTYPE
    # 显示 OS/EFI/Boot 文件在哪个分区
    echo "---"
    echo "Table:     $partition_table_format"
    echo "Part OS:   $os_part"
    echo "Part EFI:  $efi_part"
    echo "Part Boot: $boot_part"
    echo "---"

    IFS=, read -r os_part_uuid os_part_label os_part_fstype \
        < <(lsblk /dev/$os_part -rno UUID,LABEL,FSTYPE | tr ' ' ,)

    if [ -n "$efi_part" ]; then
        IFS=, read -r efi_part_uuid efi_part_label \
            < <(lsblk /dev/$efi_part -rno UUID,LABEL | tr ' ' ,)
    fi

    mkdir -p /nbd /nbd-boot /nbd-efi

    # 使用目标系统的格式化程序
    mount /dev/$os_part /nbd/
    mount_pseudo_fs /nbd/
    case "$os_part_fstype" in
    ext4) chroot /nbd mkfs.ext4 -F -L "$os_part_label" -U "$os_part_uuid" /dev/$xda*2 ;;
    esac
    umount -R /nbd/

    # 创建并挂载 /os
    mkdir -p /os
    mount -o noatime /dev/$xda*2 /os/

    # 如果是 efi 则创建 /os/boot/efi
    # 如果镜像有 efi 分区也创建 /os/boot/efi，用于复制 efi 分区的文件
    if is_efi || [ -n "$efi_part" ]; then
        mkdir -p /os/boot/efi/

        # 挂载 /os/boot/efi
        # 预先挂载 /os/boot/efi 因为可能 boot 和 efi 在同一个分区（openeuler 24.03 arm）
        # 复制 boot 时可以会复制 efi 的文件
        if is_efi; then
            mount -o $efi_mount_opts /dev/$xda*1 /os/boot/efi/
        fi
    fi

    # 复制系统分区
    echo Copying os partition...
    mount -o ro /dev/$os_part /nbd/
    cp -a /nbd/* /os/
    umount /nbd/

    # 复制独立的boot分区，如果有
    if [ -n "$boot_part" ] && ! [ "$boot_part" = "$os_part" ]; then
        echo Copying boot partition...
        mount -o ro /dev/$boot_part /nbd-boot/
        cp -a /nbd-boot/* /os/boot/
        umount /nbd-boot/
    fi

    # 复制独立的efi分区，如果有
    # 如果 efi 和 boot 是同一个分区，则复制 boot 分区时已经复制了 efi 分区的文件
    if [ -n "$efi_part" ] && ! [ "$efi_part" = "$os_part" ] && ! [ "$efi_part" = "$boot_part" ]; then
        echo Copying efi partition...
        mount -o ro /dev/$efi_part /nbd-efi/
        cp -a /nbd-efi/* /os/boot/efi/
        umount /nbd-efi/
    fi

    # 断开 qcow 并删除 qemu-img
    info "Disconnecting qcow2"
    disconnect_qcow
    apk del qemu-img

    # 取消挂载硬盘
    info "Unmounting disk"
    if is_efi; then
        umount /os/boot/efi/
    fi
    umount /os/
    umount /installer/

    # 如果镜像有独立的efi分区（包括efi+boot在同一个分区），复制其uuid
    # 如果有相同uuid的fat分区，则无法挂载
    # 所以要先复制efi分区，断开nbd再复制uuid
    # 复制uuid前要取消挂载硬盘 efi 分区
    if is_efi && [ -n "$efi_part_uuid" ] && ! [ "$efi_part" = "$os_part" ]; then
        info "Copy efi partition uuid"
        apk add mtools
        mlabel -N "$(echo $efi_part_uuid | sed 's/-//')" -i /dev/$xda*1 ::$efi_part_label
        apk del mtools
        update_part
    fi

    # 删除 installer 分区并扩容
    info "Delete installer partition"
    apk add parted
    parted /dev/$xda -s -- rm 3
    update_part
    resize_after_install_cloud_image

    # 重新挂载 /os /boot/efi
    info "Re-mount disk"
    mount -o noatime /dev/$xda*2 /os/
    if is_efi; then
        mount -o $efi_mount_opts /dev/$xda*1 /os/boot/efi/
    fi

    # 创建 swap
    create_swap_if_ram_less_than $need_ram /os/swapfile

    # 挂载伪文件系统
    mount_pseudo_fs /os/

    modify_ubuntu

    # 基本配置
    basic_init /os

    disable_cloud_init /os

    # 删除 swapfile
    swapoff -a
    rm -f /os/swapfile
}

get_partition_table_format() {
    apk add parted
    parted "$1" -s print | grep 'Partition Table:' | awk '{print $NF}'
}

dd_qcow() {
    if true; then
        connect_qcow

        # 显示分区
        lsblk -o NAME,SIZE,FSTYPE,LABEL /dev/nbd0

        # 将前1M dd到内存
        dd if=/dev/nbd0 of=/first-1M bs=1M count=1

        # 将1M之后 dd到硬盘
        # shellcheck disable=SC2194
        case 3 in
        1)
            # BusyBox dd
            dd if=/dev/nbd0 of=/dev/$xda bs=1M skip=1 seek=1
            ;;
        2)
            # 用原版 dd status=progress，但没有进度和剩余时间
            apk add coreutils
            dd if=/dev/nbd0 of=/dev/$xda bs=1M skip=1 seek=1 status=progress
            ;;
        3)
            # 用 pv
            apk add pv
            echo "Start DD Cloud Image..."
            (set -o pipefail && pv -f /dev/nbd0 | dd of=/dev/$xda bs=1M skip=1 seek=1 iflag=fullblock)
            ;;
        esac

        disconnect_qcow
    else
        # 将前1M dd到内存，将1M之后 dd到硬盘
        qemu-img dd if=$qcow_file of=/first-1M bs=1M count=1
        qemu-img dd if=$qcow_file of=/dev/disk/by-label/os bs=1M skip=1
    fi

    # 已 dd 并断开连接 qcow，可删除 qemu-img
    apk del qemu-img

    # 将前1M从内存 dd 到硬盘
    umount /installer/
    dd if=/first-1M of=/dev/$xda
    rm -f /first-1M

    update_part
}

# 适用于 DD 后修复 gpt 备份分区表
fix_gpt_backup_partition_table_by_parted() {
    apk add parted
    parted /dev/$xda -f -s print
    update_part
}

resize_after_install_cloud_image() {
    # 提前扩容
    # 修复 vultr 512m debian 11 generic/genericcloud 首次启动 kernel panic
    info "Resize after dd"
    lsblk -f /dev/$xda

    # 打印分区表，并自动修复备份分区表
    fix_gpt_backup_partition_table_by_parted

    disk_size=$(get_disk_size /dev/$xda)
    disk_end=$((disk_size - 1))

    # 不能漏掉最后的 _ ，否则第6部分都划到给 last_part_fs
    IFS=: read -r last_part_num _ last_part_end _ last_part_fs _ \
        < <(parted -msf /dev/$xda 'unit b print' | tail -1)
    last_part_end=$(echo $last_part_end | sed 's/B//')

    if [ $((disk_end - last_part_end)) -ge 0 ]; then
        printf "yes" | parted /dev/$xda resizepart $last_part_num 100% ---pretend-input-tty
        update_part

        mkdir -p /os

        case "$last_part_fs" in
        ext4)
            apk add e2fsprogs-extra
            e2fsck -p -f /dev/$xda*$last_part_num
            resize2fs /dev/$xda*$last_part_num
            apk del e2fsprogs-extra
            ;;
        esac
        update_part
        parted /dev/$xda -s print
    fi
}

mount_part_basic_layout() {
    os_dir=$1
    efi_dir=$2

    if is_efi || is_xda_gt_2t; then
        os_part_num=2
    else
        os_part_num=1
    fi

    # 挂载系统分区
    mkdir -p $os_dir
    mount -t ext4 /dev/${xda}*${os_part_num} $os_dir

    # 挂载 efi 分区
    if is_efi; then
        mkdir -p $efi_dir
        mount -t vfat -o umask=077 /dev/${xda}*1 $efi_dir
    fi
}

# pool.ntp.org 没有 AAAA，纯 IPv6 的机器上永远同步不上；池里只有 2.pool.ntp.org 有，
# 可双栈机器解析它会先选 v6，而它的 v6 服务器从有的机房一半不回。所以只在没有 v4 时用它
get_ntp_server() {
    if ip -4 route show default | grep -q .; then
        echo pool.ntp.org
    else
        echo 2.pool.ntp.org
    fi
}

sync_time() {
    # 优先级:
    # 1. NTP (get_ntp_server)      — 专为时间同步设计，不依赖证书
    # 2. HTTP Date header fallback — 当 NTP 端口被防火墙挡时用
    #
    # 旧版本默认走 HTTP + --no-check-certificate，相当于主动放弃 TLS 校验。
    # NTP 走 UDP/123，跟 RTC 偏差再大也能 step 同步。

    # NTP
    # -d  Verbose / -n Foreground / -q Quit after sync / -p PEER
    if ntpd -d -n -q -p "$(get_ntp_server)"; then
        return
    fi

    # HTTP Date 回退（不强制 https；alpine apk 仓库默认 http）
    warn "NTP sync failed, falling back to HTTP Date header"
    url="$(grep -m1 ^http /etc/apk/repositories)/$(uname -m)/APKINDEX.tar.gz"
    # gnu date 不支持 -D
    # 重启时 alpine 会自动写入到硬件时钟，因此不 hwclock -w
    if date_header=$(wget -S --spider "$url" 2>&1 | grep -m1 '^  Date:') &&
        busybox date -u -D "  Date: %a, %d %b %Y %H:%M:%S GMT" -s "$date_header" >/dev/null; then
        return
    fi

    # 两条路都失败要说出来：时钟偏差大时后面的 HTTPS 下载会因证书时间失败
    warn "Time sync failed (NTP and HTTP Date); HTTPS downloads may fail if the clock is far off"
    return 1
}

is_ubuntu_lts() {
    IFS=. read -r major minor < <(echo "$releasever")
    [ $((major % 2)) = 0 ] && [ $minor = 04 ]
}

# 虚拟机上也装 generic：virtual 不带 linux-modules-extra，6.8 及更早的内核里 GCP 的 gve、Azure 的 mana 只在那里
get_ubuntu_kernel_flavor() {
    is_ubuntu_lts && echo generic-hwe-$releasever || echo generic
}

# 各目标装机的阶段，横幅的「第几/共几」从这张表数出来：加减阶段改这里，序号与总数跟着变
get_steps() {
    case "$distro" in
    alpine) echo partition install configure ;;
    dd)
        if [ "$cloud_init_network" = 1 ]; then
            echo write network
        else
            echo write
        fi
        ;;
    debian) echo verify sources partition download write configure ;;
    ubuntu) echo verify partition download install ;;
    esac
}

# step <阶段> <在做什么>：打出「[第几/共几] 在做什么」
step() {
    local s n=0 i=0
    for s in $(get_steps); do
        n=$((n + 1))
        if [ "$s" = "$1" ]; then
            i=$n
        fi
    done
    info "[$i/$n] $2"
}

trans() {
    info "start trans"

    mod_motd

    # 先检查 modloop 是否正常
    # 防止格式化硬盘后，缺少 ext4 模块导致 mount 失败
    # https://github.com/bin456789/reinstall/issues/136
    start_modloop

    cat /proc/cmdline
    clear_previous
    add_community_repo

    # 需要在重新分区之前，找到主硬盘
    # 重新运行脚本时，可指定 xda
    # xda=sda ash trans.start
    if [ -z "$xda" ]; then
        find_xda
    fi

    limit_tencent_disk_requests

    if [ "$distro" != "alpine" ]; then
        setup_web_if_enough_ram
        # util-linux 包含 lsblk
        # util-linux 可自动探测 mount 格式
        apk add util-linux
    fi

    # shellcheck disable=SC2154
    case "$distro" in
    alpine)
        install_alpine
        ;;
    dd)
        warn_static_network
        step write "download and write the image"
        dd_raw_with_extract
        # 内核还认着写盘前的分区表，不重读的话，后面找 ESP、清 NVRAM 条目看到的都是旧盘。
        # partx -u 碰上 mdev 正在探的分区会悄悄跳过，所以整盘重读；也会偶尔撞上，要重试
        retry 5 1 blockdev --rereadpt /dev/$xda
        if [ "$cloud_init_network" = 1 ]; then
            step network "write the network config into the image's cloud-init seed"
            write_cloud_init_seed
        fi
        ;;
    debian)
        step verify "verify the image checksums"
        fetch_qcow_hash
        step sources "check the Debian apt sources"
        prepare_debian_sources
        step partition "partition the disk"
        create_part
        step download "download the image"
        download_qcow
        step write "write the image"
        dd_qcow
        resize_after_install_cloud_image
        step configure "configure the system"
        modify_os_on_disk
        ;;
    ubuntu)
        # 24.04 云镜像有 boot 分区（在系统分区之前），因此不直接 dd 云镜像
        step verify "verify the image checksums"
        fetch_qcow_hash
        step partition "partition the disk"
        create_part
        step download "download the image"
        download_qcow
        step install "install and configure the system"
        install_qcow_by_copy
        ;;
    esac

    # 需要用到 lsblk efibootmgr ，只要 1M 左右容量
    # 因此 alpine 不单独处理
    if is_efi; then
        del_invalid_efi_entry
        add_default_efi_to_nvram
    fi

    info 'done'
    # 让 web 输出全部内容
    sleep 5
}

# 脚本入口
# debian initrd 会寻找 main
# 并调用本文件的 create_ifupdown_config 方法
: main

# 复制脚本
# 用于打印错误或者再次运行
# 路径相同则不用复制
# 重点：要在删除脚本之前复制
if ! [ "$(readlink -f "$0")" = /trans.sh ]; then
    cp -f "$0" /trans.sh
fi
trap 'trap_err $LINENO $?' ERR

# 删除本脚本，不然会被复制到新系统
rm -f /etc/local.d/trans.start
rm -f /etc/runlevels/default/local

# 提取变量
extract_env_from_cmdline

# 带参数运行部分
# 重新下载并 exec 运行新脚本
if [ "$1" = "update" ]; then
    info 'update script'
    # shellcheck disable=SC2154
    wget -O /trans.sh "$confhome/trans.sh"
    chmod +x /trans.sh
    exec /trans.sh
elif [ "$1" = "alpine" ]; then
    info 'switch to alpine'
    distro=alpine
    # 后面的步骤很多都会用到这个，例如分区布局
    cloud_image=0
elif [ -n "$1" ]; then
    error_and_exit "unknown option $1"
fi

# 从这里起输出同时写各控制台与 /reinstall.log：开机时 local 服务把本脚本的输出丢进 /dev/null，
# 不在这里接上，控制台上什么也看不到。放在 update 之后，否则 exec 起来的新脚本再接一层、日志写两遍；
# 追加写，手动重跑时上一次的日志还在
# shellcheck disable=SC2046
exec > >(exec tee -a $(get_ttys /dev/) /reinstall.log) 2>&1
echo "===== trans.sh${1:+ $1} started $(date -u '+%Y-%m-%d %H:%M:%S') UTC ====="

# 无参数运行部分
# 允许 ramdisk 使用所有内存，默认是 50%
mount / -o remount,size=100%

# 同步时间
# 1. 可以防止访问 https 出错
# 2. 可以防止 https://github.com/bin456789/reinstall/issues/223
#    E: Release file for http://security.ubuntu.com/ubuntu/dists/noble-security/InRelease is not valid yet (invalid for another 5h 37min 18s).
#    Updates for this repository will not be applied.
# 3. 不能直接读取 rtc，因为默认情况 windows rtc 是本地时间，linux rtc 是 utc 时间
# 4. 允许同步失败，因为不是关键步骤
sync_time || true

# 安装 ssh 并更改端口
apk add openssh
if is_need_change_ssh_port; then
    change_ssh_port / $ssh_port
fi

# 设置密码，添加开机启动 + 开启 ssh 服务
if is_need_set_ssh_keys; then
    set_ssh_keys /
    # 临时系统保留空密码：网络起不来时，还能从面板控制台以 root 登进来救
    passwd -d root
    printf '\n' | setup-sshd
else
    change_root_password /
    printf '\nyes' | setup-sshd
fi
info false "SSH is up on port ${ssh_port:-22}. The log is /reinstall.log."

# shellcheck disable=SC2154
if [ "$hold" = 1 ]; then
    if is_run_from_locald; then
        info "hold 1"
        echo "Nothing was installed. Run '/trans.sh' to install, or 'reboot' to go back to the current system."
        exit
    fi
fi

trans

if [ "$hold" = 2 ]; then
    info "hold 2"
    echo "Installed. Run 'reboot' to start the new system."
    exit
fi

# swapoff -a
# umount ?
sync
reboot
