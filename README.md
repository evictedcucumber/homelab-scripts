# Homelab Scripts

A repository with all my homelab scripts.

## Scripts

### `scripts/iso/debian/generate-debian-iso.sh`

Use the script to download the base debian ISO and add the preseed from `<PRESEED FILES>` to the autoinstall ISO then move the generated ISO to `<OUTPUT DESTINATION>`.

```bash
generate-debian-iso.sh <PRESEED FILES> <OUTPUT DESTINATION>
```

Use the script to use a predownloaded base debian ISO at `<BASE DEBIAN ISO>` and add the preseed from `<PRESEED FILES>` to the autoinstall ISO then move the generated ISO to `<OUTPUT DESTINATION>`.

```bash
generate-debian-iso.sh <PRESEED FILES> <OUTPUT DESTINATION> <BASE DEBIAN ISO>
```

### `./scripts/hyper-v/create-tcyclops-vm.ps1`

> [!WARNING] Administrator
> Script requries running as administrator to correctly perform Hyper-V actions.

Create the homelab test envrionment such as Switch, NAT, VM using the ISO from `<AUTO INSTALL ISO>`.

```ps1
create-tcyclops-vm.ps1 <AUTO INSTALL ISO>
```
