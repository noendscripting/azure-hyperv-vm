<#
.SYNOPSIS
Offline Pester coverage for the ARM contract and host/guest safety checks.
.DESCRIPTION
Mocks Hyper-V, Windows storage, networking, and guest remoting. No disk is
formatted and no VM is created. Test descriptions name the expected behavior;
mock invocation filters assert the exact target, prefix, and destructive action.
.NOTES
Run with Invoke-Pester -Path .\tests. These mocks do not prove Azure allocation,
real hypervisor startup, or Internet availability. The Standard-security
assertion records the original contract and will fail if the template differs.
#>
BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:template = Get-Content -Raw (Join-Path $script:root 'azuredeploy.json') | ConvertFrom-Json
    $source = Get-Content -Raw (Join-Path $script:root 'scripts\Configure-HyperV.ps1')
    # Only the mocked harness omits elevation requirements; production scripts retain them.
    $script:configure = [scriptblock]::Create(($source -replace '(?m)^#Requires.*$', ''))
    $guestSource = Get-Content -Raw (Join-Path $script:root 'scripts\Set-NestedVMNetwork.ps1')
    $script:guestNetwork = [scriptblock]::Create(($guestSource -replace '(?m)^#Requires.*$', ''))

    # Stubs make Windows-only cmdlets mockable on a workstation without Hyper-V.
    # Production scripts retain their native commands and elevation requirements.
    function Get-WindowsFeature { param($Name) }
    function Get-Service { param($Name) }
    function Get-CimInstance { param($ClassName) }
    function Get-Disk { param($Number) }
    function Set-Disk { param($Number, $IsOffline, $IsReadOnly) }
    function Get-Partition { }
    function Initialize-Disk { param($Number, $PartitionStyle) }
    function New-Partition { param($DiskNumber, [switch]$UseMaximumSize, $DriveLetter) }
    function Format-Volume { [CmdletBinding(SupportsShouldProcess)] param($FileSystem, $AllocationUnitSize, $NewFileSystemLabel, [Parameter(ValueFromPipeline)]$InputObject) }
    function Get-Volume { param($DriveLetter) }
    function Set-VMHost { param($VirtualMachinePath, $VirtualHardDiskPath) }
    function Get-VMHost { }
    function Get-VMSwitch { param($Name) }
    function New-VMSwitch { param($Name, $SwitchType) }
    function Get-NetAdapter { param($Name) }
    function Get-NetIPAddress { param($AddressFamily) }
    function New-NetIPAddress { param($InterfaceIndex, $IPAddress, $PrefixLength) }
    function Get-NetNat { param($Name) }
    function New-NetNat { param($Name, $InternalIPInterfaceAddressPrefix) }
    function New-VM { param($Name, $Generation, $MemoryStartupBytes, [switch]$NoVHD, $SwitchName, $Path) }
    function Start-VM { param($VM) }
    function Get-VM { param($Name) }
    function Stop-VM { param($VM, [switch]$TurnOff, [switch]$Force) }
    function Remove-VM { param($VM, [switch]$Force) }
    function Get-VMNetworkAdapter { param($VM) }
    function Get-NetRoute { param($AddressFamily) }
    function New-NetRoute { param($InterfaceIndex, $DestinationPrefix, $NextHop) }
    function Set-NetIPInterface { param($InterfaceIndex, $AddressFamily, $Dhcp) }
    function Set-DnsClientServerAddress { param($InterfaceIndex, $ServerAddresses) }
    function Get-NetIPConfiguration { param($InterfaceIndex) }
    function Test-NetConnection { [CmdletBinding()] param($ComputerName, $Port, $InformationLevel) }
}

