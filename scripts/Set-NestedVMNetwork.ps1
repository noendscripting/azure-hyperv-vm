<#
.SYNOPSIS
Assigns a Windows nested guest's static NAT-network settings via PowerShell Direct.
.DESCRIPTION
Run elevated on the Hyper-V host after installing Windows in the guest.
PowerShell Direct uses the host/guest boundary, so no working guest IP connection
is needed. Existing conflicting addresses or gateways are rejected, not removed.
.PARAMETER VMName
Running Windows guest with exactly one Hyper-V NIC attached to NestedNAT.
.PARAMETER IPAddress
Unused address in 192.168.100.2-254. The regex excludes network, gateway, and
broadcast addresses; the operator must prevent duplicates, including offline VMs.
.PARAMETER GuestCredential
Administrator credentials inside this guest, not the Azure host's credentials.
.OUTPUTS
Guest IP configuration and a message after DNS/outbound TCP 443 validation passes.
.NOTES
Not a Linux network helper. WinNAT has no DHCP/DNS service; this script explicitly
sets a /24 prefix, 192.168.100.1 gateway, and public recursive DNS servers.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $VMName,

    [Parameter(Mandatory)]
    [ValidatePattern('^192\.168\.100\.(?:[2-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])$')]
    [string] $IPAddress,

    [Parameter(Mandatory)]
    [pscredential] $GuestCredential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$vm = Get-VM -Name $VMName
if ($vm.State -ne 'Running') {
    throw "VM '$VMName' must be running with Windows installed."
}
$adapters = @(Get-VMNetworkAdapter -VM $vm)
if ($adapters.Count -ne 1 -or $adapters[0].SwitchName -ne 'NestedNAT') {
    throw 'Expected exactly one guest NIC connected to NestedNAT.'
}

# PowerShell Direct needs no guest network and avoids opening WinRM or guest ports in Azure.
Invoke-Command -VMName $VMName -Credential $GuestCredential -ArgumentList $IPAddress -ScriptBlock {
    # This block runs inside the guest. Its strict/error preferences and supplied
    # address are established locally rather than relying on the host session.
    param([string] $Address)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $nics = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
    if ($nics.Count -ne 1) {
        throw 'Expected exactly one active guest network adapter.'
    }
    $index = $nics[0].ifIndex
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceIndex -eq $index })
    # APIPA is expected before static configuration; deliberate existing IPv4
    # settings are not safe to overwrite just because the NIC is on NestedNAT.
    $conflicts = @($addresses | Where-Object {
        $_.IPAddress -notlike '169.254.*' -and ($_.IPAddress -ne $Address -or $_.PrefixLength -ne 24)
    })
    if ($conflicts.Count -gt 0) {
        throw 'The guest already has a different IPv4 configuration. Resolve it explicitly before running this helper.'
    }
    $routes = @(Get-NetRoute -AddressFamily IPv4 | Where-Object {
        $_.InterfaceIndex -eq $index -and $_.DestinationPrefix -eq '0.0.0.0/0'
    })
    if ($routes | Where-Object { $_.NextHop -ne '192.168.100.1' }) {
        throw 'The guest already has a different default gateway.'
    }
    # Reuse an already-correct IP/default route so reruns do not create duplicates.
    # DHCP must be disabled because the internal WinNAT switch has no DHCP server.
    Set-NetIPInterface -InterfaceIndex $index -AddressFamily IPv4 -Dhcp Disabled
    if (-not ($addresses | Where-Object { $_.IPAddress -eq $Address -and $_.PrefixLength -eq 24 })) {
        New-NetIPAddress -InterfaceIndex $index -IPAddress $Address -PrefixLength 24 | Out-Null
    }
    if ($routes.Count -eq 0) {
        New-NetRoute -InterfaceIndex $index -DestinationPrefix '0.0.0.0/0' -NextHop '192.168.100.1' | Out-Null
    }
    Set-DnsClientServerAddress -InterfaceIndex $index -ServerAddresses '1.1.1.1', '8.8.8.8'
    Get-NetIPConfiguration -InterfaceIndex $index
    # A hostname/TCP test exercises DNS plus routed/NATed outbound access. A failed
    # probe can also reflect an organizational egress policy, not necessarily bad NAT.
    if (-not (Test-NetConnection -ComputerName www.microsoft.com -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        throw 'Guest outbound DNS/TCP 443 validation failed. Check guest settings, host NAT, NSG, and upstream connectivity.'
    }
    Write-Output 'Guest static IP, gateway, DNS, and outbound TCP 443 validation passed.'
}
