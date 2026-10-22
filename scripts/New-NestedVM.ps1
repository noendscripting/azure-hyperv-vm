<#
.SYNOPSIS
Creates and starts one Gen2 nested VM using an operator-supplied OS ISO.
.DESCRIPTION
Run elevated on the configured Hyper-V host. Creates VM files only under the
validated F: defaults and connects the guest to NestedNAT. OS installation and
licensing are manual; no guest IP address or Azure resource is created here.
.PARAMETER Name
Unique Hyper-V VM name and VHDX filename stem; existing files are never replaced.
.PARAMETER IsoPath
Path on the host to a licensed installation ISO; it is not downloaded.
.PARAMETER GuestOS
Selects the Windows or Linux Secure Boot certificate template, not the OS image.
.PARAMETER ProcessorCount
Virtual processors for this guest. Budget total guest allocations against the host.
.PARAMETER MemoryGB
Fixed startup RAM in GiB. Leave sufficient memory for the Windows host.
.PARAMETER DiskSizeGB
Maximum capacity of the dynamically expanding guest VHDX, not preallocated space.
.PARAMETER EnableVTPM
Opts into a virtual TPM for this Gen2 guest using a new local key protector.
The protector and vTPM are configured and verified while the guest is powered off.
Omitting this switch leaves the existing default behavior unchanged.
.OUTPUTS
Instructions for completing OS installation and assigning static guest networking.
.NOTES
If later configuration fails, the partly created VM is retained for inspection.
After installation, remove the ISO or change boot order before future restarts.
The local key protector depends on this Hyper-V host's key material. Plan key
backup/transfer before migrating or restoring a vTPM VM to another host, and retain
guest BitLocker recovery keys separately. This is not an HGS/shielded-VM setup.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$')]
    [string] $Name,

    [Parameter(Mandatory)]
    [string] $IsoPath,

    [ValidateSet('Windows', 'Linux')]
    [string] $GuestOS = 'Windows',

    [ValidateRange(1, 4)]
    [int] $ProcessorCount = 2,

    [ValidateRange(1, 16)]
    [int] $MemoryGB = 8,

    [ValidateRange(16, 1024)]
    [int] $DiskSizeGB = 64,

    [switch] $EnableVTPM
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
    throw "Guest installation ISO not found: $IsoPath"
}
$switch = Get-VMSwitch -Name NestedNAT
if ($switch.SwitchType -ne 'Internal' -or -not (Get-NetNat -Name NestedNAT).Active) {
    throw 'NestedNAT must be an internal switch with active WinNAT. Run Configure-HyperV.ps1 first.'
}
# Do not silently fall back to C: if the data-volume configuration was skipped.
$hostConfiguration = Get-VMHost
if ($hostConfiguration.VirtualMachinePath -ne 'F:\Hyper-V\VMs' -or
    $hostConfiguration.VirtualHardDiskPath -ne 'F:\Hyper-V\Virtual Hard Disks') {
    throw 'Hyper-V default storage paths are not configured on F:.'
}
if (Get-VM | Where-Object { $_.Name -eq $Name }) {
    throw "VM '$Name' already exists."
}
# Check both Hyper-V inventory and on-disk artifacts left by earlier attempts.
$vhdPath = Join-Path $hostConfiguration.VirtualHardDiskPath "$Name.vhdx"
$vmDirectory = Join-Path $hostConfiguration.VirtualMachinePath $Name
if ((Test-Path -LiteralPath $vhdPath) -or (Test-Path -LiteralPath $vmDirectory)) {
    throw 'VM files already exist. Refusing to overwrite them.'
}

# NewVHDSizeBytes creates a dynamic VHDX: physical usage grows with guest writes,
# so provisioned guest capacities can exceed free space unless the operator budgets it.
$vm = New-VM -Name $Name -Generation 2 -MemoryStartupBytes ($MemoryGB * 1GB) `
    -Path $hostConfiguration.VirtualMachinePath -NewVHDPath $vhdPath `
    -NewVHDSizeBytes ($DiskSizeGB * 1GB) -SwitchName NestedNAT
Set-VMProcessor -VM $vm -Count $ProcessorCount
Set-VMMemory -VM $vm -DynamicMemoryEnabled $false
# Common signed Linux bootloaders use the third-party UEFI CA, not the Windows CA.
$secureBootTemplate = if ($GuestOS -eq 'Linux') { 'MicrosoftUEFICertificateAuthority' } else { 'MicrosoftWindows' }
Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate $secureBootTemplate
if ($EnableVTPM) {
    # A local protector avoids requiring Host Guardian Service for this lab VM.
    # Configure it before the first boot; never silently start an unprotected
    # guest when vTPM was explicitly requested.
    Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
    Enable-VMTPM -VM $vm
    if (-not (Get-VMSecurity -VM $vm).TpmEnabled) {
        throw "Virtual TPM did not become enabled for '$Name'. The VM has not been started."
    }
    Write-Warning 'vTPM uses a local key protector. Preserve host key material and guest recovery keys before moving/restoring this VM to another host.'
}
Add-VMDvdDrive -VM $vm -Path $IsoPath
Set-VMFirmware -VM $vm -FirstBootDevice (Get-VMDvdDrive -VM $vm)
Start-VM -VM $vm
Write-Output "Created '$Name' on F: and connected it to NestedNAT. Install the guest OS using VMConnect."
Write-Output 'Guest network: unused 192.168.100.2-254/24 address, gateway 192.168.100.1, DNS 1.1.1.1 and 8.8.8.8. No DHCP is provided.'
