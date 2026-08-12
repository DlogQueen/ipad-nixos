#!/usr/bin/env bash
# flash-ipad.sh — Select and flash iPad Linux bundle
# Use after downloading GH Actions artifact
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "iPad NixOS Flash Helper"
echo "======================="
echo ""

# Check prerequisites
for cmd in gaster irecovery python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd not found. Install it first."
    exit 1
  fi
done

echo "Which iPad?"
echo "  1) iPad 5th gen (A1822, A9) — dtbpack-a1822"
echo "  2) iPad Air 1 (A1458, A7)  — dtbpack-a1458"
read -p "Select [1/2]: " choice

case "$choice" in
  1) DTB="$SCRIPT_DIR/dtbpack-a1822" ;;
  2) DTB="$SCRIPT_DIR/dtbpack-a1458" ;;
  *) echo "Invalid choice"; exit 1 ;;
esac

if [ ! -f "$DTB" ]; then
  echo "ERROR: $DTB not found"
  ls -la "$SCRIPT_DIR"/dtbpack-* 2>/dev/null
  exit 1
fi

echo ""
echo "==> Put iPad in DFU mode (screen must be BLACK)"
echo "    Hold Power + Home 10s, release Power, hold Home 10s"
read -p "    Press Enter when ready..."
echo ""

echo "==> Step 1: checkm8 exploit"
sudo gaster pwn || { echo "FAILED"; exit 1; }

echo "==> Step 2: Load pongoOS"
sudo irecovery -f "$SCRIPT_DIR/Pongo.bin" || { echo "FAILED"; exit 1; }

echo "==> Step 3: Wait for pongoOS USB..."
sleep 3

echo "==> Step 4: Upload kernel + dtb + initramfs"
sudo python3 "$SCRIPT_DIR/load_linux.py" \
  -k "$SCRIPT_DIR/Image.lzma" \
  -d "$DTB" \
  -r "$SCRIPT_DIR/initrd" \
  -c "console=tty0 earlycon loglevel=7 root=/dev/ram0"

echo ""
echo "==> Boot initiated! Check iPad display."
echo "    USB Ethernet: ssh root@172.16.42.1"