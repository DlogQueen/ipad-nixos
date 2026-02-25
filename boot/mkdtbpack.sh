#!/usr/bin/env bash
# mkdtbpack.sh — Create a dtbpack file for pongoOS from device tree blobs
#
# pongoOS expects DTBs in a custom "dtbpack" container format:
#   [4 bytes]  magic: "Cows"
#   For each DTB:
#     [N bytes]  board ID string, null-terminated (e.g., "J81")
#     [4 bytes]  DTB size in big-endian binary
#     [M bytes]  raw DTB data
#   [5 bytes]  terminator: \0\0\0\0\0
#
# Usage: ./mkdtbpack.sh <output> <board_id:dtb_path> [board_id:dtb_path ...]
# Example: ./mkdtbpack.sh dtbpack J81:apple/t7001-j81.dtb J82:apple/t7001-j82.dtb

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <output_file> <BOARD_ID:dtb_path> [BOARD_ID:dtb_path ...]"
    echo ""
    echo "iPad Air 2 example:"
    echo "  $0 dtbpack J81:arch/arm64/boot/dts/apple/t7001-j81.dtb"
    exit 1
fi

OUTPUT="$1"
shift

# Write magic header
printf 'Cows' > "$OUTPUT"

for entry in "$@"; do
    BOARD_ID="${entry%%:*}"
    DTB_PATH="${entry#*:}"

    if [[ ! -f "$DTB_PATH" ]]; then
        echo "ERROR: DTB file not found: $DTB_PATH"
        exit 1
    fi

    SIZE=$(stat -c'%s' "$DTB_PATH")
    echo "  Adding $BOARD_ID ($DTB_PATH, $SIZE bytes)"

    # Board ID (null-terminated string)
    printf '%s\0' "$BOARD_ID" >> "$OUTPUT"

    # DTB size (4 bytes, big-endian)
    # Use printf with octal escapes instead of xxd for portability
    printf "\\x$(printf '%08x' "$SIZE" | cut -c1-2)\\x$(printf '%08x' "$SIZE" | cut -c3-4)\\x$(printf '%08x' "$SIZE" | cut -c5-6)\\x$(printf '%08x' "$SIZE" | cut -c7-8)" >> "$OUTPUT"

    # DTB data
    cat "$DTB_PATH" >> "$OUTPUT"
done

# Terminator
printf '\0\0\0\0\0' >> "$OUTPUT"

echo "Created $OUTPUT ($(stat -c'%s' "$OUTPUT") bytes)"
