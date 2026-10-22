<#
.SYNOPSIS
Offline Pester regression tests for deployment orchestration and regional preflight.
.DESCRIPTION
Uses synthetic Azure catalogs and mocks every Azure mutation, reboot, Run Command,
and sleep. Verifies resource-creation boundaries, explicit alternative selection,
concrete image resolution, progress output, and propagation of guest/API failures.
.NOTES
No Azure subscription or credentials are needed. Passing catalog tests is not a
reservation of regional capacity; real preflight/ARM checks run during deployment.
#>
BeforeAll {
    $script:deployPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Deploy.ps1'
    $script:availabilityPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Test-DeploymentAvailability.ps1'
    # Stub signatures allow Pester to intercept Az calls without importing or
    # authenticating the real modules on the machine executing the tests.
    function Get-AzContext { }
    function Set-AzContext { param($SubscriptionId) }
    function Get-AzResource { param($ResourceId, [switch]$ExpandProperties) }
    function Get-AzComputeResourceSku { param($Location) }
    function Get-AzVMUsage { param($Location) }
    function Get-AzVMImage { param($Location, $PublisherName, $Offer, $Skus, $Version, $Top, $OrderBy) }
    function Get-AzVMImageSku { param($Location, $PublisherName, $Offer) }
    function New-AzResourceGroup { param($Name, $Location, [switch]$Force) }
    function Test-AzResourceGroupDeployment { param($ResourceGroupName, $TemplateFile, $TemplateParameterObject) }
    function New-AzResourceGroupDeployment { param($Name, $ResourceGroupName, $TemplateFile, $TemplateParameterObject) }
    function Invoke-AzVMRunCommand { param($ResourceGroupName, $VMName, $CommandId, $ScriptPath) }
    function Restart-AzVM { param($ResourceGroupName, $Name) }
    function Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status) }
}

