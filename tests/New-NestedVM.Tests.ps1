<#
.SYNOPSIS
Offline tests for optional nested-guest vTPM setup and its first-boot boundary.
.DESCRIPTION
Mocks Hyper-V and storage lookups. No VM, key protector, or virtual disk is created.
Stateful call tracking verifies that key protection and vTPM checks precede boot.
#>
BeforeAll {
    $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\New-NestedVM.ps1'
    $script:newGuest = [scriptblock]::Create(
        ((Get-Content -LiteralPath $path -Raw) -replace '(?m)^#Requires.*$', '')
    )
    function Get-VMSwitch { param($Name) }
    function Get-NetNat { param($Name) }
    function Get-VMHost { }
    function Get-VM { }
    function New-VM { param($Name, $Generation, $MemoryStartupBytes, $Path, $NewVHDPath, $NewVHDSizeBytes, $SwitchName) }
    function Set-VMProcessor { param($VM, $Count) }
    function Set-VMMemory { param($VM, $DynamicMemoryEnabled) }
    function Set-VMFirmware { param($VM, $EnableSecureBoot, $SecureBootTemplate, $FirstBootDevice) }
    function Set-VMKeyProtector { param($VM, [switch]$NewLocalKeyProtector) }
    function Enable-VMTPM { param($VM) }
    function Get-VMSecurity { param($VM) }
    function Add-VMDvdDrive { param($VM, $Path) }
    function Get-VMDvdDrive { param($VM) }
    function Start-VM { param($VM) }
}

Describe 'Nested VM optional virtual TPM' {
    BeforeEach {
        $script:state = [pscustomobject]@{ Events = [System.Collections.Generic.List[string]]::new() }
        $state = $script:state
        $script:arguments = @{ Name = 'lab01'; IsoPath = 'F:\Hyper-V\ISO\server.iso' }
        Mock Test-Path { $LiteralPath -like '*.iso' }
        Mock Join-Path { "$Path\$ChildPath" } -ParameterFilter { $Path -like 'F:\*' }
        Mock Get-VMSwitch { [pscustomobject]@{ SwitchType = 'Internal' } }
        Mock Get-NetNat { [pscustomobject]@{ Active = $true } }
        Mock Get-VMHost {
            [pscustomobject]@{
                VirtualMachinePath = 'F:\Hyper-V\VMs'
                VirtualHardDiskPath = 'F:\Hyper-V\Virtual Hard Disks'
            }
        }
        Mock Get-VM { }
        Mock New-VM { [pscustomobject]@{ Name = $Name; State = 'Off'; Generation = 2 } }
        Mock Set-VMProcessor { }
        Mock Set-VMMemory { }
        Mock Set-VMFirmware { }
        Mock Set-VMKeyProtector -MockWith ({ $state.Events.Add('KeyProtector') }.GetNewClosure())
        Mock Enable-VMTPM -MockWith ({ $state.Events.Add('EnableTPM') }.GetNewClosure())
        Mock Get-VMSecurity -MockWith ({
            $state.Events.Add('VerifyTPM')
            [pscustomobject]@{ TpmEnabled = $true }
        }.GetNewClosure())
        Mock Add-VMDvdDrive { }
        Mock Get-VMDvdDrive { [pscustomobject]@{ Path = 'F:\Hyper-V\ISO\server.iso' } }
        Mock Start-VM -MockWith ({ $state.Events.Add('Start') }.GetNewClosure())
        Mock Write-Warning { }
    }

    It 'keeps vTPM opt-in and preserves normal Gen2 guest creation' {
        & $script:newGuest @script:arguments | Out-Null
        Should -Invoke New-VM -Times 1 -Exactly -ParameterFilter {
            $Generation -eq 2 -and $MemoryStartupBytes -eq 8GB -and $SwitchName -eq 'NestedNAT'
        }
        Should -Invoke Set-VMKeyProtector -Times 0 -Exactly
        Should -Invoke Enable-VMTPM -Times 0 -Exactly
        Should -Invoke Get-VMSecurity -Times 0 -Exactly
        Should -Invoke Start-VM -Times 1 -Exactly
    }

    It 'sets a local key protector, enables and verifies TPM, then boots the guest' {
        & $script:newGuest @script:arguments -EnableVTPM | Out-Null
        ($script:state.Events -join ',') | Should -Be 'KeyProtector,EnableTPM,VerifyTPM,Start'
        Should -Invoke Set-VMKeyProtector -Times 1 -Exactly -ParameterFilter {
            $VM.Name -eq 'lab01' -and $VM.State -eq 'Off' -and $NewLocalKeyProtector
        }
        Should -Invoke Enable-VMTPM -Times 1 -Exactly -ParameterFilter { $VM.Name -eq 'lab01' }
        Should -Invoke Write-Warning -Times 1 -Exactly -ParameterFilter { $Message -like '*local key protector*' }
    }

    It 'also supports vTPM with the existing Linux Secure Boot template' {
        & $script:newGuest @script:arguments -GuestOS Linux -EnableVTPM | Out-Null
        Should -Invoke Set-VMFirmware -Times 1 -Exactly -ParameterFilter {
            $EnableSecureBoot -eq 'On' -and $SecureBootTemplate -eq 'MicrosoftUEFICertificateAuthority'
        }
        Should -Invoke Enable-VMTPM -Times 1 -Exactly
    }

    It 'never boots when key protector configuration fails' {
        Mock Set-VMKeyProtector { throw 'Key protector failed' }
        { & $script:newGuest @script:arguments -EnableVTPM } | Should -Throw '*Key protector failed*'
        Should -Invoke Enable-VMTPM -Times 0 -Exactly
        Should -Invoke Start-VM -Times 0 -Exactly
    }

    It 'never boots when the host cannot enable vTPM' {
        Mock Enable-VMTPM { throw 'vTPM unavailable on this host' }
        { & $script:newGuest @script:arguments -EnableVTPM } | Should -Throw '*vTPM unavailable*'
        Should -Invoke Start-VM -Times 0 -Exactly
    }

    It 'never boots when TPM read-back does not confirm enablement' {
        Mock Get-VMSecurity { [pscustomobject]@{ TpmEnabled = $false } }
        { & $script:newGuest @script:arguments -EnableVTPM } | Should -Throw '*VM has not been started*'
        Should -Invoke Start-VM -Times 0 -Exactly
    }

    It 'does not replace key material on an existing VM' {
        Mock Get-VM { [pscustomobject]@{ Name = 'lab01' } }
        { & $script:newGuest @script:arguments -EnableVTPM } | Should -Throw '*already exists*'
        Should -Invoke New-VM -Times 0 -Exactly
        Should -Invoke Set-VMKeyProtector -Times 0 -Exactly
    }
}
