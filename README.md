# Homelab Scripts

A repository with all my homelab scripts.

Network layout referenced throughout:

| Network          | Purpose             | Path                                       |
| ---------------- | ------------------- | ------------------------------------------ |
| `10.0.0.0/24`    | tcyclops (test)     | Hyper-V **Homelab** internal vSwitch + NAT |
| `192.168.2.0/24` | cyclops (production) | physical homelab LAN behind the host       |

## Scripts

### `scripts/iso/debian/generate-debian-iso.sh`

Downloads the **current** Debian amd64 netinst ISO, verifies it against the
published `SHA256SUMS` (and, if `gpg` and the Debian CD signing key are
available, the OpenPGP signature), injects `preseed.cfg` and `recipes/` from
`<CONFIG DIRECTORY>`, and writes the autoinstall ISO to `<OUTPUT DIRECTORY>`
(defaults to the current directory).

```bash
generate-debian-iso.sh <CONFIG DIRECTORY> [OUTPUT DIRECTORY] [BASE ISO]
```

- `<CONFIG DIRECTORY>` must contain `preseed.cfg` and a `recipes/` directory.
- `[BASE ISO]` uses a local ISO instead of downloading. `<OUTPUT DIRECTORY>`
  must be given explicitly when you pass it (it is positional).
- The netinst filename is resolved from `SHA256SUMS` at runtime, so a new
  Debian point release will not 404 a hardcoded URL.
- Downloads are cached (resumable) under
  `${XDG_CACHE_HOME:-~/.cache}/generate-debian-iso`.
- The source image's BIOS + UEFI boot records are replayed verbatim
  (`xorriso -boot_image any replay`), so no El Torito / isohybrid offsets are
  hand-maintained.

The root password in `preseed.cfg` is a throwaway placeholder hash (marked
`# CHANGES POST OS INSTALL`) that configuration management resets after install.

**Environment variables:**

| Variable              | Effect                                                   |
| --------------------- | ------------------------------------------------------- |
| `DEBIAN_ISO_BASE_URL` | override the ISO directory URL                          |
| `DEBIAN_ISO_CACHE`    | override the download cache directory                   |
| `DEBIAN_OUTPUT_NAME`  | output ISO filename (default `debian-preseed-auto.iso`) |
| `REQUIRE_GPG=1`       | fail unless `SHA256SUMS` is OpenPGP-verified            |
| `SKIP_GPG=1`          | skip OpenPGP verification                               |

Requires `wget`, `xorriso`, `gpg` (optional), and coreutils/`awk`
(`sha256sum`, `realpath`, ...). `nix develop` provides all of these.

### `scripts/hyper-v/create-tcyclops-vm.ps1`

> [!WARNING]
> Requires an elevated (Administrator) PowerShell session for Hyper-V actions.

Creates or reconciles the Generation 2 `tcyclops` test VM (Switch, NAT, VHD,
CPU/nested-virt, TPM, Secure Boot off, MAC spoofing).

```ps1
create-tcyclops-vm.ps1 -IsoPath <AUTO INSTALL ISO> [-Force] [-Reinstall] [-EnableGuestServiceInterface]
```

- Offline-only settings require the VM to be **Off**. The script stops with a
  message if it is running; `-Force` stops it automatically.
- The ISO is attached and the DVD made first boot device **only** on first
  create, or with `-Reinstall`. This stops a re-run from silently re-arming the
  unattended installer (which would wipe the disk) on a provisioned VM.
- `-EnableGuestServiceInterface` opts into host→guest file copy (off by
  default).

### `scripts/hyper-v/enable-interface-forwarding.ps1`

> [!WARNING]
> Requires an elevated (Administrator) PowerShell session.

Enables IPv4 forwarding on the host vEthernet interfaces so WSL2 can route to
Hyper-V VMs on the lab switch.

```ps1
enable-interface-forwarding.ps1 [-SwitchName Homelab[,...]] [-SkipWsl]
```

The WSL adapter is discovered by pattern (works for both `vEthernet (WSL)` and
`vEthernet (WSL (Hyper-V firewall))`). WSL recreates its adapter on restart and
resets the flag, so **re-run this after `wsl --shutdown`**.

### `scripts/wsl/route-cyclops.sh`

Creates static routes inside WSL to reach tcyclops (`10.0.0.0/24`) and cyclops
(`192.168.2.0/24`) via the (runtime-detected) Windows host gateway. Idempotent;
run it by hand after a WSL restart.

```bash
route-cyclops.sh
```

## Development

`nix develop` (or `direnv allow`) drops you in a shell with every dependency
plus `shellcheck` / `shfmt`. CI runs `shellcheck`, `bash -n` and
`PSScriptAnalyzer` (see `.github/workflows/lint.yml`). Format shell scripts with
`shfmt -w -i 4 -ci`.
