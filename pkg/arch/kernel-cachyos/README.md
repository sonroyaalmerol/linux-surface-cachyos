# Linux Surface + CachyOS Kernel

A fully automated Arch Linux kernel package combining **CachyOS performance patches** with **linux-surface device support patches**.

## What This Does

- Starts from the kernel CachyOS provides (vanilla + CachyOS patches for 6.x, pre-patched tarball for 7.x)
- Applies linux-surface patches on top for Microsoft Surface device support
- Merges configs using linux-surface's own versioned configs (no manual maintenance)
- Only **two lines** need manual changes per version: `_major` and `_minor`

## Automation

Everything is automated via the sync script and CI workflow:

```mermaid
graph LR
    A[Daily CI Schedule] --> B[Check Updates]
    B -->|New patches| C[Run sync script]
    C --> D[Discover patches via API]
    D --> E[Regenerate PKGBUILD]
    E --> F[Verify patches apply]
    F --> G[Commit & Push]
    G --> H[Build locally]
```

### Sync Script

```bash
# Auto-detect and sync to latest versions
./scripts/sync-cachyos-surface.sh --verify --commit

# Target specific version
./scripts/sync-cachyos-surface.sh --version=6.19 --verify --commit

# Just check if updates exist
./scripts/sync-cachyos-surface.sh --update-check

# Preview without changes
./scripts/sync-cachyos-surface.sh --dry-run
```

### CI Workflow

The `.github/workflows/sync-cachyos-surface.yml` workflow:

- Runs daily at 06:00 UTC
- Checks for new linux-surface patches and CachyOS releases
- Auto-discovers patch URLs via GitHub API
- Regenerates the PKGBUILD source array
- Verifies patches apply (dry-run)
- Commits and pushes changes

### What's Dynamic vs Static

| What                      | Dynamic (auto-discovered)                       | Static (rarely changes)              |
| ------------------------- | ----------------------------------------------- | ------------------------------------ |
| Surface patches           | ✅ Filenames queried from GitHub API            | —                                    |
| Surface config            | ✅ Downloaded from `configs/surface-X.Y.config` | —                                    |
| CachyOS base patch        | ✅ URL found by checking multiple locations     | —                                    |
| CachyOS scheduler         | ✅ URL based on `_cpusched` + `_major`          | —                                    |
| CachyOS config            | ✅ Downloaded from `linux-cachyos-bore/config`  | —                                    |
| CachyOS+Surface overrides | —                                               | `cachyos-surface.config` (committed) |
| Version numbers           | —                                               | `_major`, `_minor` in PKGBUILD       |

## Installation on CachyOS

### Prerequisites

```bash
# Install build dependencies (CachyOS provides most of these)
sudo pacman -S --needed base-devel bc binutils cpio gettext libelf openssl \
    pahole perl python rust rust-bindgen rust-src tar xxhash xz zlib zstd
```

### Option A: Build from Source (Recommended)

```bash
# 1. Clone the repository
git clone https://github.com/sonroyaalmerol/linux-surface-cachyos.git
cd linux-surface-cachyos

# 2. Sync to latest patches (optional — PKGBUILD is already synced)
./scripts/sync-cachyos-surface.sh --verify

# 3. Build the kernel (takes 1-2 hours on 12 cores)
cd pkg/arch/kernel-cachyos
makepkg -sf

# 4. Install the built packages
sudo pacman -U linux-surface-cachyos-6.19.0-1-x86_64.pkg.tar.zst
sudo pacman -U linux-surface-cachyos-headers-6.19.0-1-x86_64.pkg.tar.zst
```

### Option B: Build with Custom Schedulers

The PKGBUILD supports three scheduler variants. Edit `pkg/arch/kernel-cachyos/PKGBUILD`:

```bash
# In the build configuration section, change _cpusched:
_cpusched=bore    # BORE (default) — best for interactive desktop
_cpusched=eevdf   # EEVDF — vanilla Linux default
_cpusched=bmq     # BMQ — throughput-oriented
```

### After Installing

#### 1. Generate initramfs and bootloader entry

On CachyOS, this happens **automatically** via `kernel-install` when you install the package. The package installs:

- `/usr/lib/modules/6.19.0-1-surface-cachyos/vmlinuz` — the kernel image
- `/usr/lib/modules/6.19.0-1-surface-cachyos/pkgbase` — tells `kernel-install` the kernel name

If `kernel-install` doesn't run automatically, generate manually:

```bash
# Generate initramfs
sudo mkinitcpio -P

# If using systemd-boot (CachyOS default):
sudo bootctl update

# If using GRUB:
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

#### 2. Install Surface-specific packages

```bash
# Add the linux-surface repo (if not already added)
sudo pacman-key --recv-keys 56F7BA2D2A8D6F5E
sudo pacman-key --finger 56F7BA2D2A8D6F5E
sudo pacman-key --lsign-key 56F7BA2D2A8D6F5E

