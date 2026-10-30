# Reinstall

[![license](https://img.shields.io/github/license/Lynthar/Reinstall)](LICENSE)
[![shellcheck](https://img.shields.io/github/actions/workflow/status/Lynthar/Reinstall/shellcheck.yml?branch=main&label=shellcheck)](https://github.com/Lynthar/Reinstall/actions/workflows/shellcheck.yml)

隐私优先的 VPS 一键重装脚本：DD 任意 raw 镜像，或装 Debian / Ubuntu 云镜像与 Alpine；默认 UTC、不做 IP 定位

简体中文 | [English](README.en.md)

把一台正在跑着的 VPS 重装成别的系统。它先改引导让机器重启进一个临时的 Alpine，
再在那里面把目标系统真正装上去。**这个脚本会擦盘**——跑之前先备份，最好先在一台
可以重建的机器上试一次。

能装四种东西：Debian 10/11/12/13、Ubuntu 18.04/20.04/22.04/24.04/26.04/26.10、Alpine 3.22/3.23/3.24，
以及 `dd` 任意 raw 镜像（只收 `http(s)://`）。不写版本时装表里最新的一个，Ubuntu 则是最新的
LTS（26.04）。Debian 与 Ubuntu 走官方云镜像。
Debian 10 / 11 的官方支持已经结束，装好后用 Freexian 的 ELTS 源（`deb.freexian.com`），
它的签名密钥指纹钉在脚本里。ELTS 只覆盖赞助方用到的那些包，Freexian 说尽量对个人免费，
没有书面承诺；这两版的云镜像停在 2024-07 与 2026-08。Ubuntu 18.04 / 20.04 的标准支持
已经结束，云镜像停在 2023-06 与 2025-06，装好后要接 Ubuntu Pro（ESM）才有安全更新。

## 安装

不需要安装。下载脚本，用 root 跑：

```bash
curl -O https://raw.githubusercontent.com/Lynthar/Reinstall/main/reinstall.sh
```

要从 Windows 上 dd 一个 Linux 镜像，得先自己装好 Cygwin：这里没有上游的
`reinstall.bat`，脚本在 Cygwin 下也不替你装包，缺哪个命令就在哪一步失败。在 PowerShell
里照下面这样装。第二、三行让老 Windows 自带的 PowerShell 5.1 也能用 TLS 1.2 下载；安装器
要用 `Start-Process -Wait` 起，再加 `--wait`，否则它自己申请管理员权限另起一份时，PowerShell
不等装完就返回。

```powershell
cd $env:TEMP
$sp = [Net.ServicePointManager]::SecurityProtocol
[Net.ServicePointManager]::SecurityProtocol = $sp -bor [Net.SecurityProtocolType]::Tls12
$url = 'https://www.cygwin.com/setup-x86_64.exe'
Invoke-WebRequest $url -OutFile setup-x86_64.exe -UseBasicParsing
$pkgs = 'curl,cpio,p7zip,dos2unix,jq,xz,gzip,zstd,openssl,bind-utils,libiconv,binutils'
$site = 'https://mirrors.kernel.org/sourceware/cygwin'
Start-Process -Wait .\setup-x86_64.exe -ArgumentList `
    "--quiet-mode --wait --only-site --site $site --packages $pkgs"
```

装好后以管理员身份打开 Cygwin 终端（不是管理员的话脚本会报 `Please run as administrator.`），
在里面用上面那条 curl 下载脚本，再照下面用法里的命令跑，只是不用 `sudo`。

## 用法

```bash
sudo bash reinstall.sh debian 12
sudo bash reinstall.sh ubuntu 24.04 --minimal
sudo bash reinstall.sh alpine 3.22
sudo bash reinstall.sh dd --img "https://example.com/x.img.xz"
```

Alpine 宿主默认没有 `sudo` 和 `bash`：以 root 直接 `sh reinstall.sh …` 就行，
脚本会自己装上 bash。
口令建议从 stdin 给，不要用 `--password`——
后者会进 `ps` 和 history：

```bash
printf '%s' "$PW" | sudo bash reinstall.sh --password-stdin debian 12
```

注入 SSH 公钥，接受裸 key、文件、`https://` 地址，或 `github:用户名`：

```bash
sudo bash reinstall.sh debian 12 --ssh-key github:yourname
```

装的过程能看：默认在 `127.0.0.1:80` 起一个只读日志页，SSH 端口转发过去就能盯着：

```bash
ssh -L 8080:127.0.0.1:80 root@your-server
```

日志本身在临时系统的 `/reinstall.log`，用同一套登录方式 SSH 进去就能看。装的过程中别从
厂商面板重启或关机：开始写盘之后，新旧两个系统都起不来。出了错，屏幕上会说盘动没动——
没动就 `reboot` 回原系统；动了就别重启，在 SSH 里修好原因后跑 `/trans.sh` 重来。现场打包在
`/tmp/reinstall-debug.tar.gz`，里面有 IP 地址和安装日志，发给别人之前先看一眼。

其它常用旗标：`--timezone`、`--ssh-port`、`--web-port`、`--no-web`、
`--hold 0|1|2`（0 在打包临时系统之前停下、可以手改里面的文件，1 停在安装环境，2 装完不重启）、`--force-boot-mode bios|efi`、`-x` 调试、
`--commit <SHA>` 钉住引导脚本的版本，`--hostname <名字>` 设主机名（dd 不收；不给时用镜像
自带的，Debian 镜像没带就是 `debian`）。没有配置文件也没有环境变量，行为全部由旗标决定。
DHCP 给了 DNS 就用 DHCP 的；静态网络的机器写成 `1.1.1.1` 与 `8.8.8.8`（IPv6 对应
Cloudflare 与 Google），不沿用原系统的设置。临时系统逐个试 DHCP 给的 DNS，解析不了的删掉，
哪一族一个不剩（或 DHCP 本来就没给）就补上这两个。装好的 Debian 12 / 13、Ubuntu 与
`--cloud-init-network` 写的种子会把补上的也写进网络配置，和 DHCP 给的一起用（IPv6 只在
DHCPv6 给的全都解析不了时这样做）；Debian 10 / 11 与 Alpine 仍只用 DHCP 给的。

静态 IP 的机器（没有 DHCP）上 dd 要当心：镜像照原样写进去，得自己带着这台机器的地址，
否则重启后那一族网络起不来，全是静态的就连不上了。临时系统写盘前会在屏幕和日志里列出
静态配置的地址。镜像带 cloud-init 的话（发行版的通用云镜像一般都带），可以加
`--cloud-init-network`：写完盘后把探到的网络配置作为 NoCloud 种子写进镜像的
`/var/lib/cloud/seed/nocloud`，按 MAC 认网卡、不改名，镜像别处一概不动。

- 镜像的根要在 ext4、xfs 或 btrfs 上。根在 LVM、LUKS 上，或镜像里找不到 cloud-init、
  cloud-init 被禁用、已经自带种子、单独挂了 `/var`，都只说一声、不写。
- 写了种子，镜像里的 cloud-init 就会按第一次开机跑一遍它自己的默认配置（扩分区、
  生成主机密钥、建默认用户之类）。
- 机器上挂着云厂商的 cidata 种子盘时，cloud-init 也会读它，它带的网络配置会顶掉这里写的。
- 种子按 netplan 的写法写，Debian、Ubuntu 的云镜像原样采用；不用 netplan 的镜像由
  cloud-init 自己转换，网关不在地址的网段里时，默认路由可能配不上。

几家云厂商的机器有已知的坑，认出来会多做一步，并在屏幕和日志里说认出了什么、做了什么。
识别只读本机的 DMI 与 sysfs，不往外发请求：

- **腾讯云**（DMI 的 `sys_vendor`，CVM 与轻量都是）：部分机型的 virtio 盘一次请求超过
  512 KiB 时，大块写入会出 I/O 错误。临时系统写盘前把 `max_sectors_kb` 设成 512；装好的
  Debian、Ubuntu 写一条和腾讯自家镜像同样作用的 udev 规则并重建 initramfs，Alpine 写进
  `mdev.conf`。dd 的镜像照原样写，屏幕上会提醒它得自带这条设置。
- **Azure**：NVMe 盘挂在 Hyper-V 虚拟 PCI 总线后面时，装 Alpine 会把 `pci-hyperv` 加进
  initramfs，否则开机找不到根。Debian 11 起与 Ubuntu 22.04 起的 initramfs 本来就带它，
  更老的版本在这种盘上没验过。开了加速网络时 VF 和合成网卡是同一个 MAC，写给 netplan
  （Debian 12 / 13、Ubuntu）与 dd 的网络配置除了 MAC 还按驱动认网卡。否则 networkd
  把 VF 也配上，Ubuntu 开机多等两分钟网络，最后是 degraded。

重启之前反悔：

```bash
sudo bash reinstall.sh reset
```

它收回一次性启动项，删掉下载的内核和写进引导配置的条目，下次开机照常进原系统。
脚本中途出错或按了 Ctrl+C，会自己做这一步。

## 安全

**校验覆盖到哪一段**：Ubuntu 云镜像做 GPG 签名校验（签名必须出自脚本里
钉住的那把密钥）加 SHA256，Debian 云镜像做 SHA512 完整性校验；校验和（Ubuntu 的连同签名）
在动硬盘之前就取回、验过，下载完只比对镜像哈希。**`dd` 模式不校验任何东西**
——镜像的完整性由你自己负责。

**引导脚本按 commit 钉住**：运行时会把 raw 地址解析成 40 位 commit SHA 再取脚本，
也可以用 `--commit` 自己指定一个（只接受 40 位小写十六进制）。解析不出来就直接报错退出，
不会退回分支引用——退回去等于没钉。

**下载并非全程严格 HTTPS**：临时 Alpine 启动时自己取的两样（软件仓库与 modloop）走明文
HTTP，因为甲骨文云的 ARM 机器在那个阶段还没同步时钟，HTTPS 会失败。apk 软件包靠 apk 自带的签名校验，
modloop 必须与开机前经 HTTPS 取得的那份 SHA-256 一致才挂载，否则启动停在那一步。
其余下载**默认校验 TLS 证书**；宿主的 CA 库坏掉时（32 位 Cygwin 是已知的一例）可以加
`--allow-insecure-bootstrap` 关掉校验，**代价是 `trans.sh`、临时 Alpine 与 Ubuntu 签名密钥
都可以在传输中被替换**，加上这个旗标会打一条警告。

**装完之后 root 登录是开着的**：给了 SSH key 就写进 root 的 `authorized_keys`，root 用 key
登录，密码字段是 `*`，没有密码能登，控制台也不行；没给 key 就设一个 root 密码，并打开 sshd 的
root 密码登录。装好第一件事该是收紧它。

**`--ssh-key` 接受 `http://` 地址**——那意味着公钥可以在传输中被替换成别人的。
请只用 `https://` 或 `github:` / `gitlab:`。

**日志页默认只绑 `127.0.0.1` 且没有鉴权。** `--web-public` 会把它绑到 `0.0.0.0`
并打一条警告；要从别处看，用 SSH 端口转发。

**隐私默认值**：时区默认 UTC，要按 IP 猜时区得显式加 `--detect-timezone`（那会把你的
IP 交给第三方服务，帮助信息里就这么写着）；口令用 `read -s` 读、不回显；打印口令的行都带
password 字样，写日志时整行丢掉；临时系统只拿到口令的 SHA-512 哈希。

## 能力边界

- **只能装那四个目标。** CentOS、Rocky、Fedora、Arch、openSUSE、NixOS、Windows
  全部会直接报错退出。脚本仍能**从**这些系统上运行（包括 Windows / Cygwin），只是装不出它们。
- **架构只有 x86_64 和 aarch64**，而且 32 位 x86 会被当成 x86_64 处理。
- **OpenVZ / LXC 这类容器虚拟化不支持**，Secure Boot 要先关掉。
- **BIOS 引导、用 GRUB、`/boot` 又在 btrfs、ZFS、LVM、软 RAID 或加密盘上的机器不支持**：
  GRUB 在那里改写不了 grubenv，一次性启动项会一直生效，每次重启都进临时系统。脚本在
  动手之前就报错退出。openSUSE 的 btrfs 例外，它的 GRUB 为此打了补丁。
- **`dd` 模式不改密码、不配网络、不装驱动**——镜像必须自带能用的配置，唯一的例外是
  显式加了 `--cloud-init-network` 时写进去的网络种子。
  写盘前会读镜像开头的分区表，最后一个分区的末尾超出目标盘就退出；
  读不出分区表的镜像不核。
- **Debian 要的盘比镜像本身大**：云镜像的整个虚拟盘（Debian 13 是 3 GiB）要和存放下载的
  分区一起放得下，arm64 的 Debian 13 约要 3.5 GiB。放不下的话临时系统在擦盘之前退出，
  重启回原系统。
- **必须能自动探测到网络**（IPv4 或 IPv6 任一即可），拿不到就报错退出。
  纯 IPv6 的机器要带 `--commit <SHA>`：把分支解析成 commit 要访问 `api.github.com`，
  它没有 IPv6 地址。
- **`--minimal` 只对 Ubuntu 有效**，对 Debian 是静默无效的。
- **EFI 机器上 DD 一个非 EFI 镜像会弹二次确认**，从 stdin 读一行 `y`：stdin 已读完
  （如 `--password-stdin` 的管道）就报错退出，开着却没人输入就一直等。
- **`--commit` 只收 40 位 SHA，不收 tag 名。** 仓库打了 tag（如 `v0.1.0`），
  要钉它就用它指向的 SHA。

## 与上游的区别

上游 [bin456789/reinstall](https://github.com/bin456789/reinstall) 支持面大得多——
Windows、RHEL 系、传统安装器、netboot.xyz、国内镜像自适配。我把这些全砍了，换来不到
上游一半长的脚本和隐私优先的默认值：不做 IP 地理定位、默认 UTC、密码不进 `ps` 和 shell
history、引导脚本按 commit SHA 钉住、Ubuntu 云镜像验签。

**如果你在 GFW 内、或者需要装 Windows 和 RHEL 系，请直接用上游**，那才是它的主场。

## 许可证

GNU 通用公共许可证 v3.0 —— 见 [LICENSE](LICENSE)。继承自上游
[bin456789/reinstall](https://github.com/bin456789/reinstall)。
