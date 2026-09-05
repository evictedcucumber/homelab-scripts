#!/usr/bin/env bash
#
# generate-debian-iso.sh
#
# Downloads the *current* Debian amd64 netinst ISO (verified against the
# published SHA256SUMS, optionally OpenPGP-verified), injects preseed.cfg
# and recipes/ from a config directory, and writes an unattended-install
# ISO.
#
# The source image's own BIOS + UEFI boot equipment is carried across
# verbatim with `xorriso -boot_image any replay`, so this keeps working
# across Debian point releases without hand-maintaining El Torito offsets
# or isohybrid MBRs.
#

set -Eeuo pipefail

# --- Logging & Diagnostics ---
log_info() { printf '[+] %s\n' "$*" >&2; }
log_warn() { printf '[!] WARNING: %s\n' "$*" >&2; }
log_error() { printf '[E] ERROR: %s\n' "$*" >&2; }

on_error() {
    log_error "Command failed at line $1: '$2'"
    exit 1
}
trap 'on_error ${LINENO} "$BASH_COMMAND"' ERR

# --- Configuration & Constants ---
# Directory that holds the "current" netinst image, SHA256SUMS and .sign.
readonly ISO_BASE_URL="${DEBIAN_ISO_BASE_URL:-https://cdimage.debian.org/debian-cd/current/amd64/iso-cd}"
readonly OUTPUT_NAME="${DEBIAN_OUTPUT_NAME:-debian-preseed-auto.iso}"
readonly CACHE_DIR="${DEBIAN_ISO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/generate-debian-iso}"
# Kernel command-line snippet that triggers the unattended install.
readonly PRESEED_ARGS='auto=true priority=critical file=/cdrom/preseed.cfg'
# Debian CD signing key (see https://www.debian.org/CD/verify).
readonly DEBIAN_CD_SIGNING_KEY='DF9B9C49EAA9298432589D76DA87E80D6294BE9B'
readonly REQUIRE_GPG="${REQUIRE_GPG:-0}"
readonly SKIP_GPG="${SKIP_GPG:-0}"

