#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates or updates the tcyclops (test) or dcyclops (dev) Hyper-V VM idempotently.

.DESCRIPTION
    Manages two Generation 2 Hyper-V VMs, selected with -VM. Intended for
    running Proxmox VE nested.

    Each VM gets its own internal virtual switch and subnet; the host holds
    the .1 address of each subnet as the guest gateway:

      VM        Switch       Host/gateway IP   Subnet
      tcyclops  Homelab      10.0.2.1          10.0.2.0/24
      dcyclops  HomelabDev   10.0.1.1          10.0.1.0/24

    Both subnets sit behind one shared NAT, "HomelabNAT", with prefix
    10.0.0.0/16 (WinNAT supports only one NAT network per host). If an older
    HomelabNAT with a different prefix exists it is replaced, which briefly
    interrupts NAT for running lab VMs.

      tcyclops  Permanent test VM. Created once and reconciled on re-runs.
      dcyclops  Ephemeral dev VM. Brought up, used, brought down, and rebuilt
                from scratch with -Rebuild (e.g. -VM dcyclops -Rebuild -Start).

    Creates the VM if it does not exist, or reconciles its configuration if it
    already exists. Most settings (vCPU count, nested virtualization, static
    memory, firmware, TPM) can only be changed while the VM is in the Off
    state. If the VM is running the script stops with a clear message; pass
    -Force to have it stopped automatically.

    The install ISO is only attached and the DVD only made the first boot
    device when the VM is first created, or when -Reinstall or -Rebuild is
    given. This prevents a re-run from silently re-triggering the unattended
    installer (which would wipe the disk) on an already-provisioned VM.

    -Rebuild (ephemeral VMs only) turns the VM off, removes it together with
    its checkpoints and its VHD directory, then creates it again from scratch
    with the ISO attached and a fresh "pre-os-install" checkpoint. It is
    refused for permanent VMs such as tcyclops; use -Reinstall there.

.PARAMETER VM
    Which VM to manage: tcyclops (permanent test VM) or dcyclops (ephemeral
    dev VM). Per-VM name and sizing live in the Desired Configuration section.

.PARAMETER IsoPath
    Path to the autoinstall ISO to mount in the VM's DVD drive.

.PARAMETER Force
    Stop the VM if it is running so offline-only settings can be applied.

.PARAMETER Reinstall
    Re-attach the ISO and set the DVD as first boot device even on an existing
    VM. WARNING: on next boot this re-runs the unattended installer.

.PARAMETER Rebuild
    Destroy and recreate the VM from scratch: stop it, remove the VM, delete
    its VHD directory (including checkpoint files), then run the normal create
    path. Only allowed for ephemeral VMs (dcyclops). WARNING: all VM data is
    lost.

.PARAMETER Start
    Start the VM after it has been configured, if it is not already running.

.PARAMETER EnableGuestServiceInterface
    Also enable the "Guest Service Interface" integration service (host to
    guest file copy). Left disabled by default.

.EXAMPLE
    .\create-cyclops-vm.ps1 -VM tcyclops -IsoPath C:\isos\proxmox-auto.iso

    First create of the permanent test VM (or reconcile an existing one).

.EXAMPLE
    .\create-cyclops-vm.ps1 -VM dcyclops -IsoPath C:\isos\proxmox-auto.iso -Rebuild -Start

    Throw away dcyclops (if present), recreate it from scratch, and boot it
    into the unattended installer.

.NOTES
    Run in an elevated PowerShell session (Administrator).
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('tcyclops', 'dcyclops')]
    [string]$VM,

    [Parameter(Mandatory)]
    [string]$IsoPath,

    [switch]$Force,

    [switch]$Reinstall,

    [switch]$Rebuild,

    [switch]$Start,

    [switch]$EnableGuestServiceInterface
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------
# Desired Configuration
# ---------------------------------------------------------------------

