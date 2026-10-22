<#
.SYNOPSIS
Reports regional availability and compatible alternatives without deploying resources.
.DESCRIPTION
Called by Deploy.ps1 after subscription/VNet selection. Reads the subscription's
regional SKU, quota, and Windows Server image catalogs; it never changes the
selected configuration. Returned failures are aggregated so the caller can show
all failed components before stopping. Authentication/service errors still throw.
.PARAMETER Location
Region to query in the active Azure PowerShell subscription.
.PARAMETER VirtualMachineSize
Requested host size; must meet this build's nested Hyper-V/networking requirements.
.PARAMETER ImageSku
Requested Windows Server Gen2 SKU in the MicrosoftWindowsServer:WindowsServer offer.
.PARAMETER ImageVersion
Concrete version or latest; a successful result always contains a concrete version.
.PARAMETER OSDiskSku
Requested managed disk tier for a 127-GiB OS disk.
.PARAMETER DataDiskSku
Requested managed disk tier for nested VM files.
.PARAMETER DataDiskSizeGB
Data-disk capacity to match against regional disk-tier size ranges.
.OUTPUTS
One object: Failures (string array), Alternatives (Component/Selection/Details
objects), and Image (verified Sku/Version, or null). Empty Failures means preflight
passed; it does not guarantee Azure allocation capacity at deployment time.
.NOTES
Offers at most five alternatives per failed component. Fewer are reported
explicitly rather than recommending unavailable or incompatible resources.
The family filter was designed for this repository's Standard-security/SCSI
configuration; it does not validate every possible template security setting.
#>
#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Location,
    [Parameter(Mandatory)] [string] $VirtualMachineSize,
    [Parameter(Mandatory)] [string] $ImageSku,
    [Parameter(Mandatory)] [string] $ImageVersion,
    [Parameter(Mandatory)] [string] $OSDiskSku,
    [Parameter(Mandatory)] [string] $DataDiskSku,
    [Parameter(Mandatory)] [int] $DataDiskSizeGB
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Capabilities {
    # Azure returns named capabilities as string-valued records. Normalize once
    # per comparison; numeric casts are applied only by the specific size checks.
    param($Sku)
    $values = @{}
    foreach ($capability in $Sku.Capabilities) {
        $values[$capability.Name] = $capability.Value
    }
    return $values
}

function Test-RegionalSku {
    param($Sku)
    # This build is non-zonal: a zone-only restriction does not block regional deployment.
    return @($Sku.Restrictions | Where-Object { $_.Type -eq 'Location' }).Count -eq 0
}

function Get-VMProblems {
    # Emit every reason instead of returning a boolean, allowing both precise
    # selected-SKU errors and reuse of identical checks when ranking alternatives.
    param($Sku)
    if (-not $Sku) {
        return 'not listed in the regional catalog'
    }
    if (-not (Test-RegionalSku $Sku)) {
        'restricted for this subscription in the region'
    }
    $caps = Get-Capabilities $Sku
    # Limit this SCSI/Standard-security build to known Intel nested-capable families.
    if ($Sku.Name -notmatch '^Standard_[DE][0-9]+s_v[345]$') {
        'not in the supported nested-virtualization Dsv3-v5/Esv3-v5 families'
    }
    if ($caps['HyperVGenerations'] -notmatch 'V2') {
        'Gen2 is not supported'
    }
    if ($caps['AcceleratedNetworkingEnabled'] -ne 'True') {
        'accelerated networking is not supported'
    }
    if (($OSDiskSku -like 'Premium*' -or $DataDiskSku -like 'Premium*') -and $caps['PremiumIO'] -ne 'True') {
        'selected Premium disk requires PremiumIO'
    }
    # Allocation consumes both the total regional vCPU pool and its family pool.
    # Missing quota/capacity metadata is not treated as permission to proceed.
    foreach ($quotaName in @('cores', $Sku.Family)) {
        $quota = @($usage | Where-Object { $_.Name.Value -eq $quotaName })
        if ($quota.Count -ne 1 -or -not $caps.ContainsKey('vCPUs') -or
            ($quota[0].CurrentValue + [int]$caps['vCPUs']) -gt $quota[0].Limit) {
            "insufficient or unknown quota for '$quotaName'"
        }
    }
}

