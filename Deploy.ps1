<#
.SYNOPSIS
Builds and verifies a private Azure VM that hosts nested Hyper-V guests.
.DESCRIPTION
Runs on the deployment workstation, not inside the Azure VM. Existing network
names are supplied by the caller; no VNet, subnet, public IP, or NSG is created.
After regional preflight and ARM validation, the script provisions the host,
installs the latest stable PowerShell 7 and Hyper-V, restarts Windows, and
configures storage/NAT through Run Command.
The final host script boots a temporary VM to verify the nested hypervisor.
.PARAMETER SubscriptionId
Subscription used for both the new host resources and the existing VNet.
.PARAMETER ResourceGroupName
Resource group for the host/NIC/disks. Keep it separate from shared VPN resources
so that deleting the host resource group does not delete the existing network.
.PARAMETER Location
Azure region for the host; must match the existing VNet. Defaults to Central US.
.PARAMETER VirtualMachineName
Azure VM and Windows computer name. The 15-character limit is imposed by Windows.
.PARAMETER VirtualMachineSize
Requested host size. Regional compatibility/quota failures offer alternatives
without automatically changing the selected size.
.PARAMETER ImageSku
Windows Server Gen2 SKU under MicrosoftWindowsServer:WindowsServer.
.PARAMETER ImageVersion
Concrete Marketplace version or latest. Latest is resolved and pinned before ARM.
.PARAMETER OSDiskSku
Managed disk tier for the fixed 127-GiB OS disk.
.PARAMETER DataDiskSku
Managed disk tier for guest VM storage. Standard_LRS is the lowest-cost default.
.PARAMETER AdminUsername
Local administrator account on the Azure host, not an account inside nested VMs.
.PARAMETER AdminPassword
SecureString forwarded directly to ARM's securestring input; never logged here.
.PARAMETER VNetResourceGroupName
Resource group containing the caller's existing VNet.
.PARAMETER VNetName
Existing VNet name. Its DNS, VPN, routes, and security rules remain untouched.
.PARAMETER SubnetName
Existing VM-capable subnet with VPN access and suitable outbound connectivity.
.PARAMETER DataDiskSizeGB
Provisioned data capacity in GiB. Guest VHDX files are stored on this disk at F:.
.PARAMETER TimeZone
Windows time-zone identifier, independent of the Azure region.
.PARAMETER ValidateOnly
Runs preflight and ARM validation without provisioning a VM. Creates the target
resource group if absent because ARM group validation requires one.
.OUTPUTS
A host/network summary object on deployment success; a message for ValidateOnly.
Timestamped status messages use the host stream, leaving this output consumable.
.NOTES
Requires an authenticated Azure PowerShell context and permission to deploy and
execute VM Run Command. Rerunning the full build restarts the host again.
#>
#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [string] $ResourceGroupName = 'rg-lab',
    [string] $Location = 'centralus',

    [ValidatePattern('^[a-zA-Z][a-zA-Z0-9-]{0,13}[a-zA-Z0-9]$')]
    [string] $VirtualMachineName = 'Hyperv01',

    [string] $VirtualMachineSize = 'Standard_D8s_v5',
    [ValidateNotNullOrEmpty()]
    [string] $ImageSku = '2025-datacenter-g2',
    [ValidatePattern('^(latest|[0-9]+\.[0-9]+\.[0-9]+)$')]
    [string] $ImageVersion = 'latest',
    [ValidateNotNullOrEmpty()]
    [string] $OSDiskSku = 'StandardSSD_LRS',
    [ValidateNotNullOrEmpty()]
    [string] $DataDiskSku = 'Standard_LRS',
    [string] $AdminUsername = 'vadmin',

    [Parameter(Mandatory)]
    [securestring] $AdminPassword,

    [Parameter(Mandatory)]
    [ValidatePattern('^[^/\s]+$')]
    [string] $VNetResourceGroupName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[^/\s]+$')]
    [string] $VNetName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[^/\s]+$')]
    [string] $SubnetName,

    [ValidateRange(32, 32767)]
    [int] $DataDiskSizeGB = 256,

    [string] $TimeZone = 'Eastern Standard Time',
    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# A monotonic timer measures duration even if the workstation's wall clock changes.
$executionTimer = [System.Diagnostics.Stopwatch]::StartNew()
$progressState = @{ Step = 0; Message = 'Starting' }
$totalSteps = if ($ValidateOnly) { 5 } else { 10 }
$progressActivity = "Hyper-V deployment: $VirtualMachineName ($Location)"

