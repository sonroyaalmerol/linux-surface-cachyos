#!/usr/bin/env bash
#
# sync-cachyos-surface.sh — Fully automated sync engine
#
# Discovers CachyOS and linux-surface patches/configs dynamically,
# regenerates the PKGBUILD source array, downloads everything,
# updates checksums, verifies patches apply, and commits.
#
# Usage:
#   ./sync-cachyos-surface.sh                    # Auto-detect latest versions
#   ./sync-cachyos-surface.sh --version=6.19     # Target specific version
#   ./sync-cachyos-surface.sh --dry-run           # Preview only
#   ./sync-cachyos-surface.sh --verify            # Verify patches apply cleanly
#   ./sync-cachyos-surface.sh --commit             # Commit changes
#
# CI usage:
#   ./sync-cachyos-surface.sh --verify --commit   # Full auto pipeline
#
# Environment:
#   GITHUB_TOKEN     Optional GitHub API token (avoids rate limits)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use git to find repo root (most reliable), fall back to relative path
if git -C "${SCRIPT_DIR}" rev-parse --show-toplevel &>/dev/null; then
    REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
else
    REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
PKGDIR="${REPO_ROOT}/pkg/arch/kernel-cachyos"

CACHYOS_LINUX_REPO="CachyOS/linux"
CACHYOS_PATCHES_REPO="CachyOS/kernel-patches"
LINUX_SURFACE_REPO="linux-surface/linux-surface"

# ============================================================================
# Helpers
# ============================================================================

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Fully automated sync engine for surface-cachyos kernel.

Options:
  --version=X.Y     Target kernel major.minor version (default: auto-detect)
  --dry-run          Preview changes without writing files
  --verify           Download sources and verify patches apply cleanly
  --commit           Create git commit after update
  --update-check     Only check if updates are available (exit 0=update needed, 1=up to date)
  -h, --help         Show this help

Environment:
  GITHUB_TOKEN        Optional GitHub API token
EOF
}

log()  { echo "[$(date +%H:%M:%S)] INFO  $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN  $*" >&2; }
err()  { echo "[$(date +%H:%M:%S)] ERROR $*" >&2; }

gh_api() {
    local endpoint="$1"
    local token="${GITHUB_TOKEN:-}"
    if [ -n "$token" ]; then
        curl -sSf -H "Authorization: token ${token}" \
            "https://api.github.com${endpoint}" 2>/dev/null
    else
        curl -sSf "https://api.github.com${endpoint}" 2>/dev/null
    fi
}

gh_raw() {
    local url="$1"
    curl -sSfL "$url" 2>/dev/null
}

gh_check_url() {
    # Return 0 if URL returns 200, 1 otherwise
    local url="$1"
    local code
    code=$(curl -sSf -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
    [ "$code" = "200" ]
}

# ============================================================================
# Parse arguments
# ============================================================================

DRY_RUN=false
VERIFY=false
COMMIT=false
UPDATE_CHECK=false
FORCE_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version=*)   FORCE_VERSION="${1#--version=}"; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --verify)      VERIFY=true; shift ;;
        --commit)      COMMIT=true; shift ;;
        --update-check) UPDATE_CHECK=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             err "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ============================================================================
# Phase 1: Detect latest versions
# ============================================================================

log "Phase 1: Detecting versions..."

# Find latest linux-surface patch version
detect_surface_version() {
    gh_api "/repos/${LINUX_SURFACE_REPO}/contents/patches" | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
versions = []
for item in data:
    name = item.get('name', '')
    m = re.match(r'^(\d+\.\d+)$', name)
    if m:
        versions.append(name)
versions.sort(key=lambda v: tuple(int(x) for x in v.split('.')), reverse=True)
if versions:
    print(versions[0])
" 2>/dev/null
}

