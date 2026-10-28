#!/usr/bin/env bash
#
# generate-debian-iso.sh
#
# Downloads the *current* Debian amd64 netinst ISO (verified against the
# published SHA256SUMS, optionally OpenPGP-verified), injects preseed.cfg
# and recipes/ from a config directory, and writes an unattended-install
# ISO that boots the automated install after BOOT_TIMEOUT seconds.
#
# A config directory either holds a ready-made preseed.cfg, or a vm.conf
# of per-VM values that is rendered into preseeds/common/preseed.cfg.in.
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
readonly CACHE_DIR="${DEBIAN_ISO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/generate-debian-iso}"
# Kernel command-line snippet that triggers the unattended install.
readonly PRESEED_ARGS='auto=true priority=critical file=/cdrom/preseed.cfg'
# Debian CD signing key (see https://www.debian.org/CD/verify).
readonly DEBIAN_CD_SIGNING_KEY='DF9B9C49EAA9298432589D76DA87E80D6294BE9B'
readonly REQUIRE_GPG="${REQUIRE_GPG:-0}"
readonly SKIP_GPG="${SKIP_GPG:-0}"
# Per-VM config directories (tcyclops, dcyclops, ...) live next to this script.
PRESEEDS_DIR="$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/preseeds"
readonly PRESEEDS_DIR
# Shared template and recipes used by every per-VM config (not a VM itself).
readonly COMMON_NAME="common"
readonly COMMON_DIR="$PRESEEDS_DIR/$COMMON_NAME"
# Seconds the boot menus wait before starting the (preseeded) default entry.
readonly BOOT_TIMEOUT="${BOOT_TIMEOUT:-5}"
# Keys every vm.conf must define, and nothing else.
readonly VM_CONF_KEYS=(HOSTNAME DOMAIN IPADDRESS NETMASK GATEWAY NAMESERVERS)

available_vms() {
    local d name names=()
    for d in "$PRESEEDS_DIR"/*/; do
        name="$(basename -- "$d")"
        [[ -d "$d" && "$name" != "$COMMON_NAME" ]] && names+=("$name")
    done
    if [[ ${#names[@]} -eq 0 ]]; then
        printf 'none found'
        return
    fi
    printf '%s' "${names[0]}"
    printf ', %s' "${names[@]:1}"
}

usage() {
    cat <<EOF >&2
Usage: $0 <vm-name | config-directory> [output-directory] [iso-path]

Arguments:
  vm-name           Name of a config under ${PRESEEDS_DIR}/
                    ($(available_vms))
  config-directory  Directory containing either preseed.cfg or vm.conf
                    (rendered into ${COMMON_DIR}/preseed.cfg.in), and
                    optionally recipes/ (default: ${COMMON_DIR}/recipes)
  output-directory  Where to write <config-name>-preseed-auto.iso, where
                    <config-name> is the config directory's basename
                    (default: current directory).
                    Must be given explicitly when passing iso-path.
  iso-path          Use this local Debian netinst ISO instead of downloading.

Environment:
  DEBIAN_ISO_BASE_URL    Override the ISO directory URL
                         (default: ${ISO_BASE_URL})
  DEBIAN_ISO_CACHE       ISO download cache directory
                         (default: ${CACHE_DIR})
  BOOT_TIMEOUT           Seconds before the boot menu auto-starts the
                         install (default: 5)
  DEBIAN_OUTPUT_NAME     Output ISO filename
                         (default: <config-name>-preseed-auto.iso)
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

if [[ ! "$BOOT_TIMEOUT" =~ ^[0-9]+$ ]] || ((${#BOOT_TIMEOUT} > 4)); then
    log_error "BOOT_TIMEOUT must be a non-negative integer (seconds, max 9999), got '$BOOT_TIMEOUT'"
    exit 1
fi

# A bare name (no slash) that is not a local directory selects a VM config
# under preseeds/.
if [[ "$1" != */* && ! -d "$1" ]]; then
    if [[ "$1" == "$COMMON_NAME" || ! -d "$PRESEEDS_DIR/$1" ]]; then
        log_error "Unknown VM '$1' (available: $(available_vms))"
        exit 1
    fi
    CONFIG_DIR="$PRESEEDS_DIR/$1"