# Per-VM settings. Ephemeral VMs may be destroyed and recreated with -Rebuild.
$VMConfigs = @{
    tcyclops = @{
        Name          = "tcyclops.homelab.zezura.cc"
        MemoryStartup = 8GB
        CPUCount      = 4
        VHDSize       = 256GB
        Ephemeral     = $false
        SwitchName    = "Homelab"
        HostIPAddress = "10.0.2.1"
        Subnet        = "10.0.2.0/24"
    }
    dcyclops = @{
        Name          = "dcyclops.homelab.zezura.cc"
        MemoryStartup = 8GB
        CPUCount      = 4
        VHDSize       = 256GB
        Ephemeral     = $true
        SwitchName    = "HomelabDev"
        HostIPAddress = "10.0.1.1"
        Subnet        = "10.0.1.0/24"
    }
}

$VMConfig = $VMConfigs[$VM]

$Name = $VMConfig.Name
$Ephemeral = $VMConfig.Ephemeral

$Generation = 2

$MemoryStartup = $VMConfig.MemoryStartup
$CPUCount = $VMConfig.CPUCount

$SwitchName = $VMConfig.SwitchName
$HostIPAddress = $VMConfig.HostIPAddress
$PrefixLength = 24
$Subnet = $VMConfig.Subnet

# WinNAT allows only one NAT network per host, so all lab switches share a
# single NAT. Its prefix must contain every per-VM subnet above: 10.0.0.0/16
# covers 10.0.1.0/24 (dcyclops), 10.0.2.0/24 (tcyclops) and room for more.
$NatName = "HomelabNAT"
$NatPrefix = "10.0.0.0/16"

$VMPath = "E:\Hyper-V VMs"
$VHDDirectory = Join-Path $VMPath "$Name\Virtual Hard Disks"
$VHDPath = Join-Path $VHDDirectory "$Name.vhdx"
$VHDSize = $VMConfig.VHDSize
$VHDSizeGB = [int]($VHDSize / 1GB)

$EnableTPM = $true

# ---------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------

# Resolve the ISO to an absolute path up front: Hyper-V cmdlets and the VMMS
# service do not share this process's working directory, and $dvd.Path
# comparisons later assume an absolute path.
try
{
    $IsoPath = (Resolve-Path -LiteralPath $IsoPath).Path
}
catch
{
    throw "ISO not found: $IsoPath"
}

function Assert-Prerequisite
{
    if (-not (Get-Module -ListAvailable Hyper-V))
    {
        throw "Hyper-V PowerShell module is not installed."
    }

    if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf))
    {
        throw "ISO is not a file: $IsoPath"
    }

    $vmDriveRoot = [System.IO.Path]::GetPathRoot($VMPath)
    if ($vmDriveRoot -and -not (Test-Path -LiteralPath $vmDriveRoot))
    {
        throw "VM storage location is not available: $vmDriveRoot (from `$VMPath = $VMPath)"
    }
}

Assert-Prerequisite

if ($Rebuild -and -not $Ephemeral)
{
    throw "-Rebuild is refused for permanent VM '$VM'. Use -Reinstall to re-arm the installer instead."
}

# ---------------------------------------------------------------------
# Network Switch & Shared NAT Setup
# ---------------------------------------------------------------------

function Test-CidrOverlap
{
    param(
        [Parameter(Mandatory)][string]$CidrA,
        [Parameter(Mandatory)][string]$CidrB
    )

    function ConvertTo-Range
    {
        param([string]$Cidr)

        $addr, $len = $Cidr -split '/'
        $bytes = ([System.Net.IPAddress]::Parse($addr)).GetAddressBytes()
        [uint64]$start = 0
        foreach ($b in $bytes)
        {
            $start = $start * 256 + $b
        }
        $size = [math]::Pow(2, 32 - [int]$len)
        $start = [math]::Floor($start / $size) * $size
        return @($start, ($start + $size - 1))
    }

    $a = ConvertTo-Range $CidrA
    $b = ConvertTo-Range $CidrB
    return ($a[0] -le $b[1]) -and ($b[0] -le $a[1])
}

