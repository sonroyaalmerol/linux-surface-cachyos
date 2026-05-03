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

## Building

```bash
cd pkg/arch/kernel-cachyos

# 1. Sync (fetches latest patches, regenerates source array, updates checksums)
../../scripts/sync-cachyos-surface.sh --verify

# 2. Build
makepkg -sf
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

Three-layer merge applied in order:

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