else
    CONFIG_DIR="$(realpath -- "$1")"
fi
if [[ ! -d "$CONFIG_DIR" ]]; then
    log_error "Config directory not found: $CONFIG_DIR"
    exit 1
fi
# Named after the config directory so per-VM ISOs (tcyclops, dcyclops, ...)
# can share an output directory without overwriting each other.
readonly OUTPUT_NAME="${DEBIAN_OUTPUT_NAME:-$(basename -- "$CONFIG_DIR")-preseed-auto.iso}"

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

if [[ -d "$CONFIG_DIR/recipes" ]]; then
    readonly RECIPES_SRC="$CONFIG_DIR/recipes"
else
    readonly RECIPES_SRC="$COMMON_DIR/recipes"
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

# --- Preseed selection / rendering ---
readonly RE_OCTET='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
readonly RE_IPV4="^${RE_OCTET}(\\.${RE_OCTET}){3}\$"
readonly RE_LABEL='[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
readonly RE_HOSTNAME="^${RE_LABEL}\$"
readonly RE_DOMAIN="^${RE_LABEL}(\\.${RE_LABEL})*\$"

# Validate one vm.conf value; $1 = key, $2 = value.
validate_vm_value() {
    local key="$1" val="$2" ns
    case "$key" in
        IPADDRESS | NETMASK | GATEWAY) [[ "$val" =~ $RE_IPV4 ]] ;;
        NAMESERVERS)
            [[ -n "$val" ]] || return 1
            for ns in $val; do
                [[ "$ns" =~ $RE_IPV4 ]] || return 1
            done
            ;;
        HOSTNAME) [[ "$val" =~ $RE_HOSTNAME ]] ;;
        DOMAIN) [[ "$val" =~ $RE_DOMAIN ]] && ((${#val} <= 253)) ;;
        *) return 1 ;;
    esac
}

# Render the common template with the values of a vm.conf ($1) into $2.
# vm.conf is parsed, never sourced.
render_preseed() {
    local conf="$1" out="$2" line key val k found
    local -A vals=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ ! "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
            log_error "$conf: malformed line: '$line' (expected KEY=VALUE)"
            exit 1
        fi
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        found=0
        for k in "${VM_CONF_KEYS[@]}"; do
            [[ "$k" == "$key" ]] && found=1
        done
        if [[ "$found" -ne 1 ]]; then
            log_error "$conf: unknown key '$key' (allowed: ${VM_CONF_KEYS[*]})"
            exit 1
        fi
        if [[ -n "${vals[$key]+x}" ]]; then
            log_error "$conf: duplicate key '$key'"
            exit 1
        fi
        if ! validate_vm_value "$key" "$val"; then
            log_error "$conf: invalid value for $key: '$val'"
            exit 1
        fi
        vals[$key]="$val"
    done <"$conf"
    for k in "${VM_CONF_KEYS[@]}"; do
        if [[ -z "${vals[$k]+x}" ]]; then
            log_error "$conf: missing key '$k'"
            exit 1
        fi
    done

    local template="$COMMON_DIR/preseed.cfg.in"
    if [[ ! -f "$template" ]]; then
        log_error "Preseed template not found: $template"
        exit 1
    fi
    # Values are validated to [A-Za-z0-9.- ], so none contain sed
    # metacharacters (& \ / newline).
    local sed_args=()
    for k in "${VM_CONF_KEYS[@]}"; do
        sed_args+=(-e "s/@${k}@/${vals[$k]}/g")
    done
    sed "${sed_args[@]}" "$template" >"$out"
    if grep -qE '@[A-Z_]+@' "$out"; then
        log_error "Unsubstituted placeholders left in rendered preseed:"
        grep -nE '@[A-Z_]+@' "$out" >&2
        exit 1
    fi
    log_info "Rendered preseed for ${vals[HOSTNAME]}.${vals[DOMAIN]} (${vals[IPADDRESS]})"
}

sha_of() { sha256sum -- "$1" | awk '{print $1}'; }

if [[ -f "$CONFIG_DIR/preseed.cfg" ]]; then
    PRESEED_SRC="$CONFIG_DIR/preseed.cfg"
elif [[ -f "$CONFIG_DIR/vm.conf" ]]; then
    PRESEED_SRC="$WORKDIR/preseed.cfg"
    render_preseed "$CONFIG_DIR/vm.conf" "$PRESEED_SRC"
else
    log_error "Neither preseed.cfg nor vm.conf found in $CONFIG_DIR"
    exit 1
fi
readonly PRESEED_SRC

# The preseed names its partman recipe by /cdrom path; make sure that file is
# really in RECIPES_SRC (an empty recipes/ dir would otherwise ship nothing
# and leave the installer waiting at the partitioning prompt).
RECIPE_REF="$(awk '$2 == "partman-auto/expert_recipe_file" { print $4; exit }' "$PRESEED_SRC")"
if [[ -n "$RECIPE_REF" ]]; then
    if [[ "$RECIPE_REF" != /cdrom/recipes/* || ! -f "$RECIPES_SRC/${RECIPE_REF#/cdrom/recipes/}" ]]; then
        log_error "Preseed references recipe $RECIPE_REF, but it is not in $RECIPES_SRC/"
        exit 1
    fi
fi

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

# Unattended boot: stop the menus waiting forever. Entry 0 of both menus is
# an installer entry that has just been patched with PRESEED_ARGS.
GRUB_STAGED="$PATCH_STAGE/boot/grub/grub.cfg"
if [[ ! -f "$GRUB_STAGED" ]] || ! grep -qF -- "$PRESEED_ARGS" "$GRUB_STAGED"; then
    log_error "Patched /boot/grub/grub.cfg not staged -- cannot set the boot timeout."
    exit 1
fi
# Appended so these top-level settings run after anything earlier in the file.
printf 'set timeout=%s\nset default=0\n' "$BOOT_TIMEOUT" >>"$GRUB_STAGED"
log_info "    set GRUB timeout to ${BOOT_TIMEOUT}s"

ISOLINUX_CFG=/isolinux/isolinux.cfg
ISOLINUX_STAGED="$PATCH_STAGE/isolinux/isolinux.cfg"
mkdir -p "$(dirname -- "$ISOLINUX_STAGED")"
if xorriso -osirrox on -indev "$SOURCE_ISO" \
    -extract "$ISOLINUX_CFG" "$ISOLINUX_STAGED" 2>/dev/null; then
    chmod u+w "$ISOLINUX_STAGED"
    # syslinux counts timeout in tenths of a second.
    if grep -qiE '^[[:space:]]*timeout[[:space:]]' "$ISOLINUX_STAGED"; then
        sed -i -E "s/^[[:space:]]*[Tt][Ii][Mm][Ee][Oo][Uu][Tt][[:space:]].*/timeout $((BOOT_TIMEOUT * 10))/" "$ISOLINUX_STAGED"
    else
        printf 'timeout %s\n' "$((BOOT_TIMEOUT * 10))" >>"$ISOLINUX_STAGED"
    fi
    MAP_ARGS+=(-map "$ISOLINUX_STAGED" "$ISOLINUX_CFG")
    log_info "    set isolinux timeout to ${BOOT_TIMEOUT}s"
else
    log_warn "${ISOLINUX_CFG} not found -- BIOS boot menu timeout not set."
fi

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
