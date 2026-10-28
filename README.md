# Homelab Scripts

A repository with all my homelab scripts.

Network layout referenced throughout:

| Network          | Purpose              | Path                                          |
| ---------------- | -------------------- | --------------------------------------------- |
| `10.0.1.0/24`    | dcyclops (dev, `.2`)  | Hyper-V **HomelabDev** internal vSwitch       |
| `10.0.2.0/24`    | tcyclops (test, `.2`) | Hyper-V **Homelab** internal vSwitch          |
| `192.168.2.0/24` | cyclops (production) | physical homelab LAN behind the host          |

Both Hyper-V switches reach the internet through one shared `HomelabNAT` on
`10.0.0.0/16`. WinNAT allows only one NAT network per host, so the NAT covers
every lab subnet rather than each switch having its own.

| Host       | Role                                                                  |
| ---------- | --------------------------------------------------------------------- |
| `cyclops`  | production (physical)                                                 |
| `tcyclops` | long-lived test VM for exercising specific changes                    |
| `dcyclops` | throwaway dev VM: bring up, do something, tear down, rebuild          |

## Scripts

### `scripts/iso/debian/generate-debian-iso.sh`

Downloads the **current** Debian amd64 netinst ISO, verifies it against the
published `SHA256SUMS` (and, if `gpg` and the Debian CD signing key are
available, the OpenPGP signature), injects a preseed and partman recipes, and
writes an unattended-install ISO to `<OUTPUT DIRECTORY>` (defaults to the
current directory). The ISO boots straight into the automated install after
`BOOT_TIMEOUT` seconds, with no menu selection needed (UEFI and BIOS).

```bash
generate-debian-iso.sh <VM NAME | CONFIG DIRECTORY> [OUTPUT DIRECTORY] [BASE ISO]
```

- `<VM NAME>` (`tcyclops` or `dcyclops`) selects the matching config under
  `scripts/iso/debian/preseeds/`, e.g. `generate-debian-iso.sh dcyclops`.
- Preseed layout: `preseeds/common/preseed.cfg.in` is the one shared template
  and `preseeds/common/recipes/` the shared recipes. Each
  `preseeds/<vm>/vm.conf` holds only that VM's `HOSTNAME`, `DOMAIN`,
  `IPADDRESS`, `NETMASK`, `GATEWAY` and `NAMESERVERS`, which must match its
  entry in `create-cyclops-vm.ps1` (see the network table above). `vm.conf` is
  parsed (not sourced) and validated; unknown, missing or malformed values
  fail the build.
- `<CONFIG DIRECTORY>` is any other directory with either a ready-made
  `preseed.cfg` or a `vm.conf`, and optionally its own `recipes/`. The build
  fails if the recipe the preseed names is missing.
- The output ISO is named `<config dir name>-preseed-auto.iso` (e.g.
  `dcyclops-preseed-auto.iso`), so both VMs' ISOs can share a directory.
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
| `DEBIAN_OUTPUT_NAME`  | output ISO filename (default `<config dir name>-preseed-auto.iso`) |
| `BOOT_TIMEOUT`        | seconds the boot menu waits before auto-starting the install (default `5`) |
| `REQUIRE_GPG=1`       | fail unless `SHA256SUMS` is OpenPGP-verified            |
| `SKIP_GPG=1`          | skip OpenPGP verification                               |

Requires `wget`, `xorriso`, `gpg` (optional), and coreutils/`awk`
(`sha256sum`, `realpath`, ...). `nix develop` provides all of these.

### `scripts/hyper-v/create-cyclops-vm.ps1`

> [!WARNING]
> Requires an elevated (Administrator) PowerShell session for Hyper-V actions.

Creates or reconciles the Generation 2 `tcyclops` (test) or `dcyclops` (dev) VM
(Switch, NAT, VHD, CPU/nested-virt, TPM, Secure Boot off, MAC spoofing). Each VM
gets its own internal switch and subnet (see the network table above); per-VM
sizing and networking live in a table at the top of the script.

