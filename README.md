# reinstall

一键 DD 重装脚本（精简版）

> 基于 [bin456789/reinstall](https://github.com/bin456789/reinstall) 重构，专注于 **VPS 上、非 GFW 网络环境** 的安全 / 隐私优先 DD 与云镜像安装

## 设计目标

- **隐私优先**：默认不联网泄露 IP 检测时区；密码不暴露在 `ps` / shell history；下载链接全部 HTTPS
- **供应链固定**：自动把 `confhome` 钉到具体 git commit SHA，防止脚本运行期间上游变更
- **范围最小**：只支持 4 种安装目标（dd / alpine / debian / ubuntu cloud image），代码量比上游减少约 44%

## 系统要求

| 类型 | 要求 |
|------|------|
| 原系统 | 任意 Linux 发行版（Cygwin 在 Windows 上也可） |
| 内存 | 256 MB+ |
| 硬盘 | 取决于目标镜像 |

> **不支持**：OpenVZ / LXC 容器虚拟化、安全启动 (Secure Boot)、GFW 内网络

## 下载

```bash
curl -O https://raw.githubusercontent.com/Lynthar/Reinstall/main/reinstall.sh
```

## 用法

```
./reinstall.sh debian   11|12|13
                ubuntu   20.04|22.04|24.04|25.10 [--minimal]
                alpine   3.20|3.21|3.22|3.23
                dd       --img="https://xxx.com/yyy.zzz" (raw image stores in raw/vhd/tar/gz/xz/zst)
```

### DD 任意 raw 镜像到硬盘

> **警告**：此功能会清除当前系统**整个硬盘**的全部数据（包含其它分区）！

支持的镜像格式：
- `raw` 和固定大小的 `vhd` 镜像
- 压缩格式：`.gz` `.xz` `.zst` `.tar` `.tar.gz` `.tar.xz` `.tar.zstd`

```bash
bash reinstall.sh dd --img "https://example.com/xxx.xz"
```

DD 模式不会对镜像做任何后处理（不修改密码、网络、驱动），用户提供的镜像必须自带正确配置。

### 安装 Debian / Ubuntu 云镜像

```bash
bash reinstall.sh debian 12
bash reinstall.sh ubuntu 24.04 --minimal
```

会从 `cdimage.debian.org` / `cloud-images.ubuntu.com` 下载官方 cloud image qcow2，然后通过 cloud-init 注入密码、SSH key、网络、时区。

### 安装 Alpine / 进入 Alpine Live OS

```bash
bash reinstall.sh alpine 3.22            # 安装 Alpine
bash reinstall.sh alpine --hold 1        # 重启进入 Live OS（救砖、备份、手动 DD 等）
```

## 安装期参数

| 参数 | 说明 |
|------|------|
| `--password PASSWORD` | 设置 root / 安装期 SSH 登录密码 **（会出现在 ps 和 shell history）** |
| `--password-stdin` | 从 stdin 读密码（推荐自动化场景） |
| `--ssh-key KEY` | 设置 SSH 公钥（详见下方格式） |
| `--ssh-port PORT` | 修改新系统 SSH 端口 |
| `--web-port PORT` | 修改安装期 web 日志端口（默认 80） |
| `--timezone TZ` | 显式设置时区，例如 `Asia/Tokyo`（默认 `UTC`） |
| `--detect-timezone` | 通过 ipapi.co 自动检测时区 **（会向第三方暴露出口 IP）** |
| `--commit SHA` | 把 `confhome` 钉到指定 git commit |
| `--hold 1` | 仅重启到安装环境，不运行安装 |
| `--hold 2` | DD 完成后不重启，可 SSH 修改系统再手动重启 |

### SSH 公钥格式

支持以下格式：

- `--ssh-key "ssh-rsa ..."`
- `--ssh-key "ssh-ed25519 ..."`
- `--ssh-key "ecdsa-sha2-nistp256/384/521 ..."`
- `--ssh-key https://path/to/public_key`
- `--ssh-key github:username`
- `--ssh-key gitlab:username`
- `--ssh-key /path/to/public_key`

## 隐私模型

| 行为 | 谁会看到 |
|------|----------|
| 镜像下载 | 镜像源（`cdimage.debian.org` / `cloud-images.ubuntu.com` / `dl-cdn.alpinelinux.org` / 用户提供的 DD 镜像 URL） |
| GitHub API 解析 commit SHA | `api.github.com`（每次运行 1 次） |
| 安装期日志查看（HTTP `:80`） | 任何能访问 80 端口的人——建议改 `--web-port` 并用防火墙限制 |
| `--detect-timezone` | `ipapi.co` 会看到出口 IP（默认不开启） |
| **密码** | `--password ARG` 会进入 `ps` 和 shell history；推荐 `--password-stdin` |

## 查看安装进度

可通过以下方式查看安装进度：
- SSH 登录（密码 = `--password` 提供的或随机生成的）
- HTTP 80 端口（默认）/ `--web-port` 指定的端口（WebSocket 实时流）
- 商家后台 VNC
- 串行控制台

即使安装过程出错，也能 SSH 进去手动救砖：运行 `/trans.sh alpine` 切到 Alpine 系统。

## 自托管

如果想用自己的 fork：

1. Fork 本仓库
2. 修改 `reinstall.sh:7` 的 `confhome` 为您的 raw URL
3. 重新发布

`confhome` 默认会自动 pin 到 main 分支的 HEAD commit；用户可用 `--commit SHA` 覆盖。

## 与上游 bin456789/reinstall 的差异

**删除**：
- Windows 目标安装（`setos_windows`、`install_windows`、Windows 驱动注入）
- 传统 Linux 安装器（debian-installer / RHEL anaconda）
- 除 debian / ubuntu 外的所有 cloud image 支持（centos / almalinux / rocky / fedora / oracle / opensuse / arch / nixos / gentoo / aosc / fnos / kali / openeuler / opencloudos / anolis / redhat）
- netboot.xyz 网络引导
- frpc 内网穿透
- 中国镜像源 + IP 地理位置探测 (`is_in_china`)
- `--allow-ping` `--rdp-port` `--add-driver` `--installer` `--force-old-windows-setup` 等参数

**修改**：
- 默认时区改为 `UTC`，不再联网探测
- 固定使用国际 DNS：`1.1.1.1` `8.8.8.8`（`initrd-network.sh`）
- `confhome` 自动钉到 commit SHA
- `prompt_password` 隐藏终端输入
- 新增 `--password-stdin` / `--timezone TZ` / `--detect-timezone`

## 许可证

本项目基于原项目的许可证进行分发，详见 [LICENSE](LICENSE) 文件。

## 致谢

- [bin456789/reinstall](https://github.com/bin456789/reinstall) - 原项目