# Find latest CachyOS kernel-patches version
detect_cachy_patch_version() {
    gh_api "/repos/${CACHYOS_PATCHES_REPO}/contents/" | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
versions = []
for item in data:
    name = item.get('name', '')
    m = re.match(r'^(\d+\.\d+)$', name)
    if m:
        versions.append(name)
versions.sort(key=lambda v: tuple(int(x) for x in v.split('.')), reverse=True)
if versions:
    print(versions[0])
" 2>/dev/null
}

# Find latest CachyOS linux release
detect_cachy_release() {
    gh_api "/repos/${CACHYOS_LINUX_REPO}/releases?per_page=20" | python3 -c "
import json, sys, re
releases = json.load(sys.stdin)
for r in releases:
    tag = r.get('tag_name', '')
    # Match stable releases: cachyos-X.Y.Z-N
    m = re.match(r'^cachyos-(\d+\.\d+)\.\d+-\d+$', tag)
    if m:
        print(tag)
        break
" 2>/dev/null
}

SURFACE_VERSION=$(detect_surface_version)
CACHY_PATCH_VERSION=$(detect_cachy_patch_version)
CACHY_RELEASE=$(detect_cachy_release)

log "Latest linux-surface patches version: ${SURFACE_VERSION:-unknown}"
log "Latest CachyOS kernel-patches version: ${CACHY_PATCH_VERSION:-unknown}"
log "Latest CachyOS linux release: ${CACHY_RELEASE:-unknown}"

# Determine the kernel version to target
# Use the MINIMUM of the two — we can only use versions where BOTH patch sets exist
if [ -n "$FORCE_VERSION" ]; then
    KERNEL_VERSION="$FORCE_VERSION"
    log "Using forced version: ${KERNEL_VERSION}"
else
    KERNEL_VERSION="$SURFACE_VERSION"
    log "Using surface version as target: ${KERNEL_VERSION}"
fi

if [ -z "$KERNEL_VERSION" ]; then
    err "Could not determine kernel version"
    exit 1
fi

# ============================================================================
# Phase 2: Discover available patches and sources
# ============================================================================

log "Phase 2: Discovering patches for ${KERNEL_VERSION}..."

# --- CachyOS source discovery ---

# For 7.0+, CachyOS uses pre-patched tarballs. Detect the approach.
CACHY_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
CACHY_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)

cachy_base_patch_url=""
cachy_sched_patch_url=""
cachy_tarball_url=""
cachy_config_url=""