function Write-DeploymentStatus {
    # Keep a shared last-stage record so exceptions can identify the failing phase.
    # Percentages are stage-based; they do not estimate Azure operation completion.
    param(
        [Parameter(Mandatory)] [int] $Step,
        [Parameter(Mandatory)] [string] $Message
    )

    $progressState.Step = $Step
    $progressState.Message = $Message
    $elapsed = $executionTimer.Elapsed.ToString('hh\:mm\:ss')
    # Host-stream messages survive transcripts without becoming deployment results.
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')] [$elapsed] [Step $Step/$totalSteps] $Message"
    Write-Progress -Id 1 -Activity $progressActivity -Status $Message `
        -PercentComplete ([int](100 * ($Step - 1) / $totalSteps))
}

try {
    Write-DeploymentStatus -Step 1 -Message 'Checking Azure PowerShell modules.'
    foreach ($module in 'Az.Accounts', 'Az.Resources', 'Az.Compute') {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            throw "Missing $module. Install-Module Az -Scope CurrentUser, then run Connect-AzAccount."
        }
    }
    Import-Module Az.Accounts
    Import-Module Az.Resources
    Import-Module Az.Compute

    Write-DeploymentStatus -Step 2 -Message "Selecting subscription $SubscriptionId and validating existing VNet/subnet."
    if (-not (Get-AzContext)) {
        throw 'Sign in first using Connect-AzAccount.'
    }
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

    # Resolve the existing subnet without issuing any network write operations.
    # Azure requires the NIC/VM region to match the VNet, even across resource groups.
    $vnetResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$VNetResourceGroupName/providers/Microsoft.Network/virtualNetworks/$VNetName"
    $subnetResourceId = "$vnetResourceId/subnets/$SubnetName"
    $vnet = Get-AzResource -ResourceId $vnetResourceId -ExpandProperties
    if ($vnet.Location -ne $Location) {
        throw "The existing VNet is in '$($vnet.Location)'; the VM location must match ($Location)."
    }
    if (-not ($vnet.Properties.subnets | Where-Object { $_.id -eq $SubnetResourceId })) {
        throw "Existing subnet '$SubnetResourceId' was not found in the VNet."
    }
    Write-Warning 'Private-only deployment: the existing network must provide VPN access and outbound connectivity for Azure VM Run Command and guest Internet access. No network routes, NSGs, DNS, or egress resources will be changed.'

    Write-DeploymentStatus -Step 3 -Message 'Checking regional VM/image/disk availability and quota. Catalog queries can take several minutes.'
    # Collect all component failures before creating resources. Alternatives require
    # an explicit rerun because they can change cost, OS edition, or storage behavior.
    $availability = & (Join-Path $PSScriptRoot 'scripts\Test-DeploymentAvailability.ps1') `
        -Location $Location -VirtualMachineSize $VirtualMachineSize -ImageSku $ImageSku `
        -ImageVersion $ImageVersion -OSDiskSku $OSDiskSku -DataDiskSku $DataDiskSku -DataDiskSizeGB $DataDiskSizeGB
    if ($availability.Failures.Count -gt 0) {
        if ($availability.Alternatives.Count -gt 0) {
            Write-Host "Verified alternatives in ${Location} (no automatic substitutions):"
            Write-Host ($availability.Alternatives | Format-Table Component, Selection, Details -Wrap | Out-String -Width 240)
        }
        throw "Regional preflight failed in ${Location}:`n$($availability.Failures -join "`n")`nSelect alternatives explicitly and rerun. No deployment resources were created."
    }
    Write-Host "Verified VM $VirtualMachineSize, image ${ImageSku}:$($availability.Image.Version), OS disk $OSDiskSku and data disk $DataDiskSku in $Location."

    $template = Join-Path $PSScriptRoot 'azuredeploy.json'
    # Keep this map aligned with azuredeploy.json; use the verified image version
    # rather than allowing "latest" to change between preflight and provisioning.
    $parameters = @{
        location = $Location
        virtualMachineName = $VirtualMachineName
        virtualMachineSize = $VirtualMachineSize
        imageSku = $ImageSku
        imageVersion = $availability.Image.Version
        osDiskSku = $OSDiskSku
        dataDiskSku = $DataDiskSku
        adminUsername = $AdminUsername
        adminPassword = $AdminPassword
        vnetResourceGroupName = $VNetResourceGroupName
        vnetName = $VNetName
        subnetName = $SubnetName
        dataDiskSizeGB = $DataDiskSizeGB
        timeZone = $TimeZone
    }

    Write-DeploymentStatus -Step 4 -Message "Ensuring resource group '$ResourceGroupName' exists."
    # Validation needs an existing resource group; this is the only resource created by -ValidateOnly.
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force | Out-Null
    Write-DeploymentStatus -Step 5 -Message 'Validating the ARM template with Azure.'
    $validation = @(Test-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
        -TemplateFile $template -TemplateParameterObject $parameters)
    # Test-AzResourceGroupDeployment returns validation errors, not a success object.
    if ($validation.Count -gt 0) {
        throw "ARM validation failed: $($validation | ConvertTo-Json -Depth 10 -Compress)"
    }
    if ($ValidateOnly) {
        Write-DeploymentStatus -Step 5 -Message 'Validation completed successfully. No VM was deployed.'
        Write-Output 'Preflight and ARM validation passed. No VM was deployed.'
        return
    }

    Write-DeploymentStatus -Step 6 -Message "Deploying Azure VM, disks and NIC. Monitor '$VirtualMachineName-build' under resource group '$ResourceGroupName' in Azure Deployments."
    $deployment = New-AzResourceGroupDeployment -Name "$VirtualMachineName-build" `
        -ResourceGroupName $ResourceGroupName -TemplateFile $template -TemplateParameterObject $parameters
    if ($deployment.ProvisioningState -ne 'Succeeded') {
        throw "ARM deployment did not succeed: $($deployment.ProvisioningState)"
    }

    function Invoke-HostScript {
        # Action Run Command executes locally supplied scripts through the VM agent
        # as SYSTEM. It needs no inbound WinRM/RDP rule or publicly hosted script.
        param(
            [Parameter(Mandatory)] [string] $ScriptName,
            [Parameter(Mandatory)] [string] $SuccessMarker
        )

        $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VirtualMachineName `
            -CommandId RunPowerShellScript -ScriptPath (Join-Path $PSScriptRoot "scripts\$ScriptName")
        $messages = ($result.Value | ForEach-Object { $_.Message }) -join "`n"
        Write-Host $messages
        # An Azure transport success does not prove the guest script succeeded.
        # Require its final marker as well as empty stderr and non-failing statuses.
        $failedStatuses = @($result.Value | Where-Object {
            $_.Code -match 'failed|error' -or
            ($_.Code -match 'StdErr' -and -not [string]::IsNullOrWhiteSpace($_.Message))
        })
        if ($failedStatuses.Count -gt 0 -or $messages -notmatch [regex]::Escape($SuccessMarker)) {
            throw "Host script $ScriptName failed or did not return its success marker."
        }
    }

    Write-DeploymentStatus -Step 7 -Message 'Installing Hyper-V and the latest stable PowerShell 7 through Azure Run Command. Guest output is returned when the command finishes.'
    Invoke-HostScript -ScriptName Install-HyperV.ps1 -SuccessMarker HYPERV_INSTALL_OK
    Write-DeploymentStatus -Step 8 -Message 'Hyper-V and PowerShell 7 installation succeeded. Restarting the Azure VM.'
    # Reboot outside Run Command so the installation response/marker can finish first.
    Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $VirtualMachineName | Out-Null

    Write-DeploymentStatus -Step 9 -Message 'Restart request completed. Waiting up to 15 minutes for the VM and Azure VM agent.'
    # Running power state alone is insufficient: the guest agent must also recover
    # before the next script can be delivered. A temporarily missing agent is normal.
    $deadline = [datetime]::UtcNow.AddMinutes(15)
    $ready = $false
    do {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VirtualMachineName -Status
        $agentReady = $null -ne $vm.VMAgent -and @($vm.VMAgent.Statuses | Where-Object {
            $_.Code -eq 'ProvisioningState/succeeded'
        }).Count -gt 0
        $running = @($vm.Statuses | Where-Object { $_.Code -eq 'PowerState/running' }).Count -gt 0
        $ready = $agentReady -and $running
        $remainingSeconds = [Math]::Max(0, [int]($deadline - [datetime]::UtcNow).TotalSeconds)
        Write-DeploymentStatus -Step 9 -Message "VM running: $running; Azure VM agent ready: $agentReady; timeout remaining: ${remainingSeconds}s."
        if (-not $ready) {
            Start-Sleep -Seconds 15
        }
    } until ($ready -or [datetime]::UtcNow -ge $deadline)
    if (-not $ready) {
        throw 'The VM agent did not become ready within 15 minutes after the Hyper-V restart.'
    }

    Write-DeploymentStatus -Step 10 -Message 'Configuring data storage and Hyper-V NAT, then boot-testing a nested VM. Guest output is returned when the command finishes.'
    Invoke-HostScript -ScriptName Configure-HyperV.ps1 -SuccessMarker HYPERV_CONFIG_OK
    Write-DeploymentStatus -Step 10 -Message "Deployment completed successfully. Private IP: $($deployment.Outputs['privateIPAddress'].Value). Nested VM boot verification passed."
    Write-Output ([pscustomobject] @{
        VM = $VirtualMachineName
        ResourceGroup = $ResourceGroupName
        PrivateIPAddress = $deployment.Outputs['privateIPAddress'].Value
        VMPath = 'F:\Hyper-V\VMs'
        VHDPath = 'F:\Hyper-V\Virtual Hard Disks'
        NestedSwitch = 'NestedNAT'
        GuestSubnet = '192.168.100.0/24'
        GuestGateway = '192.168.100.1'
    })
} catch {
    # Add phase context without replacing the original exception or reporting success.
    $elapsed = $executionTimer.Elapsed.ToString('hh\:mm\:ss')
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')] [$elapsed] FAILED at step $($progressState.Step)/${totalSteps}: $($progressState.Message)" -ForegroundColor Red
    throw
} finally {
    # Return in ValidateOnly and terminating errors both pass through this cleanup.
    Write-Progress -Id 1 -Activity $progressActivity -Completed
    $executionTimer.Stop()
}
