# reinstall

English | [简体中文](README.md)

One-shot DD reinstall script (slimmed fork)

> Reworked from [bin456789/reinstall](https://github.com/bin456789/reinstall), focused on **privacy- and security-first DD / cloud-image installation for VPSes outside the GFW**.

## Design goals

- **Privacy first**: no IP geolocation by default; password not exposed via `ps` or shell history; downloads HTTPS-only
- **Supply-chain pinning**: `confhome` is auto-pinned to a specific git commit SHA so the script can't drift mid-run if upstream changes
- **Minimal scope**: only 4 install targets (dd / alpine / debian / ubuntu cloud image); ~44% less code than upstream

## Requirements

| Item | Required |
|------|----------|
| Host OS | any Linux distribution (or Cygwin on Windows) |
| RAM | 256 MB+ |
| Disk | depends on the target image |

> **Not supported**: OpenVZ / LXC container virt, Secure Boot, networks behind the GFW

## Download

```bash
curl -O https://raw.githubusercontent.com/Lynthar/Reinstall/main/reinstall.sh
```

## Usage

```
./reinstall.sh debian   11|12|13
                ubuntu   20.04|22.04|24.04|25.10 [--minimal]
                alpine   3.20|3.21|3.22|3.23
                dd       --img="https://xxx.com/yyy.zzz" (raw image stored in raw/vhd/tar/gz/xz/zst)
```

### DD an arbitrary raw image

> **Warning**: this wipes **the entire disk** (all partitions) on the current system!

Supported image formats:
- `raw` and fixed-size `vhd`
- compressed: `.gz` `.xz` `.zst` `.tar` `.tar.gz` `.tar.xz` `.tar.zstd`

```bash
bash reinstall.sh dd --img "https://example.com/xxx.xz"
```

DD mode performs **no post-processing** on the image (no password / network / driver tweaking). Your image must be self-configured.

### Install Debian / Ubuntu cloud image

```bash
bash reinstall.sh debian 12
bash reinstall.sh ubuntu 24.04 --minimal
```

Downloads the official cloud-image qcow2 from `cdimage.debian.org` / `cloud-images.ubuntu.com`, then injects password, SSH key, network and timezone via cloud-init.

**Image verification**:
- **Ubuntu**: full GPG signature + SHA256 chain. `trans.sh` fetches `SHA256SUMS` + `SHA256SUMS.gpg` from the mirror, imports the UEC Image Automatic Signing Key from this repo's `keys/ubuntu-cloud.asc` (fingerprint `D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81`), verifies the signature, then cross-checks the qcow2's SHA256 against the signed sums. Any failure aborts.
- **Debian**: SHA512 integrity check only (catches download corruption). The Debian Cloud team currently publishes no GPG signature for cloud images (`SHA512SUMS.sign`/`.asc`/`.gpg` all 404), so **this does not defend against a compromised mirror** — that part is left to HTTPS transport security.

### Install Alpine / boot into Alpine Live OS

```bash
bash reinstall.sh alpine 3.22            # install Alpine
bash reinstall.sh alpine --hold 1        # reboot into Live OS (rescue, backup, manual DD, ...)
```

## Install-time options

| Flag | Description |
|------|-------------|
| `--password PASSWORD` | Set the root / install-time SSH password **(visible in `ps` and shell history)** |
| `--password-stdin` | Read password from stdin (recommended for automation) |
| `--ssh-key KEY` | SSH public key (formats below) |
| `--ssh-port PORT` | SSH port on the new system |
| `--web-port PORT` | Install-time web log viewer port (default 80) |
| `--web-public` | Bind web log viewer to `0.0.0.0` (default `127.0.0.1`, view via SSH port forward) |
| `--no-web` | Disable the web log viewer entirely |
| `--timezone TZ` | Set timezone explicitly, e.g. `Asia/Tokyo` (default `UTC`) |
| `--detect-timezone` | Auto-detect via ipapi.co **(leaks your egress IP to a third party)** |
| `--commit SHA` | Pin `confhome` to a specific git commit |
| `--hold 1` | Reboot into the install environment but don't run the install |
| `--hold 2` | Don't reboot after DD finishes; SSH back in and reboot manually |

### SSH key formats

- `--ssh-key "ssh-rsa ..."`
- `--ssh-key "ssh-ed25519 ..."`
- `--ssh-key "ecdsa-sha2-nistp256/384/521 ..."`
- `--ssh-key https://path/to/public_key`
- `--ssh-key github:username`
- `--ssh-key gitlab:username`
- `--ssh-key /path/to/public_key`

## Privacy model

| Behavior | Who sees what |
|----------|---------------|
| Image download | The mirror (`cdimage.debian.org` / `cloud-images.ubuntu.com` / `dl-cdn.alpinelinux.org` / your DD URL). Ubuntu downloads are GPG-verified + SHA256-checked; Debian is SHA512 integrity only (no upstream signature available) |
| GitHub API call to resolve commit SHA | `api.github.com` (one request per run) |
| Install-time log viewer (HTTP `:80`) | Bound to `127.0.0.1` by default — use `ssh -L 8080:127.0.0.1:80` to view; only `--web-public` exposes it to the internet |
| `--detect-timezone` | `ipapi.co` sees your egress IP (off by default) |
| **Password** | `--password ARG` ends up in `ps` and shell history; prefer `--password-stdin` |

## Watching install progress

You can monitor the install via:
- SSH (password is whatever you passed to `--password` or the random one printed at the end)
- WebSocket live log: bound to `127.0.0.1:80` by default — use `ssh -L 8080:127.0.0.1:80 root@SERVER` then open `http://localhost:8080`. Use `--web-public` to expose publicly, or `--no-web` to disable
- Provider VNC console
- Serial console

If the install errors out you can still SSH in and run `/trans.sh alpine` to drop into Alpine for manual recovery.

## Self-hosting the script

To use your own fork:

1. Fork this repo
2. Change `confhome` at `reinstall.sh:7` to your raw URL
3. Republish

`confhome` is auto-pinned to the HEAD commit of `main` by default; users can override with `--commit SHA`.

## Differences from upstream bin456789/reinstall

**Removed**:
- Windows-as-target install (`setos_windows`, `install_windows`, Windows driver injection)
- Traditional Linux installers (debian-installer / RHEL anaconda)
- All cloud-image support except Debian / Ubuntu (centos / almalinux / rocky / fedora / oracle / opensuse / arch / nixos / gentoo / aosc / fnos / kali / openeuler / opencloudos / anolis / redhat)
- `netboot.xyz` network boot
- `frpc` reverse-tunnel
- China mirror sources + IP geolocation (`is_in_china`)
- `--allow-ping` `--rdp-port` `--add-driver` `--installer` `--force-old-windows-setup` and other Windows flags

**Changed defaults**:
- Default timezone is `UTC`; no network probe unless `--detect-timezone`
- Hardcoded international DNS in `initrd-network.sh`: `1.1.1.1` / `8.8.8.8`
- `confhome` auto-pinned to commit SHA
- `prompt_password` hides terminal input (`-s`)
- Web log viewer bound to `127.0.0.1` by default (was `0.0.0.0`)
- Cloud-image downloads now verified (Ubuntu GPG, Debian SHA512)
- New flags: `--password-stdin` / `--timezone TZ` / `--detect-timezone` / `--web-public` / `--no-web`

## License

Distributed under the same license as the upstream project; see [LICENSE](LICENSE).

## Credits

- [bin456789/reinstall](https://github.com/bin456789/reinstall) — upstream project