Describe 'Windows guest static networking through PowerShell Direct' {
    BeforeEach {
        # Each test starts with an unconfigured guest (APIPA only). Credentials
        # are synthetic, never used to connect to any live host or VM.
        $script:credential = [pscredential]::new(
            'guestadmin', (ConvertTo-SecureString ([guid]::NewGuid().ToString()) -AsPlainText -Force)
        )
        $script:guestAddresses = @(
            [pscustomobject]@{ InterfaceIndex = 42; IPAddress = '169.254.1.2'; PrefixLength = 16 }
        )
        $script:guestRoutes = @()
        Mock Get-VM { [pscustomobject]@{ State = 'Running' } }
        Mock Get-VMNetworkAdapter { [pscustomobject]@{ SwitchName = 'NestedNAT' } }
        # Execute the guest block locally against mocks so its route/IP guards
        # are exercised, rather than replacing the entire remoting result.
        Mock Invoke-Command { & $ScriptBlock @ArgumentList }
        Mock Get-NetAdapter { [pscustomobject]@{ ifIndex = 42; Status = 'Up' } }
        Mock Get-NetIPAddress { $script:guestAddresses }
        Mock Get-NetRoute { $script:guestRoutes }
        Mock New-NetIPAddress { }
        Mock New-NetRoute { }
        Mock Set-NetIPInterface { }
        Mock Set-DnsClientServerAddress { }
        Mock Get-NetIPConfiguration { }
        Mock Test-NetConnection { $true }
    }

    It 'sets the correct guest IP, gateway and DNS and verifies outbound TCP 443' {
        & $script:guestNetwork -VMName lab01 -IPAddress 192.168.100.10 -GuestCredential $script:credential |
            Should -Match 'outbound TCP 443 validation passed'
        Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter { $VMName -eq 'lab01' }
        Should -Invoke Set-NetIPInterface -Times 1 -Exactly -ParameterFilter { $Dhcp -eq 'Disabled' }
        Should -Invoke New-NetIPAddress -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 42 -and $IPAddress -eq '192.168.100.10' -and $PrefixLength -eq 24
        }
        Should -Invoke New-NetRoute -Times 1 -Exactly -ParameterFilter {
            $InterfaceIndex -eq 42 -and $DestinationPrefix -eq '0.0.0.0/0' -and $NextHop -eq '192.168.100.1'
        }
        Should -Invoke Set-DnsClientServerAddress -Times 1 -Exactly -ParameterFilter {
            ($ServerAddresses -join ',') -eq '1.1.1.1,8.8.8.8'
        }
        Should -Invoke Test-NetConnection -Times 1 -Exactly -ParameterFilter {
            $ComputerName -eq 'www.microsoft.com' -and $Port -eq 443
        }
    }

    It 'reuses an existing correct IP and route' {
        $script:guestAddresses = @(
            [pscustomobject]@{ InterfaceIndex = 42; IPAddress = '192.168.100.10'; PrefixLength = 24 }
        )
        $script:guestRoutes = @(
            [pscustomobject]@{ InterfaceIndex = 42; DestinationPrefix = '0.0.0.0/0'; NextHop = '192.168.100.1' }
        )
        & $script:guestNetwork -VMName lab01 -IPAddress 192.168.100.10 -GuestCredential $script:credential |
            Should -Match 'validation passed'
        Should -Invoke New-NetIPAddress -Times 0 -Exactly
        Should -Invoke New-NetRoute -Times 0 -Exactly
    }

    It 'rejects reserved or out-of-subnet guest address <Address>' -ForEach @(
        @{ Address = '192.168.100.0' },
        @{ Address = '192.168.100.1' },
        @{ Address = '192.168.100.255' },
        @{ Address = '10.20.0.10' }
    ) {
        { & $script:guestNetwork -VMName lab01 -IPAddress $Address -GuestCredential $script:credential } |
            Should -Throw '*IPAddress*'
        Should -Invoke Invoke-Command -Times 0 -Exactly
    }

    It 'fails explicitly on outbound errors instead of returning success' {
        Mock Test-NetConnection { $false }
        { & $script:guestNetwork -VMName lab01 -IPAddress 192.168.100.10 -GuestCredential $script:credential } |
            Should -Throw '*outbound DNS/TCP 443 validation failed*'
    }

    It 'refuses conflicting existing guest addresses before changing DHCP' {
        $script:guestAddresses = @(
            [pscustomobject]@{ InterfaceIndex = 42; IPAddress = '10.0.0.10'; PrefixLength = 24 }
        )
        { & $script:guestNetwork -VMName lab01 -IPAddress 192.168.100.10 -GuestCredential $script:credential } |
            Should -Throw '*different IPv4 configuration*'
        Should -Invoke Set-NetIPInterface -Times 0 -Exactly
    }

    It 'refuses conflicting default gateways' {
        $script:guestRoutes = @(
            [pscustomobject]@{ InterfaceIndex = 42; DestinationPrefix = '0.0.0.0/0'; NextHop = '192.168.100.254' }
        )
        { & $script:guestNetwork -VMName lab01 -IPAddress 192.168.100.10 -GuestCredential $script:credential } |
            Should -Throw '*different default gateway*'
        Should -Invoke New-NetRoute -Times 0 -Exactly
    }

    It 'rejects a guest connected to the wrong switch' {
        Mock Get-VMNetworkAdapter { [pscustomobject]@{ SwitchName = 'OtherSwitch' } }
        { & $script:guestNetwork -VMName lab01 -IPAddress 192.168.100.10 -GuestCredential $script:credential } |
            Should -Throw '*exactly one guest NIC*'
        Should -Invoke Invoke-Command -Times 0 -Exactly
    }
}

