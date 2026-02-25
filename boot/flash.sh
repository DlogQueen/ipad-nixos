#!/usr/bin/env bash
# flash.sh — Boot Linux on iPad Air 2 (A8X / T7001) via checkm8
#
# Prerequisites:
#   - iPad connected via USB Lightning cable
#   - iPad in DFU mode (hold Home + Power, release Power after 3s, hold Home 10s)
#   - Run as root (sudo) for USB access
#
# The device must be re-flashed on every boot (checkm8 is tethered).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Paths to boot artifacts (override with environment variables)
GASTER="${GASTER:-gaster}"
LOAD_LINUX="${LOAD_LINUX:-$SCRIPT_DIR/load_linux.py}"
PONGO_BIN="${PONGO_BIN:-$SCRIPT_DIR/Pongo.bin}"
KERNEL="${KERNEL:-$PROJECT_DIR/result/Image.lzma}"
DTBPACK="${DTBPACK:-$SCRIPT_DIR/dtbpack}"
INITRAMFS="${INITRAMFS:-$PROJECT_DIR/result-initramfs/initrd}"
CMDLINE="${CMDLINE:-console=tty0 earlycon loglevel=7 root=/dev/ram0}"

echo "iPad NixOS — Boot Script"
echo "========================"
echo ""
echo "Kernel:    $KERNEL"
echo "DTBpack:   $DTBPACK"
echo "Initramfs: $INITRAMFS"
echo "PongoOS:   $PONGO_BIN"
echo ""

# Verify all files exist
for f in "$PONGO_BIN" "$KERNEL" "$DTBPACK" "$LOAD_LINUX"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: Missing file: $f"
        exit 1
    fi
done

# Initramfs is optional but recommended
if [[ ! -f "$INITRAMFS" ]]; then
    echo "WARNING: No initramfs found at $INITRAMFS"
    echo "         Boot will likely panic with 'unable to mount root fs'"
    INITRAMFS_ARGS=""
else
    INITRAMFS_ARGS="-r $INITRAMFS"
fi

echo "==> Step 1: Running checkm8 exploit (device must be in DFU mode)..."
$GASTER pwn
echo "    checkm8 exploit successful"

echo ""
echo "==> Step 2: Loading pongoOS..."
irecovery -f "$PONGO_BIN"
echo "    pongoOS loaded"

echo ""
echo "==> Step 3: Waiting for pongoOS USB device (05ac:4141)..."
for i in $(seq 1 30); do
    if lsusb | grep -q "05ac:4141"; then
        echo "    pongoOS USB device detected"
        break
    fi
    if [[ $i -eq 30 ]]; then
        echo "ERROR: pongoOS USB device not detected after 30 seconds"
        exit 1
    fi
    sleep 1
done

echo ""
echo "==> Step 4: Uploading kernel, device tree, and initramfs..."
python3 "$LOAD_LINUX" \
    -k "$KERNEL" \
    -d "$DTBPACK" \
    $INITRAMFS_ARGS \
    -c "$CMDLINE"

echo ""
echo "==> Boot initiated!"
echo "    The iPad should now show Linux boot output on its display."
echo "    If using USB gadget Ethernet, wait ~10s then check for a new"
echo "    network interface on this host (usb0 or enp*s*)."
echo ""
echo "    To connect via SSH (once USB Ethernet is working):"
echo "      ssh root@172.16.42.1"
