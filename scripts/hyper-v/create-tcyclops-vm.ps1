#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates or updates a Hyper-V VM idempotently.

.DESCRIPTION
    Creates a Generation 2 Hyper-V VM if it does not exist, or updates its
    configuration if it already exists. Intended for running Proxmox VE.

.PARAMETER IsoPath
    Path to an ISO file to mount in the VM's DVD drive.

.NOTES
    Run in an elevated PowerShell session (Administrator).
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$IsoPath
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

$EnableTPM = $true

# ---------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------

function Assert-Prerequisites
{
    if (-not (Get-Module -ListAvailable Hyper-V))
    {
        throw "Hyper-V PowerShell module is not installed."
    }

    if ($IsoPath -and -not (Test-Path $IsoPath))
    {
        throw "ISO not found: $IsoPath"
    }
}

Assert-Prerequisites

# ---------------------------------------------------------------------
# Network Switch & NAT Setup (10.0.0.0/24)
# ---------------------------------------------------------------------

function Ensure-NetworkSwitch
{
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

    if ($adapter)
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

                New-NetIPAddress `
                    -InterfaceAlias $adapterAlias `
                    -IPAddress $HostIPAddress `
                    -PrefixLength $PrefixLength `
                    -ErrorAction SilentlyContinue | Out-Null
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

Ensure-NetworkSwitch

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

if (-not $vm)
{
    if (Test-Path $VHDPath)
    {
        throw "VHD already exists but VM does not: $VHDPath"
    }

    if ($PSCmdlet.ShouldProcess($Name, "Create 256GB Dynamic VHD and Generation 2 VM"))
    {
        Write-Host "Creating 256GB Dynamic VHD..." -ForegroundColor Cyan
        New-VHD -Path $VHDPath -SizeBytes $VHDSize -Dynamic | Out-Null

        Write-Host "Creating Generation 2 VM '$Name'..." -ForegroundColor Cyan

        $vm = New-VM `
            -Name $Name `
            -Generation 2 `
            -Path $VMPath `
            -SwitchName $SwitchName `
            -MemoryStartupBytes $MemoryStartup `
            -VHDPath $VHDPath
    }
}
else
{
    if ($vm.Generation -ne 2)
    {
        throw "VM '$Name' already exists but is Generation $($vm.Generation). This script requires a Generation 2 VM."
    }

    Write-Host "VM '$Name' already exists (Generation 2). Ensuring configuration..." -ForegroundColor Yellow
}

# Verify VM exists before proceeding with configuration (e.g. if skipped in WhatIf mode)
$targetVm = Get-VM -Name $Name -ErrorAction SilentlyContinue

if (-not $targetVm)
{
    Write-Host "VM '$Name' does not exist (WhatIf mode or creation skipped). Skipping configuration steps." -ForegroundColor Yellow
    return
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

$disabledServices = Get-VMIntegrationService -VMName $Name -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled }

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
# DVD / ISO
# ---------------------------------------------------------------------

if ($IsoPath)
{
    $dvd = Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $dvd)
    {
        if ($PSCmdlet.ShouldProcess($Name, "Add DVD drive with ISO '$IsoPath'"))
        {
            $dvd = Add-VMDvdDrive -VMName $Name -Path $IsoPath -Passthru
        }
    }
    else
    {
        if ($dvd.Path -ne $IsoPath)
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
    }

    $dvdDrive = Get-VMDvdDrive -VMName $Name -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($dvdDrive -and $PSCmdlet.ShouldProcess($Name, "Set first boot device to DVD drive"))
    {
        Set-VMFirmware -VMName $Name -FirstBootDevice $dvdDrive
    }
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
# Pre-OS Install Checkpoint
# ---------------------------------------------------------------------

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
        @{Name = "MemoryStartupGB"; Expression = { $_.MemoryStartup / 1GB }},
        AutomaticStartAction,
        AutomaticStopAction,
        AutomaticCheckpointsEnabled,
        CheckpointType

Get-VMProcessor -VMName $Name |
    Select-Object Count, ExposeVirtualizationExtensions

Get-VMSecurity -VMName $Name |
    Select-Object TpmEnabled

Get-VMIntegrationService -VMName $Name |
    Select-Object Name, Enabled

Get-VMSnapshot -VMName $Name |
    Select-Object Name, CreationTime
