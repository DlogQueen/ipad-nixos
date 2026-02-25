#!/usr/bin/env bash
# extract-firmware.sh — Extract WiFi/BT/Touch firmware from iPad IPSW
#
# iPad Air 2 (iPad5,3 / iPad5,4) firmware blobs needed for Linux:
#   - WiFi:  BCM4354 → brcmfmac driver (brcmfmac4354-sdio.*)
#   - BT:   BCM4354 → btbcm driver
#   - Touch: BCM5976 → apple_z2 driver (Z2 protocol over SPI)
#
# IPSW files are ZIP archives containing:
#   - BuildManifest.plist
#   - kernelcache.*
#   - One or more .dmg files (the largest is the root filesystem)
#   - Firmware/ directory with some standalone firmware
#
# The root filesystem DMG contains firmware under:
#   /usr/share/firmware/wifi/    — WiFi/BT firmware blobs
#   /usr/share/firmware/         — other firmware
#
# For iOS 16+ the root filesystem is a "cryptex" and may need
# additional steps. iPad Air 2 maxes out at iPadOS 16.7.x.
#
# Download IPSW from: https://ipsw.me/iPad5,3
#
# Usage: ./extract-firmware.sh <path-to-ipsw> [output-dir]
# Example: ./extract-firmware.sh iPad_64bit_TouchID_16.7.10_20H350_Restore.ipsw ./firmware

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <ipsw-file> [output-dir]"
    echo ""
    echo "Download IPSW for iPad Air 2 (WiFi) from:"
    echo "  https://ipsw.me/iPad5,3"
    echo ""
    echo "Download IPSW for iPad Air 2 (Cellular) from:"
    echo "  https://ipsw.me/iPad5,4"
    exit 1
fi

IPSW="$1"
OUTPUT="${2:-./firmware}"
WORKDIR="$(mktemp -d)"

cleanup() {
    echo "Cleaning up..."
    # Unmount if still mounted
    if mountpoint -q "$WORKDIR/rootfs" 2>/dev/null; then
        sudo umount "$WORKDIR/rootfs" 2>/dev/null || true
    fi
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "iPad NixOS — Firmware Extraction"
echo "================================="
echo "IPSW:   $IPSW"
echo "Output: $OUTPUT"
echo ""

# Check dependencies
for cmd in unzip dmg2img; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Missing tool: $cmd"
        echo "  Install with: nix-shell -p $cmd"
        exit 1
    fi
done

mkdir -p "$OUTPUT" "$WORKDIR/ipsw" "$WORKDIR/rootfs"

# Step 1: Extract IPSW (it's a ZIP)
echo "==> Step 1: Extracting IPSW..."
unzip -o "$IPSW" -d "$WORKDIR/ipsw"

# Step 2: Find the largest DMG (root filesystem)
echo ""
echo "==> Step 2: Finding root filesystem DMG..."
ROOTFS_DMG=$(find "$WORKDIR/ipsw" -name "*.dmg" -printf '%s %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
echo "    Root filesystem: $(basename "$ROOTFS_DMG")"
echo "    Size: $(du -h "$ROOTFS_DMG" | cut -f1)"

# Step 3: Convert DMG to raw image
echo ""
echo "==> Step 3: Converting DMG to raw image..."
RAW_IMG="$WORKDIR/rootfs.img"
dmg2img "$ROOTFS_DMG" "$RAW_IMG"

# Step 4: Mount the filesystem
echo ""
echo "==> Step 4: Mounting root filesystem (requires sudo)..."
sudo mount -o ro,loop "$RAW_IMG" "$WORKDIR/rootfs"

# Step 5: Extract firmware files
echo ""
echo "==> Step 5: Extracting firmware..."

# WiFi / Bluetooth firmware
WIFI_SRC="$WORKDIR/rootfs/usr/share/firmware/wifi"
if [[ -d "$WIFI_SRC" ]]; then
    echo "  Found WiFi firmware directory"
    mkdir -p "$OUTPUT/brcm"

    # Copy all Broadcom firmware files
    # brcmfmac expects files named like: brcmfmac4354-sdio.bin, .clm_blob, .txt
    for f in "$WIFI_SRC"/*; do
        if [[ -f "$f" ]]; then
            cp "$f" "$OUTPUT/brcm/"
            echo "    Copied: $(basename "$f")"
        fi
    done
else
    echo "  WARNING: No WiFi firmware found at /usr/share/firmware/wifi/"
    echo "  Trying alternative paths..."

    # Try Firmware/ directory in IPSW root
    for alt in "$WORKDIR/ipsw/Firmware" "$WORKDIR/rootfs/usr/share/firmware"; do
        if [[ -d "$alt" ]]; then
            echo "  Found: $alt"
            find "$alt" -type f -name "*BCM*" -o -name "*bcm*" -o -name "*4354*" | while read -r f; do
                cp "$f" "$OUTPUT/brcm/" 2>/dev/null || true
                echo "    Copied: $(basename "$f")"
            done
        fi
    done
fi

# Touch firmware (BCM5976 / Z2 protocol)
echo ""
echo "  Looking for touch firmware..."
TOUCH_PATHS=(
    "$WORKDIR/rootfs/usr/share/firmware/multitouch"
    "$WORKDIR/rootfs/usr/share/firmware"
    "$WORKDIR/rootfs/usr/lib/firmware"
)

mkdir -p "$OUTPUT/apple"
TOUCH_FOUND=false
for tp in "${TOUCH_PATHS[@]}"; do
    if [[ -d "$tp" ]]; then
        find "$tp" -type f \( -name "*5976*" -o -name "*touch*" -o -name "*z2*" -o -name "*multi*" \) 2>/dev/null | while read -r f; do
            cp "$f" "$OUTPUT/apple/"
            echo "    Copied: $(basename "$f")"
            TOUCH_FOUND=true
        done
    fi
done

if [[ "$TOUCH_FOUND" != "true" ]]; then
    echo "  NOTE: Touch firmware may be embedded in the kernel/driver, not a separate file."
    echo "  The apple_z2 mainline driver may handle calibration data differently."
fi

# Step 6: Also grab any standalone firmware from IPSW Firmware/ dir
echo ""
echo "==> Step 6: Checking IPSW Firmware/ directory..."
if [[ -d "$WORKDIR/ipsw/Firmware" ]]; then
    find "$WORKDIR/ipsw/Firmware" -type f | head -20 | while read -r f; do
        echo "    Found: ${f#$WORKDIR/ipsw/}"
    done
fi

# Unmount
echo ""
echo "==> Unmounting..."
sudo umount "$WORKDIR/rootfs"

# Summary
echo ""
echo "================================="
echo "Extraction complete!"
echo ""
echo "Firmware files in: $OUTPUT"
find "$OUTPUT" -type f -printf "  %p (%s bytes)\n" 2>/dev/null || true
echo ""
echo "To install for Linux:"
echo "  WiFi:  copy $OUTPUT/brcm/* to /lib/firmware/brcm/ on the initramfs"
echo "  Touch: copy $OUTPUT/apple/* to /lib/firmware/apple/ on the initramfs"
echo ""
echo "Note: brcmfmac expects specific filenames. You may need to rename files:"
echo "  brcmfmac4354-sdio.bin          — main firmware"
echo "  brcmfmac4354-sdio.clm_blob     — CLM (country locale) blob"
echo "  brcmfmac4354-sdio.txt          — NVRAM config (board-specific)"