# Add to /etc/pacman.conf:
# [linux-surface]
# Server = https://pkg.surfacelinux.com/arch/

sudo pacman -Sy

# Install Surface utilities
sudo pacman -S iptsd surface-aggregation-module-dkms surface-dtx-daemon \
    linux-firmware-marvell libwacom-surface
```

#### 3. Enable Surface services

```bash
# IPTS daemon (touchscreen/pen on Intel Surface devices)
sudo systemctl enable --now iptsd

# Surface DTX (dynamic tablet detachment on Book devices)
sudo systemctl enable --now surface-dtx-daemon

# If you have a Surface Laptop Studio or similar with ITHC:
# ITHC is built into the kernel module, no daemon needed
```

#### 4. Verify everything is working

```bash
# Check kernel version
uname -r
# Expected output: 6.19.0-1-surface-cachyos or similar

# Check Surface Aggregator Module
lsmod | grep surface_aggregator
# Should show: surface_aggregator

# Check touchscreen
lsmod | grep ipts
# Should show: hid_ipts (Intel devices) or hid_ithc (newer devices)

# Check WiFi
lsmod | grep mwifiex
# Or for Ath10k devices:
lsmod | grep ath10k

# Check CachyOS features
grep -E 'CACHY|SCHED_BORE|HZ_1000' /boot/config-$(uname -r) 2>/dev/null || \
zgrep -E 'CACHY|SCHED_BORE|HZ_1000' /proc/config.gz
# Should show: CONFIG_CACHY=y, CONFIG_SCHED_BORE=y, CONFIG_HZ_1000=y
```

### Rebuilding After Updates

When a new version is synced (automatically by CI or manually):

```bash
cd linux-surface-cachyos

# Pull the latest changes
git pull

# Re-sync (if needed)
./scripts/sync-cachyos-surface.sh --verify

# Rebuild
cd pkg/arch/kernel-cachyos
makepkg -sf

# Install (remove old first to avoid conflicts)
sudo pacman -R linux-surface-cachyos linux-surface-cachyos-headers
sudo pacman -U linux-surface-cachyos-*.pkg.tar.zst
```

### Troubleshooting

**Kernel doesn't appear in boot menu:**

```bash
# Check that kernel-install picked it up
ls /boot/loader/entries/ | grep surface-cachyos

# If missing, regenerate manually:
sudo kernel-install add $(uname -r) /usr/lib/modules/$(uname -r)/vmlinuz
```

**Touchscreen not working after suspend:**

```bash
# Restart IPTSD
sudo systemctl restart iptsd
```

**WiFi not working:**

```bash
# Load the correct module
sudo modprobe mwifiex_pcie    # For Marvell-based devices (SP5, SL2/3)
sudo modprobe ath10k_pci       # For Qualcomm-based devices (SP6+, SL4+)
```

**Build fails with "missing module":**

```bash
# Ensure all build dependencies are installed
sudo pacman -S --needed base-devel bc cpio gettext kmod libelf openssl \
    pahole perl python rust rust-bindgen rust-src tar xxhash xz zstd
```

## Supported Surface Devices

- Surface Pro 3–9 (including 7+, X)
- Surface Laptop 1–5 (including AMD variants)
- Surface Book 1–3
- Surface Studio 1–2
- Surface Go 1–3
- Surface Duo

## CachyOS Features

- BORE CPU scheduler (or EEVDF/BMQ/RT)
- -O3 compiler optimization
- 1000Hz tick rate
- Full preempt
- Transparent HugePages (overridden to madvise for Surface)
- BBR3 TCP congestion (optional)
- native CPU optimizations

## Config Merge Strategy

Four-layer merge applied in order:

1. **CachyOS base config** — Starting point from CachyOS/linux-cachyos
2. **Surface config** — Downloaded from `linux-surface/configs/surface-X.Y.config`
3. **linux-surface overrides** — Downloaded from `linux-surface/.github/data/autoupdate/kernel-overrides.config`
4. **cachyos-surface.config** — Our committed override resolving CachyOS+Surface conflicts

The last layer wins. Using linux-surface's own versioned configs means Kconfig
option names are always correct for the target kernel version (no manual
maintenance needed for things like `IPTS` → `HID_IPTS` renames).

## Version Lag

CachyOS and linux-surface may not be at the same kernel version. The sync
script uses the **minimum available version** — the highest version where
BOTH patch sets exist. When CachyOS is ahead, we wait for surface patches.

## License

Kernel: GPL-2.0-only
PKGBUILD and scripts: Same as Arch Linux packaging guidelines
