# Homelab Scripts

A repository with all my homelab scripts.

## Scripts

### `scripts/iso/debian/generate-debian-iso.sh`

Downloads the base Debian ISO, injects the `preseed.cfg` and `recipes/` from `<CONFIG DIRECTORY>`, and writes the resulting autoinstall ISO to `<OUTPUT DIRECTORY>` (defaults to the current directory if omitted).

```bash
generate-debian-iso.sh <CONFIG DIRECTORY> [OUTPUT DIRECTORY]
```

Use a predownloaded base Debian ISO at `<BASE ISO>` instead of downloading one:

```bash
generate-debian-iso.sh <CONFIG DIRECTORY> [OUTPUT DIRECTORY] <BASE ISO>
```

`<CONFIG DIRECTORY>` must contain a `preseed.cfg` file and a `recipes/` directory. Set the `DEBIAN_ISO_URL` environment variable to override the default download URL. Requires `wget`, `xorriso`, `rsync`, and `sha256sum`.

### `./scripts/hyper-v/create-tcyclops-vm.ps1`

> [!WARNING] Administrator
> Script requires running as administrator to correctly perform Hyper-V actions.

Create the homelab test environment such as Switch, NAT, VM using the ISO from `<AUTO INSTALL ISO>`.

```ps1
create-tcyclops-vm.ps1 <AUTO INSTALL ISO>
```

### `./scripts/wsl/route-cyclops.sh`

Create required static routes inside WSL to allow communication between WSL and both tcyclops (test, 10.0.0.0/24) and cyclops (production, 192.168.2.0/24).

```bash
route-cyclops.sh
```

### `./scripts/hyper-v/enable-interface-forwarding.ps1`

Enable forwarding between WSL and Hyper-V to allow communication between WSL and tcyclops.

```ps1
enable-interface-forwarding.ps1
```