function Initialize-NetworkSwitch
{
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    $switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue

    if (-not $switch)
    {
        if ($PSCmdlet.ShouldProcess($SwitchName, "Create Internal Virtual Switch"))
        {
            Write-Host "Creating Virtual Switch '$SwitchName'..." -ForegroundColor Cyan
            New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
        }
    }
    else
    {
        Write-Host "Virtual switch '$SwitchName' already exists." -ForegroundColor Yellow
    }

    $adapterAlias = "vEthernet ($SwitchName)"

    # Wait for adapter
    $adapter = $null
    for ($i = 0; $i -lt 20; $i++)
    {
        $adapter = Get-NetAdapter -Name $adapterAlias -ErrorAction SilentlyContinue
        if ($adapter) { break }
        Start-Sleep -Seconds 1
    }

    if (-not $adapter)
    {
        Write-Warning "Adapter '$adapterAlias' did not appear after 20s; skipping host gateway IP configuration."
    }
    else
    {
        $ip = Get-NetIPAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $HostIPAddress }

        if (-not $ip)
        {
            if ($PSCmdlet.ShouldProcess($adapterAlias, "Assign Gateway IP $HostIPAddress/$PrefixLength"))
            {
                Write-Host "Assigning IP $HostIPAddress to $adapterAlias (subnet $Subnet)..." -ForegroundColor Cyan

                Get-NetIPAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -notlike "169.254.*" } |
                    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

                $newIp = New-NetIPAddress `
                    -InterfaceAlias $adapterAlias `
                    -IPAddress $HostIPAddress `
                    -PrefixLength $PrefixLength `
                    -ErrorAction SilentlyContinue

                if (-not $newIp)
                {
                    Write-Warning "Failed to assign $HostIPAddress/$PrefixLength to '$adapterAlias'. VM guests will have no gateway."
                }
            }
        }
    }

    $allNats = @(Get-NetNat -ErrorAction SilentlyContinue)
    $labSubnets = @($VMConfigs.Values | ForEach-Object { $_.Subnet })

    # Lab NATs: ours by name, plus any NAT on exactly one lab subnet. Older
    # per-VM setups created those (e.g. a per-VM NAT for one lab subnet under
    # another name); they are folded into the shared NAT.
    $labNats = @($allNats | Where-Object {
            $_.Name -eq $NatName -or $labSubnets -contains $_.InternalIPInterfaceAddressPrefix
        })

    $otherNats = @($allNats | Where-Object { $labNats -notcontains $_ })

    # Never delete someone else's NAT; an overlapping one would also break ours.
    $foreignNat = $otherNats | Where-Object {
        $_.InternalIPInterfaceAddressPrefix -and
        $_.InternalIPInterfaceAddressPrefix -notmatch ':' -and
        (Test-CidrOverlap $_.InternalIPInterfaceAddressPrefix $NatPrefix)
    } | Select-Object -First 1

    if ($foreignNat)
    {
        throw "Existing NAT '$($foreignNat.Name)' ($($foreignNat.InternalIPInterfaceAddressPrefix)) overlaps the lab range $NatPrefix. Remove or renumber it first; this script will not delete it."
    }

    foreach ($other in $otherNats)
    {
        Write-Warning "Another NAT '$($other.Name)' ($($other.InternalIPInterfaceAddressPrefix)) exists. WinNAT supports only one NAT per host; multiple NATs leave it in an undefined state. Remove it if it is unused."
    }

    if ($labNats.Count -eq 1 -and $labNats[0].Name -eq $NatName -and $labNats[0].InternalIPInterfaceAddressPrefix -eq $NatPrefix)
    {
        Write-Host "NAT Network '$NatName' ($NatPrefix) already exists." -ForegroundColor Yellow
        return
    }

    foreach ($old in $labNats)
    {
        if ($PSCmdlet.ShouldProcess($old.Name, "Remove lab NAT ($($old.InternalIPInterfaceAddressPrefix)) to replace it with shared '$NatName' ($NatPrefix)"))
        {
            Write-Host "Removing NAT '$($old.Name)' ($($old.InternalIPInterfaceAddressPrefix)); replacing with '$NatName' ($NatPrefix). This briefly interrupts NAT for running lab VMs." -ForegroundColor Yellow
            Remove-NetNat -Name $old.Name -Confirm:$false
        }
    }

    if ($PSCmdlet.ShouldProcess($NatName, "Create NAT Network ($NatPrefix)"))
    {
        Write-Host "Creating NAT Network '$NatName' ($NatPrefix)..." -ForegroundColor Cyan
        New-NetNat `
            -Name $NatName `
            -InternalIPInterfaceAddressPrefix $NatPrefix | Out-Null
    }
}