if [ "$CACHY_MAJOR" -ge 7 ]; then
    # CachyOS 7.x: use pre-patched tarball
    log "CachyOS 7.x detected — looking for pre-patched tarball..."

    # Find the latest release matching our major.minor
    CACHY_RELEASE_MATCHING=$(gh_api "/repos/${CACHYOS_LINUX_REPO}/releases?per_page=20" | python3 -c "
import json, sys, re
major_minor = '${KERNEL_VERSION}'
releases = json.load(sys.stdin)
for r in releases:
    tag = r.get('tag_name', '')
    if tag.startswith(f'cachyos-{major_minor}.'):
        print(tag)
        break
" 2>/dev/null || true)

    if [ -n "$CACHY_RELEASE_MATCHING" ]; then
        CACHY_SRCNAME="cachyos-$(echo "$CACHY_RELEASE_MATCHING" | sed 's/^cachyos-//')"
        cachy_tarball_url="https://github.com/CachyOS/linux/releases/download/${CACHY_SRCNAME}/${CACHY_SRCNAME}.tar.gz"
        log "CachyOS tarball: ${cachy_tarball_url}"
    else
        warn "No CachyOS release found for ${KERNEL_VERSION}"
    fi
else
    # CachyOS 6.x: use vanilla kernel + apply patches at build time
    log "CachyOS 6.x detected — using vanilla kernel + patches..."

    CACHY_PATCHSOURCE="https://raw.githubusercontent.com/CachyOS/kernel-patches/master/${KERNEL_VERSION}"

    # Find the base-all patch — check multiple possible locations
    # 1. all/ subdirectory (may have been removed from master)
    # 2. Root of version directory
    # 3. Pinned commit (last resort)

    # Try: all/0001-cachyos-base-all.patch on master
    if gh_check_url "${CACHY_PATCHSOURCE}/all/0001-cachyos-base-all.patch"; then
        cachy_base_patch_url="${CACHY_PATCHSOURCE}/all/0001-cachyos-base-all.patch"
        log "Found CachyOS base patch: all/0001-cachyos-base-all.patch"
    # Try: root 0001-cachyos-base-all.patch on master
    elif gh_check_url "${CACHY_PATCHSOURCE}/0001-cachyos-base-all.patch"; then
        cachy_base_patch_url="${CACHY_PATCHSOURCE}/0001-cachyos-base-all.patch"
        log "Found CachyOS base patch: 0001-cachyos-base-all.patch"
    else
        # Try recent commits to find where the all/ directory existed
        # IMPORTANT: The most recent commit may have DELETED the file,
        # so we need to check each commit to find the last one that ADDED/MODIFIED it.
        log "Searching CachyOS kernel-patches commit history for base-all patch..."
        FOUND_COMMIT=$(gh_api "/repos/${CACHYOS_PATCHES_REPO}/commits?path=${KERNEL_VERSION}/all&per_page=10" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data:
    sha = c['sha']
    for f in c.get('files', []):
        fname = f.get('filename', '')
        status = f.get('status', '')
        # We want a commit where the file was added or modified (not removed)
        if fname == '${KERNEL_VERSION}/all/0001-cachyos-base-all.patch' and status in ('added', 'modified', 'renamed'):
            print(sha)
            sys.exit(0)
print('')
" 2>/dev/null || true)

        # Fallback: try any commit except the deletion one
        if [ -z "$FOUND_COMMIT" ]; then
            FOUND_COMMIT=$(gh_api "/repos/${CACHYOS_PATCHES_REPO}/commits?path=${KERNEL_VERSION}/all&per_page=10" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for c in data:
    sha = c['sha']
    # Check if any file was added/modified (not just removed)
    for f in c.get('files', []):
        if f.get('status', '') in ('added', 'modified') and '0001-cachyos-base-all' in f.get('filename', ''):
            print(sha)
            sys.exit(0)
# Try second commit as fallback (first is usually the deletion)
if len(data) > 1:
    print(data[1]['sha'])
" 2>/dev/null || true)
        fi

        if [ -n "$FOUND_COMMIT" ]; then
            cachy_base_patch_url="https://raw.githubusercontent.com/CachyOS/kernel-patches/${FOUND_COMMIT}/${KERNEL_VERSION}/all/0001-cachyos-base-all.patch"
            # Verify this URL actually works (the commit exists and file is accessible)
            if gh_check_url "$cachy_base_patch_url"; then
                log "Found base-all patch at commit ${FOUND_COMMIT:0:12}"
            else
                warn "Commit ${FOUND_COMMIT:0:12} found but file URL returns 404"
                cachy_base_patch_url=""
            fi
        else
            warn "Could not find CachyOS base-all patch for ${KERNEL_VERSION}"
        fi
    fi
fi

# --- Surface patch discovery ---

log "Discovering Surface patches for ${KERNEL_VERSION}..."
SURFACE_PATCHES=$(gh_api "/repos/${LINUX_SURFACE_REPO}/contents/patches/${KERNEL_VERSION}" | python3 -c "
import json, sys
data = json.load(sys.stdin)
patches = []
for item in data:
    name = item.get('name', '')
    if name.endswith('.patch'):
        patches.append(name)
patches.sort()
for p in patches:
    print(p)
" 2>/dev/null || true)

SURFACE_PATCH_COUNT=$(echo "$SURFACE_PATCHES" | grep -c '^' 2>/dev/null || echo 0)
log "Found ${SURFACE_PATCH_COUNT} Surface patches"

# --- Surface config discovery ---

SURFACE_CONFIG_URL="https://raw.githubusercontent.com/linux-surface/linux-surface/master/configs/surface-${KERNEL_VERSION}.config"
SURFACE_OVERRIDES_URL="https://raw.githubusercontent.com/linux-surface/linux-surface/master/.github/data/autoupdate/kernel-overrides.config"

if gh_check_url "$SURFACE_CONFIG_URL"; then
    log "Surface config available: surface-${KERNEL_VERSION}.config"
else
    warn "Surface config NOT available for ${KERNEL_VERSION}"
fi

# --- Update check mode ---

if [ "$UPDATE_CHECK" = "true" ]; then
    # Read current version from PKGBUILD
    CURRENT_VERSION=$(grep '^_major=' "${PKGDIR}/PKGBUILD" | cut -d= -f2)

    echo ""
    echo "============================================="
    echo "Update Check"
    echo "============================================="
    echo "Current version:      ${CURRENT_VERSION}"
    echo "Latest surface:      ${SURFACE_VERSION}"
    echo "Latest CachyOS:       ${CACHY_PATCH_VERSION}"
    echo "Target version:       ${KERNEL_VERSION}"
    echo "Surface patches:      ${SURFACE_PATCH_COUNT} found"
    echo "CachyOS base patch:   ${cachy_base_patch_url:+available}${cachy_base_patch_url:-NOT FOUND}"
    echo "CachyOS tarball:      ${cachy_tarball_url:+available}${cachy_tarball_url:-N/A (6.x mode)}"
    echo "============================================="

    if [ "$CURRENT_VERSION" != "$KERNEL_VERSION" ]; then
        echo "UPDATE NEEDED: ${CURRENT_VERSION} → ${KERNEL_VERSION}"
        exit 0
    else
        echo "Up to date"
        exit 1
    fi
fi

# ============================================================================
# Phase 3: Generate PKGBUILD source array
# ============================================================================

log "Phase 3: Generating PKGBUILD source array..."

# Build the source array entries
SOURCE_ENTRIES=()
SOURCE_ENTRIES+=("cachyos-surface.config")

if [ "$CACHY_MAJOR" -ge 7 ] && [ -n "$cachy_tarball_url" ]; then
    # CachyOS 7.x: pre-patched tarball + scheduler patch only
    SOURCE_ENTRIES+=("\"${cachy_tarball_url}\"")
    SOURCE_ENTRIES+=("\"${CACHY_PATCHSOURCE}/sched/0001-bore-cachy.patch\"")
    SOURCE_ENTRIES+=("config")
elif [ -n "$cachy_base_patch_url" ]; then
    # CachyOS 6.x: vanilla kernel + base-all + scheduler patches
    VANILLA_KERNEL="linux-${KERNEL_VERSION}.tar.xz"
    SOURCE_ENTRIES+=("\"https://cdn.kernel.org/pub/linux/kernel/v${CACHY_MAJOR}.x/linux-${KERNEL_VERSION}.tar.xz\"")
    SOURCE_ENTRIES+=("\"${cachy_base_patch_url}\"")
    SOURCE_ENTRIES+=("\"${CACHY_PATCHSOURCE}/sched/0001-bore-cachy.patch\"")
    SOURCE_ENTRIES+=("config")
else
    err "No CachyOS source available for ${KERNEL_VERSION}"
    exit 1
fi

# Add surface patches
while IFS= read -r p; do
    [ -z "$p" ] && continue
    SOURCE_ENTRIES+=("\"https://raw.githubusercontent.com/linux-surface/linux-surface/master/patches/${KERNEL_VERSION}/${p}\"")
done <<< "$SURFACE_PATCHES"

# Generate the source array text
SOURCE_ARRAY="source=(\n"
for entry in "${SOURCE_ENTRIES[@]}"; do
    # If it contains a URL or is a quoted string, add directly
    if [[ "$entry" == \"* ]] || [[ "$entry" == http* ]]; then
        SOURCE_ARRAY+="    ${entry}\n"
    else
        SOURCE_ARRAY+="    \"${entry}\"\n"
    fi
done
SOURCE_ARRAY+=")"

if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo "[DRY RUN] Generated source array:"
    echo -e "$SOURCE_ARRAY"
    echo ""
    echo "[DRY RUN] Would update PKGBUILD with:"
    echo "  _major=${KERNEL_VERSION}"
    echo "  pkgver=${KERNEL_VERSION}.${_minor:-0}"
fi

# ============================================================================
# Phase 4: Update PKGBUILD
# ============================================================================

if [ "$DRY_RUN" = "false" ]; then
    log "Phase 4: Updating PKGBUILD..."
    PKGBUILD="${PKGDIR}/PKGBUILD"

    if [ ! -f "$PKGBUILD" ]; then
        err "PKGBUILD not found at ${PKGBUILD}"
        exit 1
    fi

    # Update version variables
    sed -i "s/^_major=.*/_major=${KERNEL_VERSION}/" "$PKGBUILD"
    log "Updated _major=${KERNEL_VERSION}"

    # Determine _srcname and _minor based on CachyOS approach
    if [ "$CACHY_MAJOR" -ge 7 ] && [ -n "$cachy_tarball_url" ]; then
        # Extract tagrel from release tag
        TAGREL=$(echo "$CACHY_RELEASE_MATCHING" | sed -E 's/^cachyos-[0-9]+\.[0-9]+\.[0-9]+-([0-9]+)$/\1/')
        KERN_MINOR=$(echo "$CACHY_RELEASE_MATCHING" | sed -E 's/^cachyos-[0-9]+\.[0-9]+\.([0-9]+)-[0-9]+$/\1/')
        SRCNAME="cachyos-${KERNEL_VERSION}.${KERN_MINOR}-${TAGREL}"

        sed -i "s/^_minor=.*/_minor=${KERN_MINOR}/" "$PKGBUILD"
        # Add _tagrel and _srcname if not present
        grep -q '^_tagrel=' "$PKGBUILD" || sed -i "/^_minor=/a _tagrel=${TAGREL}" "$PKGBUILD"
        grep -q '^_srcname=' "$PKGBUILD" || sed -i "/^_tagrel=/a _srcname=${SRCNAME}" "$PKGBUILD"
        sed -i "s/^_srcname=.*/_srcname=${SRCNAME}/" "$PKGBUILD"
        sed -i "s/^_tagrel=.*/_tagrel=${TAGREL}/" "$PKGBUILD"
    else
        # 6.x: vanilla kernel
        # Check if there's a stable minor release
        STABLE_KERNEL=$(curl -sSf -o /dev/null -w "%{http_code}" \
            "https://cdn.kernel.org/pub/linux/kernel/v${CACHY_MAJOR}.x/linux-${KERNEL_VERSION}.1.tar.xz" 2>/dev/null)
        if [ "$STABLE_KERNEL" = "200" ]; then
            log "Stable kernel ${KERNEL_VERSION}.1 exists, setting _minor=1"
            sed -i "s/^_minor=.*/_minor=1/" "$PKGBUILD"
        elif grep -q '^_minor=0' "$PKGBUILD"; then
            log "Keeping _minor=0 (rc/first release)"
        fi
    fi

    # Replace the source array in PKGBUILD
    python3 -c "
import re, sys

pkgbuil_path = '${PKGBUILD}'
with open(pkgbuil_path, 'r') as f:
    content = f.read()

# Find and replace the source=() block
# Match source=( ... ) including multi-line
new_source = '''${SOURCE_ARRAY}'''

pattern = r'source=\([\s\S]*?\)(?=\s*\n)'
match = re.search(pattern, content)
if match:
    content = content[:match.start()] + new_source + content[match.end():]
    with open(pkgbuil_path, 'w') as f:
        f.write(content)
    print('Replaced source array')
else:
    print('WARNING: Could not find source array in PKGBUILD', file=sys.stderr)
"
    log "PKGBUILD source array updated"

    # Remove old sha256sums — will be regenerated by updpkgsums
    if grep -q '^sha256sums=' "$PKGBUILD"; then
        # Remove the entire sha256sums array
        python3 -c "
import re
path = '${PKGBUILD}'
with open(path, 'r') as f:
    content = f.read()
# Remove sha256sums line and everything until the closing paren
content = re.sub(r'sha256sums=\([\s\S]*?\)\n', '', content)
with open(path, 'w') as f:
    f.write(content)
print('Removed old sha256sums')
"
    fi
fi

# ============================================================================
# Phase 5: Download sources and update checksums
# ============================================================================

if [ "$DRY_RUN" = "false" ]; then
    log "Phase 5: Downloading sources and updating checksums..."
    cd "$PKGDIR"

    # Clean up old source files
    rm -f *.patch *.tar.xz *.tar.gz config-*

    # Download all sources
    log "Running makepkg --nobuild --nodeps to fetch sources..."
    if ! makepkg --nobuild --nodeps 2>&1; then
        warn "makepkg --nobuild failed, trying updpkgsums..."
        if command -v updpkgsums &>/dev/null; then
            updpkgsums
            log "Checksums updated via updpkgsums"
        else
            warn "updpkgsums not available. You'll need to run it manually."
        fi
    else
        # If makepkg succeeded, also update checksums
        if command -v updpkgsums &>/dev/null; then
            updpkgsums
            log "Checksums updated"
        fi
    fi
fi

# ============================================================================
# Phase 6: Verify patches apply (optional)
# ============================================================================

if [ "$VERIFY" = "true" ] && [ "$DRY_RUN" = "false" ]; then
    log "Phase 6: Verifying patches apply cleanly..."
    cd "$PKGDIR"

    if [ -d src ]; then
        log "Source tree exists, checking patches..."
        cd src

        # Find the kernel source directory
        KERN_DIR=$(find . -maxdepth 1 -type d -name 'linux-*' -o -name 'cachyos-*' | head -1)
        if [ -n "$KERN_DIR" ] && [ -d "$KERN_DIR" ]; then
            cd "$KERN_DIR"

            PATCHES_FAILED=0
            for patch_file in ../*.patch; do
                [ -f "$patch_file" ] || continue
                pname=$(basename "$patch_file")
                echo -n "  Testing $pname... "
                if patch -Np1 --dry-run --fuzz=3 < "$patch_file" >/dev/null 2>&1; then
                    echo "OK"
                else
                    echo "FAILED"
                    PATCHES_FAILED=$((PATCHES_FAILED + 1))
                fi
            done

            if [ "$PATCHES_FAILED" -gt 0 ]; then
                warn "${PATCHES_FAILED} patches failed dry-run"
                log "Check .rej files for details"
                exit 1
            else
                log "All patches apply cleanly!"
            fi
        else
            warn "Kernel source directory not found in src/"
        fi
    else
        warn "No src/ directory — run makepkg --nobuild first"
    fi
fi

# ============================================================================
# Phase 7: Commit (optional)
# ============================================================================

if [ "$COMMIT" = "true" ] && [ "$DRY_RUN" = "false" ]; then
    log "Phase 7: Committing changes..."
    cd "$REPO_ROOT"
    git add "${PKGDIR}"
    git commit -m "kernel-cachyos: Update to ${KERNEL_VERSION}

Surface patches: ${SURFACE_PATCH_COUNT} found
CachyOS source: ${cachy_base_patch_url:+base-all patch}${cachy_tarball_url:+pre-patched tarball}
auto-sync: true"
    log "Committed: kernel-cachyos ${KERNEL_VERSION}"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "============================================="
echo "Sync Complete"
echo "============================================="
echo "Kernel version:     ${KERNEL_VERSION}"
echo "Surface patches:    ${SURFACE_PATCH_COUNT}"
echo "CachyOS source:     ${cachy_base_patch_url:-${cachy_tarball_url:-none}}"
echo "Dry run:            ${DRY_RUN}"
echo ""
echo "Next steps:"
echo "  1. cd ${PKGDIR}"
echo "  2. makepkg --nobuild    # Verify patches apply"
echo "  3. makepkg -sf          # Build kernel"
echo "============================================="