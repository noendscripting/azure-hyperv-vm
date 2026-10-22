<#
.SYNOPSIS
Prepares persistent guest storage, internal NAT, and a nested-VM boot test.
.DESCRIPTION
Runs elevated on the Azure host after Hyper-V installation and restart.
Discovers the non-OS SCSI LUN 0 disk, formats it only if RAW, and otherwise
requires the expected F: NTFS volume. Reuses matching networking configuration
and rejects conflicting storage/switch/IP/NAT settings rather than replacing them.
.OUTPUTS
HYPERV_CONFIG_OK after storage, NAT, and a temporary nested VM boot all pass.
.NOTES
192.168.100.0/24 must not overlap networks reachable through the VNet or VPN.
WinNAT provides translation only: guests still need static IP, gateway, and DNS.
Failures leave previously created storage/network configuration in place; there
is no destructive rollback of the data disk or existing guest VMs.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ((Get-WindowsFeature -Name Hyper-V).InstallState -ne 'Installed') {
    throw 'Hyper-V must be installed and the host restarted before configuration.'
}
if ((Get-Service -Name vmms).Status -ne 'Running') {
    throw 'The Hyper-V Virtual Machine Management service is not running.'
}

# The template pins SCSI and LUN 0; disk numbers and drive letters are not stable identifiers.
# Exclude boot/system disks even when they also advertise LUN 0. Azure's virtual
# SCSI controller can appear as either SCSI or SAS to the Windows storage stack.
$candidates = @(
    Get-CimInstance -ClassName Win32_DiskDrive |
        Where-Object { $_.SCSILogicalUnit -eq 0 } |
        ForEach-Object { Get-Disk -Number $_.Index } |
        Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and $_.BusType -in @('SCSI', 'SAS') }
)
if ($candidates.Count -ne 1) {
    throw "Expected exactly one non-OS SCSI disk at LUN 0; found $($candidates.Count). No disk was formatted."
}
$disk = $candidates[0]
if ($disk.IsOffline) {
    Set-Disk -Number $disk.Number -IsOffline $false
}
if ($disk.IsReadOnly) {
    Set-Disk -Number $disk.Number -IsReadOnly $false
}
$fPartition = @(Get-Partition | Where-Object { $_.DriveLetter -eq 'F' })
if ($fPartition.Count -gt 0 -and $fPartition[0].DiskNumber -ne $disk.Number) {
    throw 'F: is already used by another disk. No disk was formatted.'
}

# Only an uninitialized disk is eligible for formatting. GPT supports large
# disks; 64-KiB NTFS allocation units suit large VHDX files. A label/mount mismatch
# on a rerun requires operator action instead of guessing which data is disposable.
if ($disk.PartitionStyle -eq 'RAW') {
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
    New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter F |
        Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel HyperVData -Confirm:$false |
        Out-Null
} else {
    if ($fPartition.Count -ne 1) {
        throw 'The data disk is already initialized but not mounted at F:. Refusing to repartition it.'
    }
    $volume = Get-Volume -DriveLetter F
    if ($volume.FileSystem -ne 'NTFS' -or $volume.FileSystemLabel -ne 'HyperVData') {
        throw 'Existing F: is not the expected HyperVData NTFS volume. Refusing to format it.'
    }
}

# Defaults affect subsequently created VMs; they do not move any existing VM files.
$vmPath = 'F:\Hyper-V\VMs'
$vhdPath = 'F:\Hyper-V\Virtual Hard Disks'
New-Item -ItemType Directory -Path $vmPath, $vhdPath, 'F:\Hyper-V\ISO' -Force | Out-Null
Set-VMHost -VirtualMachinePath $vmPath -VirtualHardDiskPath $vhdPath

# Keep Azure's physical/virtual NIC outside the Hyper-V switch. Nested guests use
# an internal L2 segment and NAT instead of exposing their MACs to the Azure fabric.
$switchName = 'NestedNAT'
$natName = 'NestedNAT'
$gateway = '192.168.100.1'
$prefix = '192.168.100.0/24'
$switch = Get-VMSwitch | Where-Object { $_.Name -eq $switchName }
if ($switch -and $switch.SwitchType -ne 'Internal') {
    throw "Existing switch '$switchName' is not Internal. Refusing to replace it."
}
if (-not $switch) {
    New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
}
$adapter = Get-NetAdapter -Name "vEthernet ($switchName)"
$addresses = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceIndex -eq $adapter.ifIndex })
# Ignore transient APIPA addresses, but never replace a deliberate host address.
# No gateway is assigned here: the Azure NIC must remain the host's default route.
$conflicts = @($addresses | Where-Object {
    $_.IPAddress -notlike '169.254.*' -and ($_.IPAddress -ne $gateway -or $_.PrefixLength -ne 24)
})
if ($conflicts.Count -gt 0) {
    throw "Unexpected IPv4 configuration on '$switchName'. Refusing to replace it."
}
if (-not ($addresses | Where-Object { $_.IPAddress -eq $gateway -and $_.PrefixLength -eq 24 })) {
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $gateway -PrefixLength 24 | Out-Null
}

# WinNAT supports one internal NAT prefix per host; do not break an existing HNS/containers NAT.
$nats = @(Get-NetNat)
$otherNats = @($nats | Where-Object { $_.Name -ne $natName })
if ($otherNats.Count -gt 0) {
    throw "Another WinNAT configuration exists: $($otherNats.Name -join ', '). Resolve the conflict before continuing."
}
$nat = $nats | Where-Object { $_.Name -eq $natName }
if ($nat -and $nat.InternalIPInterfaceAddressPrefix -ne $prefix) {
    throw "Existing NAT '$natName' does not use $prefix. Refusing to replace it."
}
if (-not $nat) {
    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $prefix | Out-Null
}

# Read back settings rather than treating successful setter calls as verification.
$hostConfiguration = Get-VMHost
if ($hostConfiguration.VirtualMachinePath -ne $vmPath -or $hostConfiguration.VirtualHardDiskPath -ne $vhdPath) {
    throw 'Hyper-V default storage paths did not persist.'
}
if (-not (Get-NetNat -Name $natName).Active) {
    throw 'The nested VM NAT is not active.'
}

# Starting a diskless VM checks the nested hypervisor, not just whether the role is installed.
$testName = "HyperV-Validation-$([guid]::NewGuid().ToString('N'))"
$testVM = $null
try {
    $testVM = New-VM -Name $testName -Generation 2 -MemoryStartupBytes 256MB -NoVHD -SwitchName $switchName -Path $vmPath
    Start-VM -VM $testVM
    if ((Get-VM -Name $testName).State -ne 'Running') {
        throw 'The nested virtualization test VM failed to start.'
    }
} finally {
    # Clean only the uniquely named diskless probe, including on failed startup.
    # Do not enumerate/delete unrelated VM directories or any guest VHDX files.
    if ($testVM) {
        $currentVM = Get-VM -Name $testName
        if ($currentVM.State -ne 'Off') {
            Stop-VM -VM $currentVM -TurnOff -Force
        }
        Remove-VM -VM $testVM -Force
        $testDirectory = Join-Path $vmPath $testName
        if (Test-Path -LiteralPath $testDirectory) {
            Remove-Item -LiteralPath $testDirectory -Recurse -Force
        }
    }
}

# Booting a diskless probe validates nesting, not guest OS installation or egress.
Write-Output 'HYPERV_CONFIG_OK: F:\Hyper-V; NestedNAT; 192.168.100.1/24; nested VM boot passed.'