usage() {
    cat <<EOF >&2
Usage: $0 <config-directory> [output-directory] [iso-path]

Arguments:
  config-directory  Directory containing preseed.cfg and recipes/
  output-directory  Where to write ${OUTPUT_NAME} (default: current directory).
                    Must be given explicitly when passing iso-path.
  iso-path          Use this local Debian netinst ISO instead of downloading.

Environment:
  DEBIAN_ISO_BASE_URL    Override the ISO directory URL
                         (default: ${ISO_BASE_URL})
  DEBIAN_ISO_CACHE       ISO download cache directory
                         (default: ${CACHE_DIR})
  DEBIAN_OUTPUT_NAME     Output ISO filename (default: ${OUTPUT_NAME})
  REQUIRE_GPG=1          Fail unless SHA256SUMS is OpenPGP-verified
  SKIP_GPG=1             Skip OpenPGP verification of SHA256SUMS
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

for cmd in wget xorriso sha256sum awk sed grep mktemp realpath dirname basename; do
    require_cmd "$cmd"
done

# --- Argument Parsing & Validation ---
if [[ $# -lt 1 || $# -gt 3 ]]; then
    usage
fi

CONFIG_DIR="$(realpath -- "$1")"
if [[ ! -d "$CONFIG_DIR" ]]; then
    log_error "Config directory not found: $CONFIG_DIR"
    exit 1
fi

if [[ $# -ge 2 ]]; then
    OUTPUT_DIR="$(realpath -m -- "$2")"
else
    OUTPUT_DIR="$PWD"
fi

LOCAL_ISO=""
if [[ $# -eq 3 ]]; then
    LOCAL_ISO="$(realpath -- "$3")"
    if [[ ! -f "$LOCAL_ISO" ]]; then
        log_error "Provided ISO path does not exist: $LOCAL_ISO"
        exit 1
    fi
fi

mkdir -p "$OUTPUT_DIR"
readonly OUTPUT_ISO="$OUTPUT_DIR/$OUTPUT_NAME"

readonly PRESEED_SRC="$CONFIG_DIR/preseed.cfg"
readonly RECIPES_SRC="$CONFIG_DIR/recipes"

if [[ ! -f "$PRESEED_SRC" ]]; then
    log_error "Preseed file not found: $PRESEED_SRC"
    exit 1
fi

if [[ ! -d "$RECIPES_SRC" ]]; then
    log_error "Recipes directory not found: $RECIPES_SRC/"
    exit 1
fi

# --- Workspace Management ---
WORKDIR="$(mktemp -d -t debian-iso.XXXXXX)"
cleanup() {
    if [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]]; then
        rm -rf "$WORKDIR"
    fi
}
trap cleanup EXIT

sha_of() { sha256sum -- "$1" | awk '{print $1}'; }

# --- Checksum manifest + optional OpenPGP verification ---
verify_gpg() {
    local sums="$1" sig="$2" out
    if [[ "$SKIP_GPG" == "1" ]]; then
        log_warn "SKIP_GPG=1 -- not verifying the OpenPGP signature of SHA256SUMS."
        return 0
    fi
    if ! command -v gpg >/dev/null 2>&1; then
        if [[ "$REQUIRE_GPG" == "1" ]]; then
            log_error "REQUIRE_GPG=1 but 'gpg' is not installed."
            exit 1
        fi
        log_warn "gpg not installed -- skipping OpenPGP verification (REQUIRE_GPG=1 to enforce)."
        return 0
    fi
    if out="$(gpg --status-fd 1 --verify "$sig" "$sums" 2>/dev/null)" &&
        grep -q '^\[GNUPG:\] VALIDSIG' <<<"$out"; then
        log_info "    OpenPGP signature OK."
        return 0
    fi
    if grep -q '^\[GNUPG:\] \(NO_PUBKEY\|ERRSIG\)' <<<"${out:-}"; then
        local msg="Debian CD signing key not in keyring -- cannot verify SHA256SUMS.sign."
        if [[ "$REQUIRE_GPG" == "1" ]]; then
            log_error "$msg"
            log_error "Import it with:  gpg --keyserver keyserver.ubuntu.com --recv-keys ${DEBIAN_CD_SIGNING_KEY}"
            exit 1
        fi
        log_warn "$msg"
        log_warn "Import it with:  gpg --keyserver keyserver.ubuntu.com --recv-keys ${DEBIAN_CD_SIGNING_KEY}"
        return 0
    fi
    log_error "OpenPGP verification of SHA256SUMS FAILED."
    exit 1
}

log_info "Fetching checksum manifest..."
wget -q -O "$WORKDIR/SHA256SUMS" "$ISO_BASE_URL/SHA256SUMS"

if wget -q -O "$WORKDIR/SHA256SUMS.sign" "$ISO_BASE_URL/SHA256SUMS.sign" 2>/dev/null; then
    verify_gpg "$WORKDIR/SHA256SUMS" "$WORKDIR/SHA256SUMS.sign"
elif [[ "$REQUIRE_GPG" == "1" ]]; then
    log_error "REQUIRE_GPG=1 but SHA256SUMS.sign could not be downloaded."
    exit 1
else
    log_warn "Could not download SHA256SUMS.sign -- skipping OpenPGP verification."
fi

# Resolve the netinst filename from the manifest so a new point release
# never leaves us pointing at a 404. Exclude the "debian-mac-*" variant.
ISO_FILENAME="$(awk '$2 ~ /^debian-[0-9].*-amd64-netinst\.iso$/ { print $2; exit }' "$WORKDIR/SHA256SUMS")"
if [[ -z "$ISO_FILENAME" ]]; then
    log_error "No debian-<version>-amd64-netinst.iso entry found in $ISO_BASE_URL/SHA256SUMS"
    exit 1
fi
EXPECTED_SHA="$(awk -v f="$ISO_FILENAME" '$2 == f { print $1; exit }' "$WORKDIR/SHA256SUMS")"
if [[ -z "$EXPECTED_SHA" ]]; then
    log_error "No checksum for $ISO_FILENAME in SHA256SUMS"
    exit 1
fi

# --- ISO Acquisition & Verification ---
if [[ -n "$LOCAL_ISO" ]]; then
    SOURCE_ISO="$LOCAL_ISO"
    log_info "Using provided ISO: $SOURCE_ISO"
    if [[ "$(basename -- "$SOURCE_ISO")" == "$ISO_FILENAME" ]]; then
        log_info "Verifying provided ISO against SHA256SUMS..."
        actual="$(sha_of "$SOURCE_ISO")"
        if [[ "$actual" != "$EXPECTED_SHA" ]]; then
            log_error "SHA256 mismatch for $SOURCE_ISO"
            log_error "  expected: $EXPECTED_SHA"
            log_error "  actual:   $actual"
            exit 1
        fi
        log_info "    Checksum OK."
    else
        log_warn "Provided ISO name != current release ($ISO_FILENAME); cannot verify checksum."
    fi
else
    mkdir -p "$CACHE_DIR"
    SOURCE_ISO="$CACHE_DIR/$ISO_FILENAME"
    if [[ -f "$SOURCE_ISO" ]] && [[ "$(sha_of "$SOURCE_ISO")" == "$EXPECTED_SHA" ]]; then
        log_info "Using cached ISO: $SOURCE_ISO"
    else
        if [[ -f "$SOURCE_ISO" ]]; then
            log_warn "Cached ISO is stale or corrupt; re-downloading."
        fi
        log_info "Downloading $ISO_FILENAME ..."
        wget --continue --tries=3 --timeout=30 --progress=bar:force \
            -O "$SOURCE_ISO.part" "$ISO_BASE_URL/$ISO_FILENAME"
        mv "$SOURCE_ISO.part" "$SOURCE_ISO"
        log_info "Verifying download..."
        actual="$(sha_of "$SOURCE_ISO")"
        if [[ "$actual" != "$EXPECTED_SHA" ]]; then
            rm -f -- "$SOURCE_ISO"
            log_error "SHA256 mismatch for downloaded $ISO_FILENAME"
            log_error "  expected: $EXPECTED_SHA"
            log_error "  actual:   $actual"
            exit 1
        fi
        log_info "    Checksum OK ($actual)"
    fi
fi

# --- Bootloader Menu Patching ---
# Enumerate every *.cfg on the image and patch the ones carrying a kernel
# command line (marked by the "---" separator) so every menu entry, on both
# BIOS (isolinux) and UEFI (grub), preseeds automatically.
log_info "Locating bootloader menu files..."
# Well-known locations, always tried, plus whatever `xorriso -find` reports so
# a renamed/added menu file in a future release is still covered.
ISO_CFGS=(
    /isolinux/txt.cfg /isolinux/gtk.cfg /isolinux/adtxt.cfg
    /isolinux/adgtk.cfg /boot/grub/grub.cfg /boot/grub/loopback.cfg
)
mapfile -t -O "${#ISO_CFGS[@]}" ISO_CFGS < <(
    xorriso -indev "$SOURCE_ISO" -find / -type file -name '*.cfg' 2>/dev/null |
        sed -e "s/^'//" -e "s/'\$//"
)

PATCH_STAGE="$WORKDIR/patched"
MAP_ARGS=()
patched_any=0
declare -A seen_cfg=()

for isopath in "${ISO_CFGS[@]}"; do
    [[ -n "$isopath" ]] || continue
    [[ -z "${seen_cfg[$isopath]:-}" ]] || continue
    seen_cfg[$isopath]=1
    staged="$PATCH_STAGE/${isopath#/}"
    mkdir -p "$(dirname -- "$staged")"
    if ! xorriso -osirrox on -indev "$SOURCE_ISO" \
        -extract "$isopath" "$staged" 2>/dev/null; then
        continue
    fi
    grep -q -- '---' "$staged" || continue
    chmod u+w "$staged"
    sed -i "s#---#${PRESEED_ARGS} ---#g" "$staged"
    if grep -qF -- "$PRESEED_ARGS" "$staged"; then
        MAP_ARGS+=(-map "$staged" "$isopath")
        patched_any=1
        log_info "    patched ${isopath}"
    else
        log_warn "preseed injection did not take in ${isopath}"
    fi
done

if [[ "$patched_any" -ne 1 ]]; then
    log_error "No bootloader menu files were patched -- the ISO layout may have changed."
    log_error "Inspect with: xorriso -indev '$SOURCE_ISO' -find / -name '*.cfg'"
    exit 1
fi

# --- Image Generation ---
log_info "Building preseed ISO (replaying original boot equipment)..."
BUILD_ISO="$WORKDIR/output.iso"
xorriso \
    -indev "$SOURCE_ISO" \
    -outdev "$BUILD_ISO" \
    -boot_image any replay \
    -map "$PRESEED_SRC" /preseed.cfg \
    -map "$RECIPES_SRC" /recipes \
    "${MAP_ARGS[@]}" \
    -commit

mv "$BUILD_ISO" "$OUTPUT_ISO"

log_info "Successfully generated ISO:"
log_info "    $OUTPUT_ISO"
