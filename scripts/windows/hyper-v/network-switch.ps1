#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates (or verifies) a Hyper-V Internal switch and assigns a static IP
    to the host's virtual adapter so VMs on the switch have a gateway.

.NOTES
    Run this in an elevated PowerShell session.
#>

param(
    [string]$SwitchName = "HomelabTesting",
    [string]$HostIPAddress = "10.0.0.1",
    [int]$PrefixLength = 24,
    [string]$Subnet = "10.0.0.0/24",
    [string]$NatName = "HomelabTestingNAT"
)

$ErrorActionPreference = "Stop"

# Create switch
$switch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue

if (-not $switch)
{
    Write-Host "Creating switch..." -ForegroundColor Cyan
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
} else
{
    Write-Host "Switch already exists."
}

$adapterAlias = "vEthernet ($SwitchName)"

# Wait for adapter
for ($i = 0; $i -lt 20; $i++)
{
    $adapter = Get-NetAdapter -Name $adapterAlias -ErrorAction SilentlyContinue
    if ($adapter)
    { break 
    }
    Start-Sleep -Seconds 1
}

if (-not $adapter)
{
    throw "Could not find $adapterAlias"
}

# Remove existing IPv4 addresses except APIPA
Get-NetIPAddress `
    -InterfaceAlias $adapterAlias `
    -AddressFamily IPv4 `
    -ErrorAction SilentlyContinue |
    Where-Object {$_.IPAddress -notlike "169.254.*"} |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

# Assign gateway IP
New-NetIPAddress `
    -InterfaceAlias $adapterAlias `
    -IPAddress $HostIPAddress `
    -PrefixLength $PrefixLength `
    -ErrorAction SilentlyContinue | Out-Null

# Remove old NAT if necessary
$nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue

if (-not $nat)
{
    Write-Host "Creating NAT..." -ForegroundColor Cyan
    New-NetNat `
        -Name $NatName `
        -InternalIPInterfaceAddressPrefix $Subnet | Out-Null
} else
{
    Write-Host "NAT already exists."
}

Write-Host ""
Write-Host "====================================="
Write-Host "Switch created successfully"
Write-Host "====================================="
Write-Host "Switch : $SwitchName"
Write-Host "Gateway: $HostIPAddress"
Write-Host "Subnet : $Subnet"
Write-Host ""
Write-Host "Configure guests as:"
Write-Host "  IP:      10.0.0.x"
Write-Host "  Mask:    255.255.255.0"
Write-Host "  Gateway: $HostIPAddress"
Write-Host "  DNS:     1.1.1.1 or 8.8.8.8"
Write-Host ""
Write-Host "Configure guests as:"
Write-Host "  IP:      10.0.0.x"
Write-Host "  Mask:    255.255.255.0"
Write-Host "  Gateway: $HostIPAddress"
Write-Host "  DNS:     1.1.1.1 or 8.8.8.8"
Write-Host ""
Write-Host "Configure guests as:"
Write-Host "  IP:      10.0.0.x"
Write-Host "  Mask:    255.255.255.0"
Write-Host "  Gateway: $HostIPAddress"
Write-Host "  DNS:     1.1.1.1 or 8.8.8.8"
Write-Host ""
Write-Host "Configure guests as:"
Write-Host "  IP:      10.0.0.x"
Write-Host "  Mask:    255.255.255.0"
Write-Host "  Gateway: $HostIPAddress"
Write-Host "  DNS:     1.1.1.1 or 8.8.8.8"
