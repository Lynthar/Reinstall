# Reinstall

[![license](https://img.shields.io/github/license/Lynthar/Reinstall)](LICENSE)
[![shellcheck](https://img.shields.io/github/actions/workflow/status/Lynthar/Reinstall/shellcheck.yml?branch=main&label=shellcheck)](https://github.com/Lynthar/Reinstall/actions/workflows/shellcheck.yml)

隐私优先的 VPS 一键重装脚本：DD 任意 raw 镜像，或装 Debian / Ubuntu 云镜像与 Alpine；默认 UTC、不做 IP 定位

简体中文 | [English](README.en.md)

把一台正在跑着的 VPS 重装成别的系统。它先改引导让机器重启进一个临时的 Alpine，
再在那里面把目标系统真正装上去。**这个脚本会擦盘**——跑之前先备份，最好先在一台
可以重建的机器上试一次。

能装四种东西：Debian 11/12/13、Ubuntu 20.04/22.04/24.04/25.10、Alpine 3.20–3.23，
以及 `dd` 任意 raw 镜像（`http(s)://` 或磁力链）。Debian 与 Ubuntu 走官方云镜像。

## 安装

不需要安装。下载脚本，用 root 跑：

```bash
curl -O https://raw.githubusercontent.com/Lynthar/Reinstall/main/reinstall.sh
```

## 用法

```bash
sudo bash reinstall.sh debian 12
sudo bash reinstall.sh ubuntu 24.04 --minimal
sudo bash reinstall.sh alpine 3.22
sudo bash reinstall.sh dd --img "https://example.com/x.img.xz"
```

不写版本号就取该系列最新的一个。口令建议从 stdin 给，不要用 `--password`——
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

其它常用旗标：`--timezone`、`--ssh-port`、`--web-port`、`--no-web`、
`--hold 1|2`（停在安装环境或装完不重启）、`--force-boot-mode bios|efi`、`-x` 调试、
`--commit <SHA>` 钉住引导脚本的版本。没有配置文件也没有环境变量，行为全部由旗标决定；
DNS 写死在 `1.1.1.1` 与 `8.8.8.8`（IPv6 对应 Cloudflare 与 Google）。

## 安全

**校验覆盖的是哪一段，说清楚**：Ubuntu 云镜像做 GPG 签名校验（签名必须出自脚本里
钉住的那把密钥）加 SHA256，Debian 云镜像做 SHA512 完整性校验；签过名的校验和在动硬盘之前
就取回验过，下载完只比对镜像哈希。**`dd` 模式不校验任何东西**
——镜像的完整性由你自己负责。

**引导脚本按 commit 钉住**：运行时会把 raw 地址解析成 40 位 commit SHA 再取脚本，
也可以用 `--commit` 自己指定一个（只接受 40 位小写十六进制）。解析不出来就直接报错退出，
不会退回分支引用——退回去等于没钉。

**下载并非全程严格 HTTPS**：临时 Alpine 启动时自己取的两样走明文 HTTP（脚本里有注释说明
是为了绕开某些云厂商 ARM 机器上时钟未同步导致 TLS 失败）——apk 软件包靠 apk 自带的签名校验，
modloop 必须与开机前经 HTTPS 取得的那份 SHA-256 一致才挂载，否则启动停在那一步。
其余下载**默认校验 TLS 证书**；宿主的 CA 库坏掉时（32 位 Cygwin 是已知的一例）可以加
`--allow-insecure-bootstrap` 关掉校验，**代价是 `trans.sh`、临时 Alpine 与 Ubuntu 签名密钥
都可以在传输中被替换**，加上这个旗标会打一条警告。

**装完之后 root 登录是开着的**：给了 SSH key 就写进 `authorized_keys` 并允许 root
用 key 登录；没给 key 就设一个 root 密码并允许密码登录。装好第一件事该是收紧它。

**`--ssh-key` 接受 `http://` 地址**——那意味着公钥可以在传输中被替换成别人的。
请只用 `https://` 或 `github:` / `gitlab:`。

**日志页默认只绑 `127.0.0.1` 且没有鉴权。** `--web-public` 会把它绑到 `0.0.0.0`
并打一条警告；正确的看法是用 SSH 端口转发。

**隐私默认值**：时区默认 UTC，要按 IP 猜时区得显式加 `--detect-timezone`（那会把你的
IP 交给第三方服务，帮助信息里就这么写着）；口令用 `read -s` 读、不回显；日志与 web
输出都过滤掉密码和 token。

## 能力边界

- **只能装那四个目标。** CentOS、Rocky、Fedora、Arch、openSUSE、NixOS、Windows
  全部会直接报错退出。脚本仍能**从**这些系统上运行（包括 Windows / Cygwin），只是装不出它们。
- **架构只有 x86_64 和 aarch64**，而且 32 位 x86 会被当成 x86_64 处理。
- **OpenVZ / LXC 这类容器虚拟化不支持**，Secure Boot 要先关掉。
- **`dd` 模式不改密码、不配网络、不装驱动**——镜像必须自带能用的配置。
  也**不预检磁盘容量**。
- **必须能自动探测到网络**（IPv4 或 IPv6 任一即可），拿不到就报错退出。
- **`--minimal` 只对 Ubuntu 有效**，对 Debian 是静默无效的。
- **EFI 机器上 DD 一个非 EFI 镜像会弹二次确认**，非交互场景下会卡住。
- **没有打过 tag，没有版本号。** 想钉一个已知可用的版本，用 `--commit <SHA>`。

## 与上游的区别

上游 [bin456789/reinstall](https://github.com/bin456789/reinstall) 支持面大得多——
Windows、RHEL 系、传统安装器、netboot.xyz、国内镜像自适配。我把这些全砍了，换来短
一半左右的脚本和隐私优先的默认值：不做 IP 地理定位、默认 UTC、密码不进 `ps` 和 shell
history、引导脚本按 commit SHA 钉住、云镜像验签。

**如果你在 GFW 内、或者需要装 Windows 和 RHEL 系，请直接用上游**，那才是它的主场。

## 许可证

GNU 通用公共许可证 v3.0 —— 见 [LICENSE](LICENSE)。继承自上游
[bin456789/reinstall](https://github.com/bin456789/reinstall)。