Describe 'Deployment contracts' {
    It 'parses all PowerShell scripts without errors' {
        foreach ($file in Get-ChildItem -Path $script:root -Filter *.ps1 -Recurse) {
            $tokens = $null
            $parseErrors = $null
            [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$tokens, [ref]$parseErrors
            ) | Out-Null
            @($parseErrors).Count | Should -Be 0 -Because $file.FullName
        }
    }

    It 'uses the requested VM, Server 2025 Gen2 and explicit Standard security' {
        $vm = $script:template.resources | Where-Object type -EQ 'Microsoft.Compute/virtualMachines'
        $script:template.parameters.virtualMachineSize.defaultValue | Should -Be 'Standard_D8s_v5'
        $script:template.parameters.imageSku.defaultValue | Should -Be '2025-datacenter-g2'
        $vm.properties.storageProfile.imageReference.sku | Should -Be "[parameters('imageSku')]"
        $vm.properties.storageProfile.imageReference.version | Should -Be "[parameters('imageVersion')]"
        $vm.properties.securityProfile.securityType | Should -Be 'Standard'
        $vm.properties.storageProfile.diskControllerType | Should -Be 'SCSI'
        $script:template.parameters.adminPassword.type | Should -Be 'securestring'
    }

    It 'creates exactly an SSD OS disk and one cheapest-tier HDD data disk at LUN 0' {
        $vm = $script:template.resources | Where-Object type -EQ 'Microsoft.Compute/virtualMachines'
        $vm.properties.storageProfile.osDisk.diskSizeGB | Should -Be 127
        $script:template.parameters.osDiskSku.defaultValue | Should -Be 'StandardSSD_LRS'
        $vm.properties.storageProfile.osDisk.managedDisk.storageAccountType | Should -Be "[parameters('osDiskSku')]"
        @($vm.properties.storageProfile.dataDisks).Count | Should -Be 1
        $data = $vm.properties.storageProfile.dataDisks[0]
        $data.lun | Should -Be 0
        $script:template.parameters.dataDiskSku.defaultValue | Should -Be 'Standard_LRS'
        $data.managedDisk.storageAccountType | Should -Be "[parameters('dataDiskSku')]"
        $data.caching | Should -Be 'None'
        $script:template.parameters.dataDiskSizeGB.defaultValue | Should -Be 256
    }

    It 'uses only a private NIC in an existing subnet without creating or changing the network' {
        @($script:template.resources).Count | Should -Be 2
        @($script:template.resources | Where-Object type -NotIn @(
            'Microsoft.Network/networkInterfaces', 'Microsoft.Compute/virtualMachines'
        )).Count | Should -Be 0
        $script:template.parameters.location.defaultValue | Should -Be 'centralus'
        foreach ($name in 'vnetResourceGroupName', 'vnetName', 'subnetName') {
            $script:template.parameters.PSObject.Properties.Name | Should -Contain $name
            $script:template.parameters.$name.PSObject.Properties.Name | Should -Not -Contain 'defaultValue'
        }
        $script:template.parameters.PSObject.Properties.Name | Should -Not -Contain 'rdpSourceAddressPrefix'
        $nic = $script:template.resources | Where-Object type -EQ 'Microsoft.Network/networkInterfaces'
        $nic.properties.enableIPForwarding | Should -BeFalse
        $nic.properties.enableAcceleratedNetworking | Should -BeTrue
        $nic.properties.ipConfigurations[0].properties.PSObject.Properties.Name |
            Should -Not -Contain 'publicIPAddress'
        $nic.properties.ipConfigurations[0].properties.subnet.id |
            Should -Be "[resourceId(parameters('vnetResourceGroupName'), 'Microsoft.Network/virtualNetworks/subnets', parameters('vnetName'), parameters('subnetName'))]"
        $script:template.outputs.PSObject.Properties.Name | Should -Contain 'privateIPAddress'
        $script:template.outputs.PSObject.Properties.Name | Should -Not -Contain 'rdpEndpoint'
    }
}