- On first run after upgrading, any existing NAT on exactly a lab subnet
  (e.g. an older per-VM NAT, whatever its name) is replaced with the
  shared `HomelabNAT` on `10.0.0.0/16`, briefly interrupting NAT for running lab
  VMs. A NAT that overlaps the lab range in any other way stops the script; any
  other NAT only triggers a warning, since WinNAT supports one per host.

```ps1
create-cyclops-vm.ps1 -VM <tcyclops|dcyclops> -IsoPath <AUTO INSTALL ISO> [-Force] [-Reinstall] [-Rebuild] [-Start] [-EnableGuestServiceInterface]
```

- `-Rebuild` deletes the VM and its disks (checkpoints included) and creates it
  fresh. It is refused for `tcyclops`, which is permanent; only `dcyclops`
  allows it. A typical dev loop:

  ```ps1
  create-cyclops-vm.ps1 -VM dcyclops -IsoPath .\dcyclops-preseed-auto.iso -Rebuild -Start
  # ...do something...
  Stop-VM dcyclops.homelab.zezura.cc
  ```

- `-Start` boots the VM once configuration is done.

- Offline-only settings require the VM to be **Off**. The script stops with a
  message if it is running; `-Force` stops it automatically.
- The ISO is attached and the boot order changed **only** on first create,
  `-Rebuild` or `-Reinstall`. This stops a re-run from silently re-arming the
  unattended installer (which would wipe the disk) on a provisioned VM.
- Because the ISO installs without a keypress, new and rebuilt VMs boot
  **disk first, then DVD**: the blank disk falls through to the installer once,
  and the installed disk boots itself afterwards instead of reinstalling.
  `-Reinstall` puts the DVD first (the disk already has an OS); the installer
  then registers its own UEFI boot entry ahead of it.
- `-EnableGuestServiceInterface` opts into host→guest file copy (off by
  default).

### `scripts/hyper-v/enable-interface-forwarding.ps1`

> [!WARNING]
> Requires an elevated (Administrator) PowerShell session.

Enables IPv4 forwarding on the host vEthernet interfaces so WSL2 can route to
Hyper-V VMs on the lab switch.

```ps1
enable-interface-forwarding.ps1 [-SwitchName Homelab,HomelabDev[,...]] [-SkipWsl]
```

The WSL adapter is discovered by pattern (works for both `vEthernet (WSL)` and
`vEthernet (WSL (Hyper-V firewall))`). WSL recreates its adapter on restart and
resets the flag, so **re-run this after `wsl --shutdown`**.

### `scripts/wsl/route-cyclops.sh`

Creates static routes inside WSL to reach dcyclops (`10.0.1.0/24`), tcyclops (`10.0.2.0/24`) and cyclops
(`192.168.2.0/24`) via the (runtime-detected) Windows host gateway. Idempotent;
run it by hand after a WSL restart.

```bash
route-cyclops.sh
```

### `scripts/cis/cis-coverage.sh`

Reconciles CIS Debian 13 coverage between the sibling `ansible` and
`cis-benchmark` repos: it reads the `cis_<id>` task tags from
`ansible/playbooks/os-debian-13.yml` (`ansible-playbook --list-tags`) and the
per-recommendation status tables in `cis-benchmark/docs/cyclops-debian-13-base/`,
regenerates that repo's `coverage.md`, and — with `--check` — exits non-zero on a
traceability gap (a recommendation marked implemented with no matching tag, or
one still marked `:x:`).

```bash
cis-coverage.sh [--check]
```

Repo paths default to siblings under `~/repos/homelab`; override with
`$ANSIBLE_DIR` / `$CIS_BENCHMARK_DIR`. Requires `ansible-playbook` on `PATH`, so
run it from the `ansible` repo's `nix develop` shell.

## Development

`nix develop` (or `direnv allow`) drops you in a shell with every dependency
plus `shellcheck` / `shfmt`. CI runs `shellcheck`, `bash -n` and
`PSScriptAnalyzer` (see `.github/workflows/lint.yml`). Format shell scripts with
`shfmt -w -i 4 -ci`.
