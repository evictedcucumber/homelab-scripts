#!/usr/bin/env bash
#
# build-debian13-preseed-iso.sh
#
# Downloads Debian 13 ISO, injects preseed.cfg and recipes/,
# and creates a new bootable ISO.
#

set -Eeuo pipefail

trap 'echo "ERROR: line $LINENO failed"; exit 1' ERR

ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.6.0-amd64-netinst.iso"
OUTPUT_NAME="debian-13-preseed-auto.iso"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing dependency: $1"
        exit 1
    }
}

for cmd in wget xorriso rsync isoinfo; do
    require_cmd "$cmd"
done

if [[ $# -lt 1 || $# -gt 3 ]]; then
    echo "Usage: $0 <config-directory> [output-directory] [iso-path]"
    echo
    echo "Arguments:"
    echo "  config-directory  Directory containing:"
    echo "                    - preseed.cfg"
    echo "                    - recipes/"
    echo "  output-directory  Optional output directory (defaults to pwd)"
    echo "  iso-path          Optional existing Debian ISO"
    exit 1
fi

CONFIG_DIR="$(realpath "$1")"

if [[ $# -ge 2 ]]; then
    OUTPUT_DIR="$(realpath -m "$2")"
else
    OUTPUT_DIR="$PWD"
fi

mkdir -p "$OUTPUT_DIR"

OUTPUT_ISO="$OUTPUT_DIR/$OUTPUT_NAME"

if [[ ! -f "$CONFIG_DIR/preseed.cfg" ]]; then
    echo "Missing: $CONFIG_DIR/preseed.cfg"
    exit 1
fi

if [[ ! -d "$CONFIG_DIR/recipes" ]]; then
    echo "Missing: $CONFIG_DIR/recipes/"
    exit 1
fi

WORKDIR="$(mktemp -d)"

cleanup() {
    if [[ -d "${WORKDIR:-}" ]]; then
        chmod -R u+w "$WORKDIR" 2>/dev/null || true
        rm -rf "$WORKDIR"
    fi
}

trap cleanup EXIT

ISO="$WORKDIR/debian.iso"
ISO_ROOT="$WORKDIR/iso"

mkdir -p "$ISO_ROOT"

if [[ $# -eq 3 ]]; then
    SOURCE_ISO="$(realpath "$3")"

    if [[ ! -f "$SOURCE_ISO" ]]; then
        echo "ISO does not exist: $SOURCE_ISO"
        exit 1
    fi

    echo "[+] Using provided ISO:"
    echo "    $SOURCE_ISO"

    cp "$SOURCE_ISO" "$ISO"
else
    echo "[+] Downloading Debian 13 ISO..."
    wget \
        --progress=bar:force \
        -O "$ISO" \
        "$ISO_URL"
fi

echo "[+] Extracting ISO..."
xorriso \
    -osirrox on \
    -indev "$ISO" \
    -extract / "$ISO_ROOT"

echo "[+] Fixing extracted permissions..."
chmod -R u+w "$ISO_ROOT"

echo "[+] Copying preseed.cfg..."
cp \
    "$CONFIG_DIR/preseed.cfg" \
    "$ISO_ROOT/preseed.cfg"

echo "[+] Copying recipes directory..."
mkdir -p "$ISO_ROOT/recipes"

rsync -a \
    "$CONFIG_DIR/recipes/" \
    "$ISO_ROOT/recipes/"

echo "[+] Updating BIOS installer boot entry..."

if [[ -f "$ISO_ROOT/isolinux/txt.cfg" ]]; then
    sed -i \
        's#---#auto=true priority=critical file=/cdrom/preseed.cfg ---#' \
        "$ISO_ROOT/isolinux/txt.cfg"
fi

echo "[+] Updating UEFI installer boot entry..."

if [[ -f "$ISO_ROOT/boot/grub/grub.cfg" ]]; then
    sed -i \
        's#---#auto=true priority=critical file=/cdrom/preseed.cfg ---#g' \
        "$ISO_ROOT/boot/grub/grub.cfg"
fi


echo "[+] Building ISO..."

xorriso \
    -as mkisofs \
    -iso-level 3 \
    -o "$OUTPUT_ISO" \
    -full-iso9660-filenames \
    -volid "DEBIAN_PRESEED" \
    -eltorito-boot isolinux/isolinux.bin \
        -eltorito-catalog isolinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
    -eltorito-alt-boot \
    -e boot/grub/efi.img \
        -no-emul-boot \
    -isohybrid-gpt-basdat \
    "$ISO_ROOT"

echo
echo "[+] Done:"
echo "    $PWD/$OUTPUT_ISO"
