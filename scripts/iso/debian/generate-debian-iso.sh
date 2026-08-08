#!/usr/bin/env bash
#
# generate-debian-iso.sh
#
# Downloads Debian 13 ISO, injects preseed.cfg and recipes/,
# and generates an automated bootable ISO image.
#

set -Eeuo pipefail

# --- Logging & Diagnostics ---
log_info()  { printf "[+] %s\n" "$*" >&2; }
log_warn()  { printf "[!] WARNING: %s\n" "$*" >&2; }
log_error() { printf "[E] ERROR: %s\n" "$*" >&2; }

on_error() {
    log_error "Command failed at line $1: '$2'"
    exit 1
}
trap 'on_error ${LINENO} "$BASH_COMMAND"' ERR

# --- Configuration & Constants ---
readonly DEFAULT_ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-13.6.0-amd64-netinst.iso"
readonly ISO_URL="${DEBIAN_ISO_URL:-$DEFAULT_ISO_URL}"
readonly OUTPUT_NAME="debian-13-preseed-auto.iso"

usage() {
    cat <<EOF >&2
Usage: $0 <config-directory> [output-directory] [iso-path]

Arguments:
  config-directory  Directory containing preseed.cfg and recipes/
  output-directory  Optional output directory (defaults to current directory)
  iso-path          Optional path to existing Debian installation ISO

Environment Variables:
  DEBIAN_ISO_URL    Override default Debian ISO download URL
EOF
    exit 1
}

# --- Dependency Verification ---
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "Missing required dependency: $1"
        exit 1
    }
}

for cmd in wget xorriso rsync sha256sum; do
    require_cmd "$cmd"
done

# --- Argument Parsing & Validation ---
if [[ $# -lt 1 || $# -gt 3 ]]; then
    usage
fi

CONFIG_DIR="$(realpath "$1")"

if [[ $# -ge 2 ]]; then
    OUTPUT_DIR="$(realpath -m "$2")"
else
    OUTPUT_DIR="$PWD"
fi

mkdir -p "$OUTPUT_DIR"
readonly OUTPUT_ISO="$OUTPUT_DIR/$OUTPUT_NAME"

if [[ ! -f "$CONFIG_DIR/preseed.cfg" ]]; then
    log_error "Preseed file not found: $CONFIG_DIR/preseed.cfg"
    exit 1
fi

if [[ ! -d "$CONFIG_DIR/recipes" ]]; then
    log_error "Recipes directory not found: $CONFIG_DIR/recipes/"
    exit 1
fi

# --- Workspace Management ---
WORKDIR="$(mktemp -d -t debian-iso.XXXXXX)"

cleanup() {
    if [[ -d "${WORKDIR:-}" ]]; then
        chmod -R u+w "$WORKDIR" 2>/dev/null || true
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

readonly ISO="$WORKDIR/debian.iso"
readonly ISO_ROOT="$WORKDIR/iso"

mkdir -p "$ISO_ROOT"

# --- ISO Acquisition & Verification ---
if [[ $# -eq 3 ]]; then
    SOURCE_ISO="$(realpath "$3")"

    if [[ ! -f "$SOURCE_ISO" ]]; then
        log_error "Provided ISO path does not exist: $SOURCE_ISO"
        exit 1
    fi

    log_info "Using provided ISO:"
    log_info "    $SOURCE_ISO"

    ln -s "$SOURCE_ISO" "$ISO"
else
    log_info "Downloading Debian 13 ISO..."
    wget \
        --progress=bar:force \
        -O "$ISO" \
        "$ISO_URL"

    SHA256_URL="$(dirname "$ISO_URL")/SHA256SUMS"
    ISO_FILENAME="$(basename "$ISO_URL")"

    log_info "Verifying ISO checksum..."
    if wget -q -O "$WORKDIR/SHA256SUMS" "$SHA256_URL" 2>/dev/null; then
        EXPECTED="$(grep "$ISO_FILENAME" "$WORKDIR/SHA256SUMS" 2>/dev/null | head -1 | awk '{print $1}' || true)"
        if [[ -n "$EXPECTED" ]]; then
            ACTUAL="$(sha256sum "$ISO" | awk '{print $1}')"
            if [[ "$EXPECTED" != "$ACTUAL" ]]; then
                log_error "SHA256 checksum mismatch!"
                log_error "  Expected: $EXPECTED"
                log_error "  Actual:   $ACTUAL"
                exit 1
            fi
            log_info "    Checksum OK ($ACTUAL)"
        else
            log_warn "ISO filename not found in SHA256SUMS, skipping verification"
        fi
    else
        log_warn "Could not download SHA256SUMS file, skipping verification"
    fi
fi

# --- ISO Extraction & Preseed Injection ---
log_info "Extracting MBR boot code for hybrid ISO compatibility..."
dd if="$ISO" bs=1 count=432 of="$WORKDIR/isohdpfx.bin" 2>/dev/null

log_info "Extracting source ISO..."
xorriso \
    -osirrox on \
    -indev "$ISO" \
    -extract / "$ISO_ROOT"

log_info "Fixing extracted permissions..."
chmod -R u+w "$ISO_ROOT"

log_info "Copying preseed configuration..."
cp "$CONFIG_DIR/preseed.cfg" "$ISO_ROOT/preseed.cfg"

log_info "Copying partitioning recipes..."
mkdir -p "$ISO_ROOT/recipes"
rsync -a "$CONFIG_DIR/recipes/" "$ISO_ROOT/recipes/"

# --- Bootloader Configuration ---
log_info "Injecting preseed into BIOS boot entry..."
if [[ -f "$ISO_ROOT/isolinux/txt.cfg" ]]; then
    sed -i \
        's#---#auto=true priority=critical file=/cdrom/preseed.cfg ---#' \
        "$ISO_ROOT/isolinux/txt.cfg"

    if ! grep -q "file=/cdrom/preseed.cfg" "$ISO_ROOT/isolinux/txt.cfg"; then
        log_warn "Could not verify preseed parameter injection in isolinux/txt.cfg"
    fi
fi

log_info "Injecting preseed into UEFI boot entry..."
if [[ -f "$ISO_ROOT/boot/grub/grub.cfg" ]]; then
    sed -i \
        's#---#auto=true priority=critical file=/cdrom/preseed.cfg ---#g' \
        "$ISO_ROOT/boot/grub/grub.cfg"

    if ! grep -q "file=/cdrom/preseed.cfg" "$ISO_ROOT/boot/grub/grub.cfg"; then
        log_warn "Could not verify preseed parameter injection in boot/grub/grub.cfg"
    fi
fi

# --- Image Generation ---
log_info "Building target ISO image..."
xorriso \
    -as mkisofs \
    -iso-level 3 \
    -o "$OUTPUT_ISO" \
    -full-iso9660-filenames \
    -volid "DEBIAN_PRESEED" \
    -isohybrid-mbr "$WORKDIR/isohdpfx.bin" \
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

log_info "Successfully generated ISO:"
log_info "    $OUTPUT_ISO"
