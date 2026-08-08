#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Enable forwarding on WSL and Homelab switches.

.DESCRIPTION
    Enables forwarding on WSL and Homelab switches to allow communication
    from a WSL instance and a hyper-v VM on the Homelab network.

.NOTES
    Run in an elevated PowerShell session (Administrator).
#>

Set-NetIPInterface -InterfaceAlias "vEthernet (WSL (Hyper-V firewall))" -Forwarding Enabled
Set-NetIPInterface -InterfaceAlias "vEthernet (Homelab)" -Forwarding Enabled
