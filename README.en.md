# Reinstall

[![license](https://img.shields.io/github/license/Lynthar/Reinstall)](LICENSE)
[![shellcheck](https://img.shields.io/github/actions/workflow/status/Lynthar/Reinstall/shellcheck.yml?branch=main&label=shellcheck)](https://github.com/Lynthar/Reinstall/actions/workflows/shellcheck.yml)

Privacy-first VPS reinstall script: DD any raw image, or Debian/Ubuntu cloud images and Alpine. UTC by default.

English | [简体中文](README.md)

Reinstall a running VPS as something else. It rewrites the bootloader so the
machine comes back up in a temporary Alpine, then installs the target system
from there. **This erases disks** — back up first, and try it on a machine you
can rebuild.

Four targets: Debian 11/12/13, Ubuntu 20.04/22.04/24.04/25.10, Alpine
3.20–3.23, and `dd` of any raw image (over `http(s)://` or a magnet link).
Debian and Ubuntu go through official cloud images.

## Install

Nothing to install. Download the script and run it as root:

```bash
curl -O https://raw.githubusercontent.com/Lynthar/Reinstall/main/reinstall.sh
```

## Usage

```bash
sudo bash reinstall.sh debian 12
sudo bash reinstall.sh ubuntu 24.04 --minimal
sudo bash reinstall.sh alpine 3.22
sudo bash reinstall.sh dd --img "https://example.com/x.img.xz"
```

Leaving the version off picks the newest in that series. Prefer stdin for the
password — `--password` lands in `ps` and history:

```bash
printf '%s' "$PW" | sudo bash reinstall.sh --password-stdin debian 12
```

SSH keys can be a literal key, a file, an `https://` URL, or `github:username`:

```bash
sudo bash reinstall.sh debian 12 --ssh-key github:yourname
```

You can watch it work: a read-only log page runs on `127.0.0.1:80` by default,
so forward a port over SSH and follow along:

```bash
ssh -L 8080:127.0.0.1:80 root@your-server
```

Other flags you'll reach for: `--timezone`, `--ssh-port`, `--web-port`,
`--no-web`, `--hold 1|2` (stop in the installer environment, or don't reboot at
the end), `--force-boot-mode bios|efi`, `-x` for debugging, and `--commit <SHA>`
to pin the bootstrap scripts. There's no config file and no environment
variables — everything is a flag. DNS is hardcoded to `1.1.1.1` and `8.8.8.8`,
with Cloudflare and Google for IPv6.

## Security

**Be clear about what is and isn't verified.** Ubuntu cloud images get GPG
signature verification (with the key fingerprint cross-checked in the script)
plus SHA256; Debian cloud images get SHA512 integrity checking. **`dd` mode
verifies nothing** — the image's integrity is on you. The temporary Alpine
kernel and initramfs aren't verified either.

**The bootstrap is pinned to a commit.** At runtime the raw URL is resolved to a
40-hex commit SHA before anything is fetched, and `--commit` lets you choose one.

**Downloads are not strictly HTTPS end to end.** The temporary Alpine stage is
fetched over plain HTTP — there's a comment explaining it works around clocks
that aren't synced yet on some ARM instances — and `curl` is wrapped with
`--insecure`, inherited from upstream. **If man-in-the-middle is in your threat
model, know this going in.**

**Root login is enabled when it finishes.** With an SSH key, that key is written
to `authorized_keys` and root key login is allowed; without one, a root password
is set and password login is allowed. Tightening that should be your first move.

**`--ssh-key` accepts `http://` URLs**, which means the key can be swapped in
transit. Use `https://`, `github:` or `gitlab:` instead.

**The log page binds to `127.0.0.1` and has no authentication.**
`--web-public` binds it to `0.0.0.0` and warns you; SSH port forwarding is the
right answer.

**Privacy-first defaults.** The timezone is UTC unless you pass
`--detect-timezone`, which hands your IP to a third-party service — the help text
says so. Passwords are read with `read -s` without echo, and get filtered out of
both the log and the web output.

## Limitations

- **Only those four targets.** CentOS, Rocky, Fedora, Arch, openSUSE, NixOS and
  Windows all exit with an error. The script still *runs on* those systems,
  Windows and Cygwin included — it just can't install them.
- **x86_64 and aarch64 only**, and 32-bit x86 is treated as x86_64.
- **Container virtualisation such as OpenVZ and LXC isn't supported**, and Secure
  Boot has to be off.
- **`dd` mode doesn't set passwords, configure networking or install drivers** —
  the image has to arrive with a working configuration. It also **doesn't check
  disk capacity** first.
- **Network has to be auto-detectable** (IPv4 or IPv6 will do); if it can't work
  out an address, it exits.
- **`--minimal` only affects Ubuntu**, and is silently ignored for Debian.
- **DD-ing a non-EFI image on an EFI machine asks for confirmation**, which will
  hang an unattended run.
- **No tags and no version numbers.** To pin a known-good state, use
  `--commit <SHA>`.

## Differences from upstream

Upstream [bin456789/reinstall](https://github.com/bin456789/reinstall) supports
far more — Windows, RHEL-family, traditional installers, netboot.xyz, mirror
selection for networks inside China. I dropped all of that in exchange for
scripts about half the length and privacy-first defaults: no IP geolocation, UTC
unless you say otherwise, passwords kept out of `ps` and shell history, the
bootstrap pinned to a commit SHA, and signature checks on cloud images.

**If you're behind the GFW, or need Windows or a RHEL-family target, use
upstream** — that's what it's for.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE). Inherited from
upstream [bin456789/reinstall](https://github.com/bin456789/reinstall).