Initialize-NetworkSwitch

# ---------------------------------------------------------------------
# Rebuild  (ephemeral VMs only): tear down so the create path starts fresh
# ---------------------------------------------------------------------

if ($Rebuild)
{
    $existingVm = Get-VM -Name $Name -ErrorAction SilentlyContinue

    if ($existingVm)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Rebuild: turn off and remove VM"))
        {
            if ($existingVm.State -ne 'Off')
            {
                Write-Host "Turning off VM '$Name'..." -ForegroundColor Cyan
                Stop-VM -Name $Name -TurnOff -Force -Confirm:$false
            }

            Write-Host "Removing VM '$Name'..." -ForegroundColor Cyan
            Remove-VM -Name $Name -Force -Confirm:$false
        }
    }
    else
    {
        Write-Host "VM '$Name' does not exist; nothing to remove." -ForegroundColor Yellow
    }

    # Delete leftover storage (VHD, .avhdx checkpoint files). Never touch
    # anything outside $VMPath.
    $vmRoot = [System.IO.Path]::GetFullPath((Join-Path $VMPath $Name))
    $vmPathFull = [System.IO.Path]::GetFullPath($VMPath).TrimEnd('\', '/')

    if ([string]::IsNullOrWhiteSpace($Name) -or -not $vmRoot.StartsWith($vmPathFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase))
    {
        throw "Refusing to delete '$vmRoot': it is not inside '$vmPathFull'."
    }

    if (Test-Path -LiteralPath $vmRoot)
    {
        if ($PSCmdlet.ShouldProcess($vmRoot, "Rebuild: delete VM storage (VHDs and checkpoint files)"))
        {
            Write-Host "Deleting '$vmRoot'..." -ForegroundColor Cyan
            Remove-Item -LiteralPath $vmRoot -Recurse -Force
        }
    }
}

# ---------------------------------------------------------------------
# Directory Setup
# ---------------------------------------------------------------------

if (-not (Test-Path $VMPath))
{
    if ($PSCmdlet.ShouldProcess($VMPath, "Create VM directory"))
    {
        New-Item -ItemType Directory -Path $VMPath -Force | Out-Null
    }
}

if (-not (Test-Path $VHDDirectory))
{
    if ($PSCmdlet.ShouldProcess($VHDDirectory, "Create VHD directory"))
    {
        New-Item -ItemType Directory -Path $VHDDirectory -Force | Out-Null
    }
}

# ---------------------------------------------------------------------
# VM Creation / Existence Check
# ---------------------------------------------------------------------

$currentVm = Get-VM -Name $Name -ErrorAction SilentlyContinue
$vmIsNew = $false

if (-not $currentVm)
{
    if (Test-Path $VHDPath)
    {
        throw "VHD already exists but VM does not: $VHDPath"
    }

    if ($PSCmdlet.ShouldProcess($Name, "Create ${VHDSizeGB}GB Dynamic VHD and Generation $Generation VM"))
    {
        Write-Host "Creating $VHDSizeGB GB Dynamic VHD..." -ForegroundColor Cyan
        New-VHD -Path $VHDPath -SizeBytes $VHDSize -Dynamic | Out-Null

        Write-Host "Creating Generation $Generation VM '$Name'..." -ForegroundColor Cyan

        $currentVm = New-VM `
            -Name $Name `
            -Generation $Generation `
            -Path $VMPath `
            -MemoryStartupBytes $MemoryStartup `
            -VHDPath $VHDPath `
            -SwitchName $SwitchName

        $vmIsNew = $true
    }
}
else
{
    if ($currentVm.Generation -ne $Generation)
    {
        throw "VM '$Name' already exists but is Generation $($currentVm.Generation). This script requires a Generation $Generation VM."
    }

    Write-Host "VM '$Name' already exists (Generation $Generation). Ensuring configuration..." -ForegroundColor Yellow
}

# Verify VM exists before proceeding with configuration (e.g. if skipped in WhatIf mode)
$targetVm = Get-VM -Name $Name -ErrorAction SilentlyContinue