function Test-DiskSku {
    param([string] $Name, [int] $SizeGB)
    # Ultra/Premium v2 need a different disk/controller configuration and cannot be OS disks.
    if ($Name -notin @('Standard_LRS', 'StandardSSD_LRS', 'StandardSSD_ZRS', 'Premium_LRS', 'Premium_ZRS')) {
        return $false
    }
    # One disk SKU can appear repeatedly for different capacity tiers. Any
    # unrestricted tier spanning the requested size is sufficient; an exact
    # tier-size equality would incorrectly reject ordinary intermediate sizes.
    return @($catalog | Where-Object {
        if ($_.ResourceType -ne 'disks' -or $_.Name -ne $Name -or -not (Test-RegionalSku $_)) {
            return $false
        }
        $caps = Get-Capabilities $_
        return $caps.ContainsKey('MinSizeGiB') -and $caps.ContainsKey('MaxSizeGiB') -and
            $SizeGB -ge [int]$caps['MinSizeGiB'] -and $SizeGB -le [int]$caps['MaxSizeGiB']
    }).Count -gt 0
}

function Get-CompatibleImage {
    # Restrict alternatives to familiar Windows Server Gen2 variants. Merely
    # finding a catalog entry does not make ARM64, Gen1, or other offers suitable.
    param([string] $SkuName, [string] $Version)
    if ($SkuName -notmatch '^(2025|2022|2019)-datacenter(?:-core|-smalldisk|-core-smalldisk)?-(g2|gensecond)$' -or
        $SkuName -notin $imageSkus) {
        return $null
    }
    $versions = @(Get-AzVMImage -Location $Location -PublisherName MicrosoftWindowsServer `
        -Offer WindowsServer -Skus $SkuName -Top 1 -OrderBy 'name desc')
    if ($versions.Count -eq 0) {
        return $null
    }
    $resolvedVersion = if ($Version -eq 'latest') { $versions[0].Version } else { $Version }
    # The Az.Compute "latest" alias can return a list record with no HyperVGeneration.
    # Query the concrete version to get authoritative compatibility metadata.
    try {
        $details = Get-AzVMImage -Location $Location -PublisherName MicrosoftWindowsServer `
            -Offer WindowsServer -Skus $SkuName -Version $resolvedVersion
    } catch {
        # Only a genuine not-found response is image unavailability. Do not hide
        # expired credentials, authorization problems, throttling, or service errors.
        $response = $_.Exception.PSObject.Properties['Response']
        if ($response -and $response.Value -and [int]$response.Value.StatusCode -eq 404) {
            return $null
        }
        throw
    }
    if (-not $details) {
        return $null
    }
    # Az.Compute versions may omit Architecture; reject an explicit non-x64
    # value while retaining the known Windows/Gen2 SKU and OS-type checks.
    $architecture = $details.PSObject.Properties['Architecture']
    if ($details.HyperVGeneration -ne 'V2' -or
        ($architecture -and $architecture.Value -and $architecture.Value -ne 'x64') -or
        $details.OSDiskImage.OperatingSystem -ne 'Windows') {
        return $null
    }
    return [pscustomobject]@{ Sku = $SkuName; Version = $resolvedVersion }
}

# Read catalogs once and share the snapshot with local helper functions. This
# avoids repeated remote quota/SKU lookups while evaluating many alternatives.
$catalog = @(Get-AzComputeResourceSku -Location $Location)
$usage = @(Get-AzVMUsage -Location $Location)
$imageSkus = @(Get-AzVMImageSku -Location $Location -PublisherName MicrosoftWindowsServer -Offer WindowsServer |
    ForEach-Object { $_.Skus })
$failures = [System.Collections.Generic.List[string]]::new()
$alternatives = [System.Collections.Generic.List[object]]::new()
$vm = $catalog | Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VirtualMachineSize } |
    Select-Object -First 1
