#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enable IPv4 forwarding on the WSL and Hyper-V lab switch interfaces.

.DESCRIPTION
    Lets a WSL2 instance route to Hyper-V VMs on the lab switch(es).

    The WSL vEthernet interface is recreated every time WSL restarts, which
    resets its forwarding flag, so re-run this after `wsl --shutdown`. The
    forwarding flag on the Hyper-V switch interface persists across reboots.

    The WSL adapter is discovered by pattern rather than hardcoded, so this
    works whether it is named "vEthernet (WSL)" or
    "vEthernet (WSL (Hyper-V firewall))".

.PARAMETER SwitchName
    Hyper-V virtual switch names whose host vEthernet interface should have
    forwarding enabled. Defaults to 'Homelab'.

.PARAMETER SkipWsl
    Do not touch the WSL vEthernet interface.

.NOTES
    Run in an elevated PowerShell session (Administrator).
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$SwitchName = @('Homelab'),
    [switch]$SkipWsl
)

$ErrorActionPreference = 'Stop'

function Enable-Forwarding
{
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory)] $Adapter)

    $ifaces = Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue

    if (-not $ifaces)
    {
        Write-Warning "No IPv4 interface for adapter '$($Adapter.Name)'; skipping."
        return
    }

    foreach ($iface in $ifaces)
    {
        if ($iface.Forwarding -eq 'Enabled')
        {
            Write-Host "Forwarding already enabled on '$($Adapter.Name)'." -ForegroundColor Yellow
            continue
        }

        if ($PSCmdlet.ShouldProcess($Adapter.Name, "Enable IPv4 forwarding"))
        {
            Set-NetIPInterface -InterfaceIndex $iface.InterfaceIndex -AddressFamily IPv4 -Forwarding Enabled
            Write-Host "Enabled forwarding on '$($Adapter.Name)'." -ForegroundColor Cyan
        }
    }
}

$adapters = [System.Collections.Generic.List[object]]::new()

foreach ($name in $SwitchName)
{
    $alias = "vEthernet ($name)"
    $found = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
    if ($found)
    {
        $adapters.Add($found)
    }
    else
    {
        Write-Warning "Adapter '$alias' not found (is the '$name' switch created?)."
    }
}

if (-not $SkipWsl)
{
    $wsl = Get-NetAdapter |
        Where-Object { $_.Name -like 'vEthernet (WSL*' -or $_.InterfaceDescription -like '*WSL*' }

    if ($wsl)
    {
        foreach ($w in $wsl) { $adapters.Add($w) }
    }
    else
    {
        Write-Warning "No WSL vEthernet adapter found (is WSL running?)."
    }
}

if ($adapters.Count -eq 0)
{
    throw "No target adapters found; nothing to do."
}

$adapters |
    Sort-Object -Property ifIndex -Unique |
    ForEach-Object { Enable-Forwarding -Adapter $_ }