Describe 'End-to-end deployment orchestration without Azure side effects' {
    BeforeEach {
        $script:arguments = @{
            SubscriptionId = [guid]::Empty.ToString()
            AdminPassword = ConvertTo-SecureString ([guid]::NewGuid().ToString()) -AsPlainText -Force
            VNetResourceGroupName = 'network-rg'
            VNetName = 'existing-vnet'
            SubnetName = 'hosts'
        }
        $script:state = [pscustomobject]@{
            Steps = [System.Collections.Generic.List[string]]::new()
            Messages = [System.Collections.Generic.List[string]]::new()
            Polls = 0
        }
        # Capture shared objects in closures: Deploy.ps1 is a separate script
        # scope, so relying on the mock's ambient $script: variables is unsafe.
        $state = $script:state
        Mock Write-Host -MockWith ({
            param($Object)
            $state.Messages.Add([string]$Object)
        }.GetNewClosure())
        Mock Write-Progress { }
        $script:availabilityArguments = @{
            Location = 'centralus'; VirtualMachineSize = 'Standard_D8s_v5'
            ImageSku = '2025-datacenter-g2'; ImageVersion = 'latest'
            OSDiskSku = 'StandardSSD_LRS'; DataDiskSku = 'Standard_LRS'; DataDiskSizeGB = 256
        }
        Mock Get-Module { [pscustomobject]@{ Name = $Name } } -ParameterFilter {
            $ListAvailable -and $Name -in @('Az.Accounts', 'Az.Resources', 'Az.Compute')
        }
        Mock Import-Module { } -ParameterFilter { $Name -in @('Az.Accounts', 'Az.Resources', 'Az.Compute') }
        Mock Get-AzContext { [pscustomobject]@{ Name = 'TestContext' } }
        Mock Set-AzContext { }
        Mock Get-AzResource {
            [pscustomobject]@{
                Location = 'centralus'
                Properties = @{ subnets = @(@{ id = "$ResourceId/subnets/hosts" }) }
            }
        }
        # Include more than five candidates to exercise selection limits and
        # quota filtering, not just the happy path for a single requested size.
        $script:catalog = @(
            foreach ($cores in 8, 16, 32, 48, 64, 96) {
                [pscustomobject]@{
                Name = "Standard_D${cores}s_v5"; ResourceType = 'virtualMachines'
                Restrictions = @(); Family = 'standardDSv5Family'
                Capabilities = @(
                    [pscustomobject]@{ Name = 'vCPUs'; Value = "$cores" },
                    [pscustomobject]@{ Name = 'MemoryGB'; Value = "$($cores * 4)" },
                    [pscustomobject]@{ Name = 'PremiumIO'; Value = 'True' },
                    [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' },
                    [pscustomobject]@{ Name = 'AcceleratedNetworkingEnabled'; Value = 'True' }
                )
                }
            }
            foreach ($name in 'Standard_LRS', 'StandardSSD_LRS', 'StandardSSD_ZRS', 'Premium_LRS', 'Premium_ZRS') {
                [pscustomobject]@{
                    Name = $name; ResourceType = 'disks'; Restrictions = @()
                    Capabilities = @(
                        [pscustomobject]@{ Name = 'MinSizeGiB'; Value = '1' },
                        [pscustomobject]@{ Name = 'MaxSizeGiB'; Value = '32767' }
                    )
                }
            }
        )
        $catalog = $script:catalog
        Mock Get-AzComputeResourceSku -MockWith ({ $catalog }.GetNewClosure())
        Mock Get-AzVMUsage {
            foreach ($name in 'cores', 'standardDSv5Family') {
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = $name }; CurrentValue = 0; Limit = 100 }
            }
        }
        Mock Get-AzVMImageSku {
            foreach ($name in '2025-datacenter-g2', '2025-datacenter-core-g2',
                '2025-datacenter-smalldisk-g2', '2025-datacenter-core-smalldisk-g2',
                '2022-datacenter-g2', '2022-datacenter-core-g2') {
                [pscustomobject]@{ Skus = $name }
            }
        }
        # Reproduce the original "latest" bug: list results contain Version but
        # no generation details. Only a concrete version query returns Gen2 data.
        Mock Get-AzVMImage {
            if (-not $Version) {
                [pscustomobject]@{ Version = '26100.1234.5678' }
            } elseif ($Version -eq 'latest') {
                throw 'Regression: latest alias must not be used to read image details.'
            } else {
                [pscustomobject]@{
                    Version = $Version; HyperVGeneration = 'V2'; Architecture = 'x64'
                    OSDiskImage = [pscustomobject]@{ OperatingSystem = 'Windows' }
                }
            }
        }
        Mock New-AzResourceGroup { }
        Mock Test-AzResourceGroupDeployment { }
        Mock New-AzResourceGroupDeployment {
            [pscustomobject]@{
                ProvisioningState = 'Succeeded'
                Outputs = @{ privateIPAddress = @{ Value = '10.30.0.4' } }
            }
        }
        # Record order and markers rather than executing guest scripts. Dedicated
        # host/guest tests in Build.Tests.ps1 exercise those scripts separately.
        Mock Invoke-AzVMRunCommand -MockWith ({
            param($ResourceGroupName, $VMName, $CommandId, $ScriptPath)
            $leaf = Split-Path $ScriptPath -Leaf
            $state.Steps.Add($leaf)
            $marker = if ($leaf -eq 'Install-HyperV.ps1') { 'HYPERV_INSTALL_OK' } else { 'HYPERV_CONFIG_OK' }
            [pscustomobject]@{
                Value = @([pscustomobject]@{ Code = 'ComponentStatus/StdOut/succeeded'; Message = $marker })
            }
        }.GetNewClosure())
        Mock Restart-AzVM -MockWith ({ $state.Steps.Add('Restart') }.GetNewClosure())
        Mock Get-AzVM {
            [pscustomobject]@{
                VMAgent = [pscustomobject]@{
                    Statuses = @([pscustomobject]@{ Code = 'ProvisioningState/succeeded' })
                }
                Statuses = @([pscustomobject]@{ Code = 'PowerState/running' })
            }
        }
        Mock Start-Sleep { }
    }

    It 'installs, restarts, configures, then reports the deployed endpoint' {
        $result = & $script:deployPath @script:arguments
        ($script:state.Steps -join ',') | Should -Be 'Install-HyperV.ps1,Restart,Configure-HyperV.ps1'
        $result.PrivateIPAddress | Should -Be '10.30.0.4'
        $result.GuestGateway | Should -Be '192.168.100.1'
        Should -Invoke New-AzResourceGroupDeployment -Times 1 -Exactly -ParameterFilter {
            $TemplateParameterObject.adminPassword -is [securestring] -and
            $TemplateParameterObject.dataDiskSizeGB -eq 256 -and
            $TemplateParameterObject.location -eq 'centralus' -and
            $TemplateParameterObject.imageSku -eq '2025-datacenter-g2' -and
            $TemplateParameterObject.imageVersion -eq '26100.1234.5678' -and
            $TemplateParameterObject.osDiskSku -eq 'StandardSSD_LRS' -and
            $TemplateParameterObject.dataDiskSku -eq 'Standard_LRS' -and
            $TemplateParameterObject.vnetResourceGroupName -eq 'network-rg' -and
            $TemplateParameterObject.vnetName -eq 'existing-vnet' -and
            $TemplateParameterObject.subnetName -eq 'hosts' -and
            -not $TemplateParameterObject.ContainsKey('rdpSourceAddressPrefix') -and
            (Test-Path -LiteralPath $TemplateFile)
        }
    }

    It 'validates without provisioning or restarting a VM' {
        & $script:deployPath @script:arguments -ValidateOnly | Should -Match 'No VM was deployed'
        Should -Invoke Test-AzResourceGroupDeployment -Times 1 -Exactly
        Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
        Should -Invoke Invoke-AzVMRunCommand -Times 0 -Exactly
        Should -Invoke Restart-AzVM -Times 0 -Exactly
    }

    It 'reports timestamped progress for all ten deployment stages without changing the result object' {
        $result = @(& $script:deployPath @script:arguments)
        $result.Count | Should -Be 1
        $result[0].PrivateIPAddress | Should -Be '10.30.0.4'
        $stages = @($script:state.Messages | ForEach-Object {
            if ($_ -match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{2}:\d{2}\] \[\d{2}:\d{2}:\d{2}\] \[Step (\d+)/10\]') {
                [int]$Matches[1]
            }
        })
        ($stages | Select-Object -Unique) -join ',' | Should -Be '1,2,3,4,5,6,7,8,9,10'
        ($stages | Sort-Object) -join ',' | Should -Be ($stages -join ',')
        $script:state.Messages[-1] | Should -Match 'Deployment completed successfully.*Nested VM boot verification passed'
        Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter { $Id -eq 1 -and $Completed }
        Should -Invoke Write-Progress -Times 0 -Exactly -ParameterFilter {
            -not $Completed -and ($PercentComplete -lt 0 -or $PercentComplete -gt 100)
        }
    }

    It 'uses five stages for validation-only and always clears its progress bar' {
        & $script:deployPath @script:arguments -ValidateOnly | Should -Match 'No VM was deployed'
        $script:state.Messages[-1] | Should -Match '\[Step 5/5\] Validation completed successfully'
        $script:state.Messages -join "`n" | Should -Not -Match '\[Step [6-9]/'
        Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter { $Id -eq 1 -and $Completed }
    }

    It 'reports the failing stage, rethrows the original error, and clears progress without claiming success' {
        Mock Invoke-AzVMRunCommand { throw 'Run command failed unexpectedly' }
        { & $script:deployPath @script:arguments } | Should -Throw '*Run command failed unexpectedly*'
        $script:state.Messages[-1] | Should -Match 'FAILED at step 7/10: Installing Hyper-V'
        $script:state.Messages -join "`n" | Should -Not -Match 'Deployment completed successfully'
        Should -Invoke Write-Progress -Times 1 -Exactly -ParameterFilter { $Id -eq 1 -and $Completed }
        Should -Invoke Restart-AzVM -Times 0 -Exactly
    }

    It 'rejects a VNet in a different region before resource changes' {
        Mock Get-AzResource { [pscustomobject]@{ Location = 'eastus2' } }
        { & $script:deployPath @script:arguments } | Should -Throw '*VM location must match*'
        Should -Invoke New-AzResourceGroup -Times 0 -Exactly
    }

    It 'rejects a missing subnet before resource changes' {
        Mock Get-AzResource { [pscustomobject]@{ Location = 'centralus'; Properties = @{ subnets = @() } } }
        { & $script:deployPath @script:arguments } | Should -Throw '*was not found*'
        Should -Invoke New-AzResourceGroup -Times 0 -Exactly
    }

    It 'uses command-line network names rather than hardcoded names' {
        $script:arguments.VNetResourceGroupName = 'another-network-rg'
        $script:arguments.VNetName = 'another-vnet'
        $script:arguments.SubnetName = 'another-subnet'
        Mock Get-AzResource {
            [pscustomobject]@{
                Location = 'centralus'
                Properties = @{ subnets = @(@{ id = "$ResourceId/subnets/another-subnet" }) }
            }
        }
        & $script:deployPath @script:arguments -ValidateOnly | Should -Match 'No VM was deployed'
        Should -Invoke Get-AzResource -Times 1 -Exactly -ParameterFilter {
            $ResourceId -eq "/subscriptions/$([guid]::Empty)/resourceGroups/another-network-rg/providers/Microsoft.Network/virtualNetworks/another-vnet"
        }
        Should -Invoke Test-AzResourceGroupDeployment -Times 1 -Exactly -ParameterFilter {
            $TemplateParameterObject.vnetResourceGroupName -eq 'another-network-rg' -and
            $TemplateParameterObject.vnetName -eq 'another-vnet' -and
            $TemplateParameterObject.subnetName -eq 'another-subnet'
        }
    }

    It 'rejects insufficient quota before resource changes' {
        Mock Get-AzVMUsage {
            [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'cores' }; CurrentValue = 96; Limit = 100 }
        }
        { & $script:deployPath @script:arguments } | Should -Throw '*quota*'
        Should -Invoke New-AzResourceGroup -Times 0 -Exactly
    }

        It 'resolves latest before fetching Gen2 details and pins the resolved version' {
            & $script:deployPath @script:arguments -ValidateOnly | Should -Match 'No VM was deployed'
            Should -Invoke Get-AzVMImage -Times 1 -Exactly -ParameterFilter { $Top -eq 1 -and $OrderBy -eq 'name desc' }
            Should -Invoke Get-AzVMImage -Times 1 -Exactly -ParameterFilter { $Version -eq '26100.1234.5678' }
            Should -Invoke Get-AzVMImage -Times 0 -Exactly -ParameterFilter { $Version -eq 'latest' }
        }

        It 'returns exactly five verified VM alternatives for an unavailable size' {
            $script:availabilityArguments.VirtualMachineSize = 'Standard_D9s_v5'
            $report = & $script:availabilityPath @script:availabilityArguments
            $report.Failures -join ' ' | Should -Match 'not listed'
            @($report.Alternatives | Where-Object Component -EQ VM).Count | Should -Be 5
            $report.Alternatives[0].Selection | Should -Be 'Standard_D8s_v5'
        }

        It 'reports all unavailable components together before resource group creation' {
            $script:arguments.VirtualMachineSize = 'MissingVM'
            $script:arguments.ImageSku = 'MissingImage'
            $script:arguments.OSDiskSku = 'MissingOSDisk'
            $script:arguments.DataDiskSku = 'MissingDataDisk'
            { & $script:deployPath @script:arguments } | Should -Throw '*VM size*Image*OS disk*Data disk*'
            Should -Invoke New-AzResourceGroup -Times 0 -Exactly
            Should -Invoke Test-AzResourceGroupDeployment -Times 0 -Exactly
        }

        It 'returns exactly five concrete image alternatives when the selected image is missing' {
            $script:availabilityArguments.ImageSku = 'MissingImage'
            $report = & $script:availabilityPath @script:availabilityArguments
            $choices = @($report.Alternatives | Where-Object Component -EQ Image)
            $choices.Count | Should -Be 5
            foreach ($choice in $choices) {
                $choice.Selection | Should -Match '^MicrosoftWindowsServer:WindowsServer:.+:26100\.1234\.5678$'
            }
        }

        It 'excludes V1 images from alternative results' {
            $script:availabilityArguments.ImageSku = 'MissingImage'
            Mock Get-AzVMImage {
                [pscustomobject]@{
                    Version = '26100.1234.5678'; HyperVGeneration = 'V1'
                    Architecture = 'x64'; OSDiskImage = @{ OperatingSystem = 'Windows' }
                }
            } -ParameterFilter { $Skus -eq '2025-datacenter-g2' -and $Version }
            $report = & $script:availabilityPath @script:availabilityArguments
            @($report.Alternatives | Where-Object Component -EQ Image).Count | Should -Be 5
            $report.Alternatives.Selection -join ',' | Should -Not -Match ':2025-datacenter-g2:'
        }

        It 'reports fewer than five disk alternatives honestly rather than inventing incompatible types' {
            $catalog = @($script:catalog | Where-Object Name -NE Standard_LRS)
            Mock Get-AzComputeResourceSku -MockWith ({ $catalog }.GetNewClosure())
            $report = & $script:availabilityPath @script:availabilityArguments
            @($report.Alternatives | Where-Object Component -EQ 'Data disk').Count | Should -Be 4
            $report.Failures -join ',' | Should -Match 'Only 4 compatible Data disk alternatives'
            $report.Alternatives.Selection | Should -Not -Contain 'UltraSSD_LRS'
            $report.Alternatives.Selection | Should -Not -Contain 'PremiumV2_LRS'
        }

        It 'checks disk capacity, not just disk SKU names' {
            foreach ($entry in $script:catalog | Where-Object ResourceType -EQ disks) {
                ($entry.Capabilities | Where-Object Name -EQ MaxSizeGiB).Value = '128'
            }
            $report = & $script:availabilityPath @script:availabilityArguments
            $report.Failures -join ',' | Should -Match 'does not support 256 GiB'
            @($report.Alternatives | Where-Object Component -EQ 'Data disk').Count | Should -Be 0
        }

        It 'allows zone-only restrictions for this non-zonal deployment' {
            ($script:catalog | Where-Object Name -EQ Standard_D8s_v5).Restrictions = @(
                [pscustomobject]@{ Type = 'Zone' }
            )
            $report = & $script:availabilityPath @script:availabilityArguments
            $report.Failures.Count | Should -Be 0
        }

        It 'does not recommend subscription-restricted VMs' {
            ($script:catalog | Where-Object Name -EQ Standard_D16s_v5).Restrictions = @(
                [pscustomobject]@{ Type = 'Location' }
            )
            $script:availabilityArguments.VirtualMachineSize = 'MissingVM'
            $report = & $script:availabilityPath @script:availabilityArguments
            $report.Alternatives.Selection | Should -Not -Contain Standard_D16s_v5
        }

        It 'propagates catalog authorization failures rather than treating them as unavailable SKUs' {
            Mock Get-AzComputeResourceSku { throw 'AuthorizationFailed' }
            { & $script:deployPath @script:arguments } | Should -Throw '*AuthorizationFailed*'
            Should -Invoke New-AzResourceGroup -Times 0 -Exactly
        }

        It 'propagates image API failures rather than masking them as missing images' {
            Mock Get-AzVMImage { throw 'Image service unavailable' } -ParameterFilter { $Version }
            { & $script:deployPath @script:arguments } | Should -Throw '*Image service unavailable*'
            Should -Invoke New-AzResourceGroup -Times 0 -Exactly
        }

        It 'wires explicitly selected alternatives through to ARM' {
            $script:arguments.VirtualMachineSize = 'Standard_D16s_v5'
            $script:arguments.ImageSku = '2022-datacenter-g2'
            $script:arguments.ImageVersion = '20348.1234.5678'
            $script:arguments.OSDiskSku = 'Premium_LRS'
            $script:arguments.DataDiskSku = 'StandardSSD_ZRS'
            & $script:deployPath @script:arguments -ValidateOnly | Should -Match 'No VM was deployed'
            Should -Invoke Test-AzResourceGroupDeployment -Times 1 -Exactly -ParameterFilter {
                $TemplateParameterObject.virtualMachineSize -eq 'Standard_D16s_v5' -and
                $TemplateParameterObject.imageSku -eq '2022-datacenter-g2' -and
                $TemplateParameterObject.imageVersion -eq '20348.1234.5678' -and
                $TemplateParameterObject.osDiskSku -eq 'Premium_LRS' -and
                $TemplateParameterObject.dataDiskSku -eq 'StandardSSD_ZRS'
            }
        }
    It 'stops on ARM validation errors' {
        Mock Test-AzResourceGroupDeployment { [pscustomobject]@{ Code = 'InvalidTemplate' } }
        { & $script:deployPath @script:arguments } | Should -Throw '*ARM validation failed*'
        Should -Invoke New-AzResourceGroupDeployment -Times 0 -Exactly
    }

    It 'returns five disk alternatives when an unsupported disk name is selected' {
        $script:availabilityArguments.DataDiskSku = 'UnavailableDisk'
        $report = & $script:availabilityPath @script:availabilityArguments
        @($report.Alternatives | Where-Object Component -EQ 'Data disk').Count | Should -Be 5
    }

    It 'treats an image version HTTP 404 as unavailable and offers five other images' {
        Mock Get-AzVMImage {
            $exception = [System.Exception]::new('Version not found')
            $exception | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = 404 })
            throw $exception
        } -ParameterFilter { $Skus -eq '2025-datacenter-g2' -and $Version }
        $report = & $script:availabilityPath @script:availabilityArguments
        $report.Failures -join ',' | Should -Match 'Image.*unavailable'
        @($report.Alternatives | Where-Object Component -EQ Image).Count | Should -Be 5
    }

    It 'does not recommend disk SKUs restricted for this subscription' {
        ($script:catalog | Where-Object Name -EQ StandardSSD_ZRS).Restrictions = @(
            [pscustomobject]@{ Type = 'Location' }
        )
        $script:availabilityArguments.DataDiskSku = 'UnavailableDisk'
        $report = & $script:availabilityPath @script:availabilityArguments
        $report.Alternatives.Selection | Should -Not -Contain StandardSSD_ZRS
        @($report.Alternatives | Where-Object Component -EQ 'Data disk').Count | Should -Be 4
    }

    It 'validates a realistic multi-tier disk catalog without requiring an exact capacity match' {
        $script:catalog | Where-Object ResourceType -EQ disks | ForEach-Object {
            ($_.Capabilities | Where-Object Name -EQ MinSizeGiB).Value = '128'
            ($_.Capabilities | Where-Object Name -EQ MaxSizeGiB).Value = '256'
        }
        # Add the smaller tier needed by the fixed 127-GiB OS disk.
        $smallerTier = [pscustomobject]@{
            Name = 'StandardSSD_LRS'; ResourceType = 'disks'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MinSizeGiB'; Value = '64' },
                [pscustomobject]@{ Name = 'MaxSizeGiB'; Value = '128' }
            )
        }
        $catalog = @($script:catalog) + $smallerTier
        Mock Get-AzComputeResourceSku -MockWith ({ $catalog }.GetNewClosure())
        $script:availabilityArguments.DataDiskSizeGB = 200
        $report = & $script:availabilityPath @script:availabilityArguments
        $report.Failures.Count | Should -Be 0
    }

    It 'rejects Run Command output without the expected success marker' {
        Mock Invoke-AzVMRunCommand {
            [pscustomobject]@{
                Value = @([pscustomobject]@{ Code = 'ComponentStatus/StdOut/succeeded'; Message = 'Installation failed' })
            }
        }
        { & $script:deployPath @script:arguments } | Should -Throw '*did not return its success marker*'
        Should -Invoke Restart-AzVM -Times 0 -Exactly
    }

    It 'rejects guest stderr even when stdout contains a success marker' {
        Mock Invoke-AzVMRunCommand {
            [pscustomobject]@{
                Value = @(
                    [pscustomobject]@{ Code = 'ComponentStatus/StdOut/succeeded'; Message = 'HYPERV_INSTALL_OK' },
                    [pscustomobject]@{ Code = 'ComponentStatus/StdErr/succeeded'; Message = 'Guest execution error' }
                )
            }
        }
        { & $script:deployPath @script:arguments } | Should -Throw '*Host script Install-HyperV.ps1 failed*'
        Should -Invoke Restart-AzVM -Times 0 -Exactly
    }

    It 'waits when the agent is temporarily absent after restart' {
        $state = $script:state
        Mock Get-AzVM -MockWith ({
            $state.Polls++
            [pscustomobject]@{
                VMAgent = if ($state.Polls -eq 1) { $null } else {
                    [pscustomobject]@{ Statuses = @([pscustomobject]@{ Code = 'ProvisioningState/succeeded' }) }
                }
                Statuses = @([pscustomobject]@{ Code = 'PowerState/running' })
            }
        }.GetNewClosure())
        (& $script:deployPath @script:arguments).GuestGateway | Should -Be '192.168.100.1'
        Should -Invoke Start-Sleep -Times 1 -Exactly
        Should -Invoke Get-AzVM -Times 2 -Exactly
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -like '*VM running: True; Azure VM agent ready: False; timeout remaining:*'
        }
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter {
            $Object -like '*VM running: True; Azure VM agent ready: True; timeout remaining:*'
        }
    }
}
