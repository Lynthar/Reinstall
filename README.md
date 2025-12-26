# reinstall

一键 DD 重装脚本（精简版）

> 基于 [bin456789/reinstall](https://github.com/bin456789/reinstall) 精简，专注于 DD 模式安装 Linux 系统

## 特点

- **安全隐私优先**：不使用中国境内镜像源，固定使用国际 DNS (1.1.1.1, 8.8.8.8)
- **自动时区检测**：基于 VPS IP 地理位置自动设置正确的时区
- **精简高效**：仅保留 DD 模式核心功能，代码量大幅减少
- **稳定可靠**：保留完整的网络配置、SSH 设置等关键功能

## 系统要求

| 类型 | 要求 |
|------|------|
| 原系统 | 任意 Linux 发行版 |
| 内存 | 256 MB+ |
| 硬盘 | 取决于 DD 镜像大小 |

> **注意**：本脚本不支持 OpenVZ、LXC 虚拟机

## 下载

```bash
curl -O https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/reinstall.sh
```

## 功能

### DD RAW 镜像到硬盘

> **警告**：此功能会清除当前系统**整个硬盘**的全部数据（包含其它分区）！

支持的镜像格式：
- `raw` 和固定大小的 `vhd` 镜像
- 压缩格式：`.gz` `.xz` `.zst` `.tar` `.tar.gz` `.tar.xz` `.tar.zst`

```bash
bash reinstall.sh dd --img "https://example.com/xxx.xz"
```

#### 可选参数

| 参数 | 说明 |
|------|------|
| `--password PASSWORD` | 设置 SSH 登录密码（用于安装期间查看日志） |
| `--ssh-key KEY` | 设置 SSH 公钥登录 |
| `--ssh-port PORT` | 修改 SSH 端口（安装期间观察日志用） |
| `--web-port PORT` | 修改 Web 端口（安装期间观察日志用） |
| `--hold 1` | 仅重启到安装环境，不运行安装 |
| `--hold 2` | DD 结束后不重启，用于 SSH 登录修改系统内容 |

### 重启到 Alpine Live OS（内存系统）

可用于备份/恢复硬盘、手动 DD、修改分区等操作。

```bash
bash reinstall.sh alpine --hold 1
```

## 自动时区检测

脚本会自动检测 VPS 的 IP 地理位置并设置正确的时区：

1. 使用 ipapi.co API（主要）
2. 使用 ip-api.com API（备用）
3. 使用 worldtimeapi.org API（备用）
4. 如果都失败，默认使用 UTC

## SSH 公钥格式

支持以下格式：

- `--ssh-key "ssh-rsa ..."`
- `--ssh-key "ssh-ed25519 ..."`
- `--ssh-key "ecdsa-sha2-nistp256/384/521 ..."`
- `--ssh-key http://path/to/public_key`
- `--ssh-key github:your_username`
- `--ssh-key gitlab:your_username`
- `--ssh-key /path/to/public_key`

## 查看安装进度

可通过以下方式查看安装进度：
- SSH 登录
- HTTP 80 端口访问
- 商家后台 VNC
- 串行控制台

即使安装过程出错，也能连接 SSH 进行手动救砖。可以运行 `/trans.sh alpine` 自动救砖成 Alpine 系统。

## 自定义使用

1. Fork 本仓库
2. 修改 `reinstall.sh` 开头的 `confhome` 为您自己的仓库地址
3. 根据需要修改其它代码

## 与原版的区别

| 功能 | 原版 | 本版 |
|------|------|------|
| Windows 安装 | ✓ | ✗ |
| 传统 Linux 安装器 | ✓ | ✗ |
| DD 模式 | ✓ | ✓ |
| Alpine Live OS | ✓ | ✓ |
| 中国镜像源 | ✓ | ✗ |
| 自动时区检测 | ✗ | ✓ |
| frpc 内网穿透 | ✓ | ✗ |
| netboot.xyz | ✓ | ✗ |

## 许可证

本项目基于原项目的许可证进行分发，详见 [LICENSE](LICENSE) 文件。

## 致谢

- [bin456789/reinstall](https://github.com/bin456789/reinstall) - 原项目
