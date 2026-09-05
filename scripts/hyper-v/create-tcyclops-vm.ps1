#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates or updates the tcyclops Hyper-V test VM idempotently.

.DESCRIPTION
    Creates a Generation 2 Hyper-V VM if it does not exist, or reconciles its
    configuration if it already exists. Intended for running Proxmox VE nested.

    Most settings below (vCPU count, nested virtualization, static memory,
    firmware, TPM) can only be changed while the VM is in the Off state. If the
    VM is running the script stops with a clear message; pass -Force to have it
    stopped automatically.

    The install ISO is only attached and the DVD only made the first boot
    device when the VM is first created, or when -Reinstall is given. This
    prevents a re-run from silently re-triggering the unattended installer
    (which would wipe the disk) on an already-provisioned VM.

.PARAMETER IsoPath
    Path to the autoinstall ISO to mount in the VM's DVD drive.

.PARAMETER Force
    Stop the VM if it is running so offline-only settings can be applied.

.PARAMETER Reinstall
    Re-attach the ISO and set the DVD as first boot device even on an existing
    VM. WARNING: on next boot this re-runs the unattended installer.

.PARAMETER EnableGuestServiceInterface
    Also enable the "Guest Service Interface" integration service (host to
    guest file copy). Left disabled by default.

.NOTES
    Run in an elevated PowerShell session (Administrator).
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$IsoPath,

    [switch]$Force,

    [switch]$Reinstall,

    [switch]$EnableGuestServiceInterface
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------
# Desired Configuration
# ---------------------------------------------------------------------

$Name = "tcyclops.homelab.zezura.cc"

$Generation = 2

$MemoryStartup = 8GB
$CPUCount = 4

$SwitchName = "Homelab"
$HostIPAddress = "10.0.0.1"
$PrefixLength = 24
$Subnet = "10.0.0.0/24"
$NatName = "HomelabNAT"

$VMPath = "E:\Hyper-V VMs"
$VHDDirectory = Join-Path $VMPath "$Name\Virtual Hard Disks"
$VHDPath = Join-Path $VHDDirectory "$Name.vhdx"
$VHDSize = 256GB
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

# ---------------------------------------------------------------------
# Network Switch & NAT Setup (10.0.0.0/24)
# ---------------------------------------------------------------------

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
                Write-Host "Assigning IP $HostIPAddress to $adapterAlias..." -ForegroundColor Cyan

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

    $nat = Get-NetNat -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq $NatName -or $_.InternalIPInterfaceAddressPrefix -eq $Subnet
    }

    if (-not $nat)
    {
        if ($PSCmdlet.ShouldProcess($NatName, "Create NAT Network ($Subnet)"))
        {
            Write-Host "Creating NAT Network '$NatName' ($Subnet)..." -ForegroundColor Cyan
            New-NetNat `
                -Name $NatName `
                -InternalIPInterfaceAddressPrefix $Subnet | Out-Null
        }
    }
    else
    {
        Write-Host "NAT Network for '$Subnet' already exists ('$($nat.Name)')." -ForegroundColor Yellow
    }
}

Initialize-NetworkSwitch

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

$vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
$vmIsNew = $false

if (-not $vm)
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

        $vm = New-VM `
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
    if ($vm.Generation -ne $Generation)
    {
        throw "VM '$Name' already exists but is Generation $($vm.Generation). This script requires a Generation $Generation VM."
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
    if ($Force)
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

$applyIso = $vmIsNew -or $Reinstall

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