Describe 'Host storage, NAT and nested boot configuration' {
    BeforeEach {
        # Model both OS and data devices at LUN 0: excluding boot/system disks
        # must be part of selection, not an assumption that disk number 2 is data.
        $script:disk = [pscustomobject]@{
            Number = 2; IsBoot = $false; IsSystem = $false; BusType = 'SCSI'
            IsOffline = $false; IsReadOnly = $false; PartitionStyle = 'RAW'
        }
        $script:drives = @(
            [pscustomobject]@{ SCSILogicalUnit = 0; Index = 0 },
            [pscustomobject]@{ SCSILogicalUnit = 0; Index = 2 }
        )
        $script:partitions = @()
        $script:switches = @()
        $script:addresses = @()
        $script:nats = @()
        $script:paths = [pscustomobject]@{ VirtualMachinePath = ''; VirtualHardDiskPath = '' }
        $script:vmState = 'Off'

        Mock Get-WindowsFeature { [pscustomobject]@{ InstallState = 'Installed' } }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Get-CimInstance { $script:drives }
        Mock Get-Disk {
            if ($Number -eq 0) {
                [pscustomobject]@{ IsBoot = $true; IsSystem = $true; BusType = 'SCSI' }
            } else {
                $script:disk
            }
        }
        Mock Set-Disk { }
        Mock Get-Partition { $script:partitions }
        Mock Initialize-Disk { }
        Mock New-Partition { [pscustomobject]@{ DriveLetter = 'F' } }
        Mock Format-Volume { }
        Mock Get-Volume { [pscustomobject]@{ FileSystem = 'NTFS'; FileSystemLabel = 'HyperVData' } }
        Mock New-Item { }
        # Stateful setters make the script's read-back verification meaningful.
        # Every BeforeEach resets this state, so test order cannot mask a failure.
        Mock Set-VMHost {
            $script:paths = [pscustomobject]@{
                VirtualMachinePath = $VirtualMachinePath
                VirtualHardDiskPath = $VirtualHardDiskPath
            }
        }
        Mock Get-VMHost { $script:paths }
        Mock Get-VMSwitch { $script:switches }
        Mock New-VMSwitch {
            $script:switches = @([pscustomobject]@{ Name = $Name; SwitchType = $SwitchType })
        }
        Mock Get-NetAdapter { [pscustomobject]@{ ifIndex = 12 } }
        Mock Get-NetIPAddress { $script:addresses }
        Mock New-NetIPAddress {
            $script:addresses = @([pscustomobject]@{
                InterfaceIndex = $InterfaceIndex; IPAddress = $IPAddress; PrefixLength = $PrefixLength
            })
        }
        Mock Get-NetNat {
            if ($Name) { $script:nats | Where-Object Name -EQ $Name } else { $script:nats }
        }
        Mock New-NetNat {
            $script:nats = @([pscustomobject]@{
                Name = $Name; InternalIPInterfaceAddressPrefix = $InternalIPInterfaceAddressPrefix; Active = $true
            })
        }
        Mock New-VM { [pscustomobject]@{ Name = $Name } }
        Mock Start-VM { $script:vmState = 'Running' }
        Mock Get-VM { [pscustomobject]@{ Name = $Name; State = $script:vmState } }
        Mock Stop-VM { $script:vmState = 'Off' }
        Mock Remove-VM { }
        Mock Test-Path { $false }
        Mock Remove-Item { }
        # Only virtual F: paths are mocked; repository paths still resolve normally.
        Mock Join-Path { "$Path\$ChildPath" } -ParameterFilter { $Path -like 'F:\*' }
    }

    It 'formats only the LUN 0 data disk, creates internal NAT, and boots/cleans a test VM' {
        & $script:configure | Should -Match 'HYPERV_CONFIG_OK'
        Should -Invoke Initialize-Disk -Times 1 -Exactly -ParameterFilter { $Number -eq 2 -and $PartitionStyle -eq 'GPT' }
        Should -Invoke Format-Volume -Times 1 -Exactly -ParameterFilter {
            $FileSystem -eq 'NTFS' -and $AllocationUnitSize -eq 65536
        }
        Should -Invoke New-VMSwitch -Times 1 -Exactly -ParameterFilter { $SwitchType -eq 'Internal' }
        Should -Invoke New-NetIPAddress -Times 1 -Exactly -ParameterFilter {
            $IPAddress -eq '192.168.100.1' -and $PrefixLength -eq 24
        }
        Should -Invoke New-NetNat -Times 1 -Exactly -ParameterFilter {
            $InternalIPInterfaceAddressPrefix -eq '192.168.100.0/24'
        }
        Should -Invoke Start-VM -Times 1 -Exactly
        Should -Invoke Stop-VM -Times 1 -Exactly
        Should -Invoke Remove-VM -Times 1 -Exactly
    }

    It 'accepts SAS presentation of the SCSI controller data disk' {
        $script:disk.BusType = 'SAS'
        & $script:configure | Should -Match 'HYPERV_CONFIG_OK'
        Should -Invoke Initialize-Disk -Times 1 -Exactly -ParameterFilter { $Number -eq 2 }
    }

    It 'reuses existing correct data without formatting or recreating networking' {
        $script:disk.PartitionStyle = 'GPT'
        $script:partitions = @([pscustomobject]@{ DriveLetter = 'F'; DiskNumber = 2 })
        $script:switches = @([pscustomobject]@{ Name = 'NestedNAT'; SwitchType = 'Internal' })
        $script:addresses = @([pscustomobject]@{ InterfaceIndex = 12; IPAddress = '192.168.100.1'; PrefixLength = 24 })
        $script:nats = @([pscustomobject]@{
            Name = 'NestedNAT'; InternalIPInterfaceAddressPrefix = '192.168.100.0/24'; Active = $true
        })
        & $script:configure | Should -Match 'HYPERV_CONFIG_OK'
        Should -Invoke Initialize-Disk -Times 0 -Exactly
        Should -Invoke Format-Volume -Times 0 -Exactly
        Should -Invoke New-VMSwitch -Times 0 -Exactly
        Should -Invoke New-NetIPAddress -Times 0 -Exactly
        Should -Invoke New-NetNat -Times 0 -Exactly
    }

    It 'never formats the OS disk if the data disk is absent' {
        $script:drives = @([pscustomobject]@{ SCSILogicalUnit = 0; Index = 0 })
        { & $script:configure } | Should -Throw '*found 0*'
        Should -Invoke Initialize-Disk -Times 0 -Exactly
        Should -Invoke Format-Volume -Times 0 -Exactly
    }

    It 'refuses ambiguous LUN 0 disks' {
        $script:drives += [pscustomobject]@{ SCSILogicalUnit = 0; Index = 3 }
        { & $script:configure } | Should -Throw '*found 2*'
        Should -Invoke Format-Volume -Times 0 -Exactly
    }

    It 'refuses an occupied F drive before initializing the disk' {
        $script:partitions = @([pscustomobject]@{ DriveLetter = 'F'; DiskNumber = 7 })
        { & $script:configure } | Should -Throw '*F: is already used*'
        Should -Invoke Initialize-Disk -Times 0 -Exactly
    }

    It 'refuses to repartition an initialized disk without the expected mount' {
        $script:disk.PartitionStyle = 'GPT'
        { & $script:configure } | Should -Throw '*Refusing to repartition*'
        Should -Invoke Format-Volume -Times 0 -Exactly
    }

    It 'refuses an unexpected existing volume instead of formatting it' {
        $script:disk.PartitionStyle = 'GPT'
        $script:partitions = @([pscustomobject]@{ DriveLetter = 'F'; DiskNumber = 2 })
        Mock Get-Volume { [pscustomobject]@{ FileSystem = 'NTFS'; FileSystemLabel = 'UserData' } }
        { & $script:configure } | Should -Throw '*Refusing to format*'
        Should -Invoke Format-Volume -Times 0 -Exactly
    }

    It 'brings offline/read-only disks online before use' {
        $script:disk.IsOffline = $true
        $script:disk.IsReadOnly = $true
        & $script:configure | Should -Match 'HYPERV_CONFIG_OK'
        Should -Invoke Set-Disk -Times 1 -Exactly -ParameterFilter { $IsOffline -eq $false }
        Should -Invoke Set-Disk -Times 1 -Exactly -ParameterFilter { $IsReadOnly -eq $false }
    }

    It 'refuses external switches instead of disrupting the Azure NIC' {
        $script:switches = @([pscustomobject]@{ Name = 'NestedNAT'; SwitchType = 'External' })
        { & $script:configure } | Should -Throw '*not Internal*'
        Should -Invoke New-VMSwitch -Times 0 -Exactly
    }

    It 'rejects conflicting gateway addresses' {
        $script:addresses = @([pscustomobject]@{ InterfaceIndex = 12; IPAddress = '10.1.1.1'; PrefixLength = 24 })
        { & $script:configure } | Should -Throw '*Unexpected IPv4 configuration*'
        Should -Invoke New-NetIPAddress -Times 0 -Exactly
    }

    It 'ignores host NIC addresses on other interfaces' {
        $script:addresses = @([pscustomobject]@{ InterfaceIndex = 4; IPAddress = '10.20.0.4'; PrefixLength = 24 })
        & $script:configure | Should -Match 'HYPERV_CONFIG_OK'
        Should -Invoke New-NetIPAddress -Times 1 -Exactly
    }

    It 'refuses another NAT prefix rather than removing it' {
        $script:nats = @([pscustomobject]@{ Name = 'ContainerNAT'; InternalIPInterfaceAddressPrefix = '172.20.0.0/16' })
        { & $script:configure } | Should -Throw '*Another WinNAT configuration exists*'
        Should -Invoke New-NetNat -Times 0 -Exactly
    }

    It 'refuses a same-name NAT with a different prefix' {
        $script:nats = @([pscustomobject]@{ Name = 'NestedNAT'; InternalIPInterfaceAddressPrefix = '172.20.0.0/16' })
        { & $script:configure } | Should -Throw '*does not use*'
        Should -Invoke New-NetNat -Times 0 -Exactly
    }

    It 'does not report success when the nested hypervisor cannot start a VM' {
        Mock Start-VM { throw 'Hypervisor unavailable' }
        { & $script:configure } | Should -Throw '*Hypervisor unavailable*'
        Should -Invoke Remove-VM -Times 1 -Exactly
        Should -Invoke Stop-VM -Times 0 -Exactly
    }

    It 'does not report success if the VM never reaches Running' {
        Mock Start-VM { }
        { & $script:configure } | Should -Throw '*failed to start*'
        Should -Invoke Remove-VM -Times 1 -Exactly
    }

    It 'stops before disk changes when Hyper-V is not installed' {
        Mock Get-WindowsFeature { [pscustomobject]@{ InstallState = 'Available' } }
        { & $script:configure } | Should -Throw '*must be installed*'
        Should -Invoke Initialize-Disk -Times 0 -Exactly
    }
}
