# Reinstall

[![license](https://img.shields.io/github/license/Lynthar/Reinstall)](LICENSE)
[![shellcheck](https://img.shields.io/github/actions/workflow/status/Lynthar/Reinstall/shellcheck.yml?branch=main&label=shellcheck)](https://github.com/Lynthar/Reinstall/actions/workflows/shellcheck.yml)

Privacy-first VPS reinstall script: DD any raw image, or Debian/Ubuntu cloud images and Alpine. UTC by default.

English | [简体中文](README.md)

Reinstall a running VPS as something else. It rewrites the bootloader so the
machine comes back up in a temporary Alpine, then installs the target system
from there. **This erases disks** — back up first, and try it on a machine you
can rebuild.

Four targets: Debian 10/11/12/13, Ubuntu 18.04/20.04/22.04/24.04/26.04/26.10,
Alpine 3.22/3.23/3.24, and `dd` of any raw image (over `http(s)://` only). Without a
version you get the newest one listed; for Ubuntu that is the newest LTS, 26.04.
Debian and Ubuntu go through official cloud images. Debian 10 and 11 are past
official support, so the installed system uses Freexian's ELTS repository
(`deb.freexian.com`); its signing key fingerprint is pinned in the script.

## Install

Nothing to install. Download the script and run it as root:

```bash
curl -O https://raw.githubusercontent.com/Lynthar/Reinstall/main/reinstall.sh
```

To dd a Linux image from Windows, set up Cygwin yourself first: there's no
upstream-style `reinstall.bat` here, and under Cygwin the script installs
nothing, so a missing command fails the step that needs it. Install it from
PowerShell as below. The second and third lines let the PowerShell 5.1 that
ships with older Windows download over TLS 1.2. The installer has to go through
`Start-Process -Wait` and get `--wait`; otherwise PowerShell returns before
setup is done, including when setup relaunches itself to get admin rights.

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

Then open a Cygwin terminal as administrator (otherwise the script stops with
`Please run as administrator.`), fetch the script there with the curl line
above, and run it as in Usage, just without `sudo`.

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

The log itself is `/reinstall.log` in the temporary system; SSH in with the same
login to read it. Don't reboot or power off from the provider's panel while it
installs: once it is writing the disk, neither the old nor the new system can
boot. If something fails, the screen says whether the disk was touched. If it
wasn't, `reboot` goes back to the current system; if it was, don't reboot — fix
the cause over SSH and run `/trans.sh` again. The scene is packed into
`/tmp/reinstall-debug.tar.gz`; it holds IP addresses and the install log, so read
it before you share it.

Other flags you'll reach for: `--timezone`, `--ssh-port`, `--web-port`,
`--no-web`, `--hold 1|2` (stop in the installer environment, or don't reboot at
the end), `--force-boot-mode bios|efi`, `-x` for debugging, `--commit <SHA>`
to pin the bootstrap scripts, and `--hostname <name>` (not with dd; without it you
get the image's own name, or `debian` when a Debian image has none). There's no
config file and no environment variables — everything is a flag. DNS is hardcoded
to `1.1.1.1` and `8.8.8.8`, with Cloudflare and Google for IPv6.

Take care with `dd` on a machine with a static IP (no DHCP): the image goes on as
it is, so it has to carry this machine's addresses itself, or that address family
stays down after the reboot — and with everything static, the machine is
unreachable. Before the write, the temporary system lists the statically
configured addresses on screen and in the log. If the image has cloud-init
(general-purpose distribution cloud images usually do), add
`--cloud-init-network`: after the write, the detected network config goes into the
image's `/var/lib/cloud/seed/nocloud` as a NoCloud seed, matching NICs by MAC
without renaming them. Nothing else in the image is touched.

- The image's root has to be on ext4, xfs or btrfs. With the root on LVM or LUKS,
  or with cloud-init missing or disabled in the image, a seed already there or a
  separate `/var` mount, it says so and writes nothing.
- Once there is a seed, the image's cloud-init runs its own first-boot defaults
  (growing the partition, SSH host keys, the default user and so on).
- If the provider attaches a cidata seed disk, cloud-init reads that too, and its
  network config replaces the one written here.
- The seed is written the way netplan reads it, and Debian and Ubuntu cloud
  images take it as is. On images without netplan, cloud-init converts it itself,
  and when the gateway is outside the address's subnet the default route may not
  come up.

Machines from a few cloud providers have known pitfalls. When the script
recognises one it does one extra step, and says on screen and in the log what it
found and what it did. It only reads the local DMI and sysfs, and sends no
requests to find out:

- **Tencent Cloud** (DMI `sys_vendor`, both CVM and Lighthouse): on some
  instances a virtio disk fails heavy writes with I/O errors once a request goes
  over 512 KiB. The temporary system sets `max_sectors_kb` to 512 before the
  write; an installed Debian or Ubuntu gets a udev rule doing what the one in
  Tencent's own images does, plus a rebuilt initramfs, and Alpine gets a line in
  `mdev.conf`. A dd image is written as is, and the screen reminds you it has to
  set this itself.
- **Azure**: when the NVMe disk sits behind Hyper-V's virtual PCI bus, an Alpine
  install adds `pci-hyperv` to the initramfs, or it wouldn't find its root at
  boot. The initramfs of Debian 11 and later and of Ubuntu 22.04 and later already
  carries it; older releases haven't been tried on such a disk. With accelerated
  networking the VF carries the synthetic NIC's MAC, so the network config written
  for netplan (Debian 12 / 13, Ubuntu) and for dd matches the NIC by its driver as
  well as its MAC; otherwise networkd configures the VF too, and Ubuntu waits two
  extra minutes for the network at boot and ends up degraded.

Changed your mind before rebooting?

```bash
sudo bash reinstall.sh reset
```

That takes back the one-time boot entry and deletes the downloaded kernel and
the entries written into the boot configuration; the next boot starts the
current system as usual. If the script fails partway or you press Ctrl+C, it
does this itself.

## Security

**Be clear about what is and isn't verified.** Ubuntu cloud images get GPG
signature verification (the signature must come from the key pinned in the
script) plus SHA256; Debian cloud images get SHA512 integrity checking. The
signed checksums are fetched and verified before the disk is touched; only the
downloaded image's hash is compared afterwards. **`dd` mode
verifies nothing** — the image's integrity is on you.

**The bootstrap is pinned to a commit.** At runtime the raw URL is resolved to a
40-hex commit SHA before anything is fetched, and `--commit` lets you choose one
(40 lowercase hex characters, nothing else). If the SHA can't be resolved the
run aborts rather than falling back to the branch ref, which would pin nothing.

**Downloads are not strictly HTTPS end to end.** Two things the temporary Alpine
fetches for itself while booting go over plain HTTP — there's a comment
explaining it works around clocks that aren't synced yet on some ARM instances.
Its apk packages are checked against apk's own signatures, and the modloop is
only mounted if it matches the SHA-256 taken over HTTPS before the reboot;
otherwise the boot stops there. Everything else **verifies TLS certificates by
default**. Hosts with a broken CA store (32-bit Cygwin is the known one) can
turn that off with `--allow-insecure-bootstrap`, **at the price of letting
`trans.sh`, the temporary Alpine and the Ubuntu signing key be swapped in
transit**; the flag prints a warning when you use it.

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
- **BIOS machines booting with GRUB whose `/boot` is on btrfs, ZFS, LVM, software
  RAID or an encrypted disk aren't supported**: GRUB can't rewrite grubenv there,
  so the one-time boot entry would stick and every reboot would start the
  temporary system. The script refuses before touching anything. openSUSE's
  btrfs is the exception — its GRUB is patched for exactly this.
- **`dd` mode doesn't set passwords, configure networking or install drivers** —
  the image has to arrive with a working configuration. The one exception is the
  network seed written when you pass `--cloud-init-network`. Before the write it
  checks that the last partition in the image's partition table ends inside the
  target disk, and stops if it doesn't. An image whose partition table it cannot read is not
  checked.
- **Network has to be auto-detectable** (IPv4 or IPv6 will do); if it can't work
  out an address, it exits. An IPv6-only host needs `--commit <SHA>`: resolving the
  branch to a commit goes through `api.github.com`, which has no IPv6 address.
- **`--minimal` only affects Ubuntu**, and is silently ignored for Debian.
- **DD-ing a non-EFI image on an EFI machine asks for confirmation**: a `y` line
  on stdin. With stdin already used up (the `--password-stdin` pipe, say) it exits;
  with stdin open and nobody typing it waits.
- **`--commit` takes a 40-hex SHA, not a tag name.** The repository has tags
  (`v0.1.0`, for one); to pin a tag, pass the SHA it points to.

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