if (-not $targetVm)
{
    Write-Host "VM '$Name' does not exist (WhatIf mode or creation skipped). Skipping configuration steps." -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------
# Power State Guard
# ---------------------------------------------------------------------
# Almost every Set-* below requires the VM to be Off. Fail fast (or stop the
# VM with -Force) rather than erroring halfway through reconciliation.

if ($targetVm.State -ne 'Off')
{
    # -Rebuild always yields a new VM, so no -Force is needed (this branch is
    # only reachable under -WhatIf, where the old VM was not really removed).
    if ($Force -or $Rebuild)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Stop VM (currently $($targetVm.State)) to apply offline-only configuration"))
        {
            Write-Host "Stopping VM '$Name'..." -ForegroundColor Cyan
            Stop-VM -Name $Name -TurnOff -Force -Confirm:$false
            $targetVm = Get-VM -Name $Name
        }
    }
    else
    {
        throw "VM '$Name' is $($targetVm.State). Stop it first, or re-run with -Force to stop it automatically."
    }
}

# ---------------------------------------------------------------------
# Memory
# ---------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess($Name, "Configure Memory ($($MemoryStartup / 1GB) GB Static)"))
{
    Set-VMMemory `
        -VMName $Name `
        -DynamicMemoryEnabled $false `
        -StartupBytes $MemoryStartup
}

# ---------------------------------------------------------------------
# CPU & Nested Virtualization
# ---------------------------------------------------------------------

$proc = Get-VMProcessor -VMName $Name -ErrorAction SilentlyContinue

if (-not $proc -or $proc.Count -ne $CPUCount -or -not $proc.ExposeVirtualizationExtensions)
{
    if ($PSCmdlet.ShouldProcess($Name, "Configure CPU ($CPUCount vCPUs, Enable Nested Virtualization)"))
    {
        Set-VMProcessor `
            -VMName $Name `
            -Count $CPUCount `
            -ExposeVirtualizationExtensions $true
    }
}