$vmProblems = @(Get-VMProblems $vm)
if ($vmProblems.Count -gt 0) {
    $failures.Add("VM size '$VirtualMachineSize': $($vmProblems -join '; ').")
    # Preserve the requested baseline capacity in recommendations, then prefer
    # smaller suitable machines. This ranks capacity, not current retail price.
    $choices = @($catalog | Where-Object {
        $_.ResourceType -eq 'virtualMachines' -and $_.Name -ne $VirtualMachineSize -and
        @(Get-VMProblems $_).Count -eq 0
    } | Where-Object {
        $caps = Get-Capabilities $_
        [int]$caps['vCPUs'] -ge 8 -and [double]$caps['MemoryGB'] -ge 32
    } | Sort-Object @{ Expression = { [int](Get-Capabilities $_)['vCPUs'] } },
        @{ Expression = { [double](Get-Capabilities $_)['MemoryGB'] } }, Name | Select-Object -First 5)
    foreach ($choice in $choices) {
        $caps = Get-Capabilities $choice
        $alternatives.Add([pscustomobject]@{
            Component = 'VM'; Selection = $choice.Name
            Details = "$($caps['vCPUs']) vCPU, $($caps['MemoryGB']) GiB; use -VirtualMachineSize '$($choice.Name)'"
        })
    }
    if ($choices.Count -lt 5) {
        $failures.Add("Only $($choices.Count) verified VM alternatives meet nesting, 8-vCPU/32-GiB, networking and quota requirements.")
    }
}

$image = Get-CompatibleImage -SkuName $ImageSku -Version $ImageVersion
if (-not $image) {
    $failures.Add("Image 'MicrosoftWindowsServer:WindowsServer:${ImageSku}:$ImageVersion' is unavailable or incompatible (requires a supported Windows Server Gen2/x64 SKU).")
    $count = 0
    # Year-prefixed names make descending order prefer newer Windows releases.
    # Concrete details are still queried for every image before it is offered.
    foreach ($name in @($imageSkus | Where-Object { $_ -ne $ImageSku } | Sort-Object -Descending)) {
        $choice = Get-CompatibleImage -SkuName $name -Version latest
        if ($choice) {
            $alternatives.Add([pscustomobject]@{
                Component = 'Image'; Selection = "MicrosoftWindowsServer:WindowsServer:$($choice.Sku):$($choice.Version)"
                Details = "Use -ImageSku '$($choice.Sku)' -ImageVersion '$($choice.Version)'"
            })
            $count++
            if ($count -eq 5) { break }
        }
    }
    if ($count -lt 5) {
        $failures.Add("Only $count verified compatible Windows Server image alternatives are available.")
    }
}

# Check both disks independently: the fixed OS size and configurable data size
# can fall into different regional tiers even when they share a disk SKU name.
foreach ($disk in @(
    @{ Component = 'OS disk'; Name = $OSDiskSku; SizeGB = 127; Parameter = 'OSDiskSku' },
    @{ Component = 'Data disk'; Name = $DataDiskSku; SizeGB = $DataDiskSizeGB; Parameter = 'DataDiskSku' }
)) {
    if (-not (Test-DiskSku -Name $disk.Name -SizeGB $disk.SizeGB)) {
        $failures.Add("$($disk.Component) SKU '$($disk.Name)' is unavailable, restricted, or does not support $($disk.SizeGB) GiB.")
        $choices = @('Standard_LRS', 'StandardSSD_LRS', 'StandardSSD_ZRS', 'Premium_LRS', 'Premium_ZRS' |
            Where-Object {
                $_ -ne $disk.Name -and (Test-DiskSku -Name $_ -SizeGB $disk.SizeGB) -and
                ($_ -notlike 'Premium*' -or ($vm -and (Get-Capabilities $vm)['PremiumIO'] -eq 'True'))
            } | Select-Object -First 5)
        foreach ($choice in $choices) {
            $alternatives.Add([pscustomobject]@{
                Component = $disk.Component; Selection = $choice
                Details = "Use -$($disk.Parameter) '$choice'; pricing/performance/redundancy may change"
            })
        }
        if ($choices.Count -lt 5) {
            $failures.Add("Only $($choices.Count) compatible $($disk.Component) alternatives exist for this configuration; Ultra/Premium v2 are not drop-in replacements.")
        }
    }
}

# Keep diagnostics structured; Deploy.ps1 decides how to display them and stop.
return [pscustomobject]@{
    Failures = $failures.ToArray()
    Alternatives = $alternatives.ToArray()
    Image = $image
}