# ---------------------------------------------------------------------
# VM Settings & Checkpoints
# ---------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess($Name, "Configure VM options & disable automatic checkpoints"))
{
    Set-VM `
        -Name $Name `
        -AutomaticCheckpointsEnabled $false `
        -AutomaticStartAction StartIfRunning `
        -AutomaticStopAction ShutDown `
        -CheckpointType Standard
}

# ---------------------------------------------------------------------
# Guest Integration Services
# ---------------------------------------------------------------------

$disabledServices = Get-VMIntegrationService -VMName $Name -ErrorAction SilentlyContinue | Where-Object {
    (-not $_.Enabled) -and ($EnableGuestServiceInterface -or $_.Name -ne 'Guest Service Interface')
}

if ($disabledServices)
{
    foreach ($service in $disabledServices)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Enable Integration Service '$($service.Name)'"))
        {
            Enable-VMIntegrationService -VMName $Name -Name $service.Name
        }
    }
}

# ---------------------------------------------------------------------
# DVD / ISO  (first-create or -Reinstall only)
# ---------------------------------------------------------------------

$applyIso = $vmIsNew -or $Reinstall -or $Rebuild

if ($applyIso)
{
    $dvd = Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $dvd)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Add DVD drive with ISO '$IsoPath'"))
        {
            $dvd = Add-VMDvdDrive -VMName $Name -Path $IsoPath -Passthru
        }
    }
    elseif ($dvd.Path -ne $IsoPath)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Set DVD drive ISO to '$IsoPath'"))
        {
            Set-VMDvdDrive `
                -VMName $Name `
                -ControllerNumber $dvd.ControllerNumber `
                -ControllerLocation $dvd.ControllerLocation `
                -Path $IsoPath
        }
    }

    $dvdDrive = Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($dvdDrive -and $PSCmdlet.ShouldProcess($Name, "Set first boot device to DVD drive"))
    {
        Set-VMFirmware -VMName $Name -FirstBootDevice $dvdDrive
    }
}
else
{
    Write-Host "Leaving ISO / boot order untouched (existing VM). Pass -Reinstall to re-arm the installer." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------
# Secure Boot (Always Disabled)
# ---------------------------------------------------------------------

if ($PSCmdlet.ShouldProcess($Name, "Disable Secure Boot"))
{
    Set-VMFirmware `
        -VMName $Name `
        -EnableSecureBoot Off
}

# ---------------------------------------------------------------------
# Virtual TPM
# ---------------------------------------------------------------------

if ($EnableTPM)
{
    $vmSecurity = Get-VMSecurity -VMName $Name -ErrorAction SilentlyContinue

    if (-not $vmSecurity -or -not $vmSecurity.TpmEnabled)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Enable Virtual TPM"))
        {
            Write-Host "Enabling Virtual TPM for '$Name'..." -ForegroundColor Cyan
            Set-VMKeyProtector -VMName $Name -NewLocalKeyProtector
            Enable-VMTPM -VMName $Name
        }
    }
}

# ---------------------------------------------------------------------
# Ensure Correct Switch
# ---------------------------------------------------------------------

$adapter = Get-VMNetworkAdapter -VMName $Name -ErrorAction SilentlyContinue | Select-Object -First 1

if ($adapter -and $adapter.SwitchName -ne $SwitchName)
{
    if ($PSCmdlet.ShouldProcess($Name, "Connect network adapter to switch '$SwitchName'"))
    {
        Connect-VMNetworkAdapter `
            -VMName $Name `
            -SwitchName $SwitchName
    }
}

# ---------------------------------------------------------------------
# MAC Address Spoofing (Required for Proxmox nested VM networking)
# ---------------------------------------------------------------------

$adapter = Get-VMNetworkAdapter -VMName $Name -ErrorAction SilentlyContinue | Select-Object -First 1

if ($adapter -and -not $adapter.MacAddressSpoofing)
{
    if ($PSCmdlet.ShouldProcess($Name, "Enable MAC Address Spoofing"))
    {
        Write-Host "Enabling MAC Address Spoofing for '$Name'..." -ForegroundColor Cyan
        Set-VMNetworkAdapter `
            -VMName $Name `
            -MacAddressSpoofing On
    }
}

# ---------------------------------------------------------------------
# Pre-OS Install Checkpoint  (first-create or -Reinstall only)
# ---------------------------------------------------------------------

if ($applyIso)
{
    $checkpointName = "pre-os-install"
    $snapshot = Get-VMSnapshot -VMName $Name -Name $checkpointName -ErrorAction SilentlyContinue

    if (-not $snapshot)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Create checkpoint '$checkpointName'"))
        {
            Write-Host "Creating checkpoint '$checkpointName'..." -ForegroundColor Cyan
            Checkpoint-VM -Name $Name -SnapshotName $checkpointName
        }
    }
    else
    {
        Write-Host "Checkpoint '$checkpointName' already exists." -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------
# Summary Output
# ---------------------------------------------------------------------

Write-Host ""
Write-Host "=====================================" -ForegroundColor Green
Write-Host "VM Configuration Summary" -ForegroundColor Green
Write-Host "=====================================" -ForegroundColor Green

Get-VM -Name $Name |
    Select-Object `
        Name,
        State,
        Generation,
        ProcessorCount,
        @{Name = "MemoryStartupGB"; Expression = { $_.MemoryStartup / 1GB } },
        AutomaticStartAction,
        AutomaticStopAction,
        AutomaticCheckpointsEnabled,
        CheckpointType |
    Format-List

Get-VMProcessor -VMName $Name |
    Select-Object Count, ExposeVirtualizationExtensions |
    Format-List

Get-VMSecurity -VMName $Name |
    Select-Object TpmEnabled |
    Format-List

Get-VMIntegrationService -VMName $Name |
    Select-Object Name, Enabled |
    Format-Table -AutoSize

Get-VMSnapshot -VMName $Name |
    Select-Object Name, CreationTime |
    Format-Table -AutoSize

# ---------------------------------------------------------------------
# Start VM
# ---------------------------------------------------------------------

if ($Start)
{
    $startVm = Get-VM -Name $Name -ErrorAction SilentlyContinue

    if ($startVm -and $startVm.State -eq 'Running')
    {
        Write-Host "VM '$Name' is already running." -ForegroundColor Yellow
    }
    elseif ($PSCmdlet.ShouldProcess($Name, "Start VM"))
    {
        Write-Host "Starting VM '$Name'..." -ForegroundColor Cyan
        Start-VM -Name $Name
    }
}
