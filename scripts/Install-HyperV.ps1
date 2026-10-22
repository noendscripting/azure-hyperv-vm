<#
.SYNOPSIS
Installs the latest stable PowerShell 7, Hyper-V role, and host management tools.
.DESCRIPTION
Run elevated on the host or through Azure Run Command. Does not restart Windows:
Deploy.ps1 waits for this script's response, then requests a restart through Azure.
An already installed role can be processed again without removing guest VM files.
PowerShell is installed machine-wide from the Microsoft-signed x64 MSI, avoiding
WinGet/App Installer's user registration dependency when Run Command runs as SYSTEM.
The latest stable release is resolved from the official PowerShell GitHub repository.
An existing equal/newer PowerShell 7 installation is verified and reused.
.OUTPUTS
HYPERV_INSTALL_OK only after PowerShell verification, role installation, and boot
configuration succeed. Informational installation messages use the host stream.
.NOTES
The OS/SKU must expose nested virtualization. Actual hypervisor operation is
verified after the restart by Configure-HyperV.ps1, not by role installation.
Requires outbound HTTPS to api.github.com and GitHub release download endpoints,
plus access needed by Windows to validate the installer's signing certificate.
MSI failures retain a diagnostic log under ProgramData\AzureHyperV\Logs.
#>
#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitProcess) {
    throw 'Run this bootstrap in 64-bit Windows PowerShell to install x64 PowerShell.'
}

function Get-InstalledPowerShellVersion {
    param(
        [Parameter(Mandatory)] [string] $ExecutablePath,
        [Parameter(Mandatory)] [string] $WorkingDirectory
    )

    # Start a clean process at the explicit machine-wide path. PATH in the
    # current Run Command session does not refresh after an MSI installation.
    $versionOutput = Join-Path $WorkingDirectory 'pwsh-version.txt'
    $errorOutput = Join-Path $WorkingDirectory 'pwsh-error.txt'
    $probe = Start-Process -FilePath $ExecutablePath `
        -ArgumentList '-NoLogo -NoProfile -NonInteractive -Command "$PSVersionTable.PSVersion.ToString()"' `
        -RedirectStandardOutput $versionOutput -RedirectStandardError $errorOutput -Wait -PassThru
    if ($probe.ExitCode -ne 0) {
        throw "PowerShell version verification failed with exit code $($probe.ExitCode)."
    }
    $versionText = [string](Get-Content -LiteralPath $versionOutput -Raw)
    $version = $null
    if (-not [version]::TryParse($versionText.Trim(), [ref]$version)) {
        throw "PowerShell returned an invalid version: '$versionText'."
    }
    return $version
}

# GitHub's latest endpoint excludes draft/prerelease releases. Validate the
# response too, so a changed API/asset layout cannot produce a false success.
Write-Host 'Resolving the latest stable PowerShell release from the official repository.'
$release = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' `
    -Headers @{ 'User-Agent' = 'AzureHyperV-Bootstrap'; Accept = 'application/vnd.github+json' }
if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v([0-9]+\.[0-9]+\.[0-9]+)$') {
    throw 'The PowerShell release response did not identify a stable version.'
}
$targetVersion = [version]$Matches[1]
$assetName = "PowerShell-$targetVersion-win-x64.msi"
$assets = @($release.assets | Where-Object { $_.name -eq $assetName })
$expectedUri = "https://github.com/PowerShell/PowerShell/releases/download/v$targetVersion/$assetName"
if ($assets.Count -ne 1 -or $assets[0].browser_download_url -ne $expectedUri) {
    throw "The official release does not contain the expected x64 MSI: $assetName."
}

$workingDirectory = Join-Path $env:TEMP "AzureHyperV-PowerShell-$([guid]::NewGuid().ToString('N'))"
$pwshPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
New-Item -ItemType Directory -Path $workingDirectory | Out-Null
try {
    $installedVersion = if (Test-Path -LiteralPath $pwshPath -PathType Leaf) {
        Get-InstalledPowerShellVersion -ExecutablePath $pwshPath -WorkingDirectory $workingDirectory
    } else {
        $null
    }
    if ($installedVersion -and $installedVersion -ge $targetVersion) {
        Write-Host "PowerShell $installedVersion already meets the latest stable target $targetVersion; skipping MSI installation."
    } else {
        Write-Host "Downloading PowerShell $targetVersion x64 MSI."
        $msiPath = Join-Path $workingDirectory $assetName
        Invoke-WebRequest -Uri $expectedUri -OutFile $msiPath -UseBasicParsing | Out-Null
        $signature = Get-AuthenticodeSignature -FilePath $msiPath
        if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch '(^|,\s*)CN=Microsoft Corporation(,|$)') {
            throw 'The PowerShell MSI does not have a valid trusted Microsoft Corporation signature. Installation was blocked.'
        }

        # Retain diagnostic logs outside the temporary download directory.
        # Do not enable PowerShell remoting or add any inbound firewall rules.
        $logDirectory = Join-Path $env:ProgramData 'AzureHyperV\Logs'
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        $logPath = Join-Path $logDirectory "PowerShell-install-$([guid]::NewGuid().ToString('N')).log"
        Write-Host "Installing PowerShell $targetVersion. MSI log: $logPath"
        $arguments = "/i `"$msiPath`" /qn /norestart /L*v `"$logPath`" ADD_PATH=1 USE_MU=1 ENABLE_MU=1"
        $installer = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
            -ArgumentList $arguments -Wait -PassThru
        if ($installer.ExitCode -notin @(0, 3010)) {
            throw "PowerShell MSI installation failed with exit code $($installer.ExitCode). See $logPath."
        }
        if ($installer.ExitCode -eq 3010) {
            Write-Host 'PowerShell MSI requested a reboot; the deployment will perform it after Hyper-V installation.'
        }
        if (-not (Test-Path -LiteralPath $pwshPath -PathType Leaf)) {
            throw "PowerShell installation completed but $pwshPath was not found. See $logPath."
        }
        $installedVersion = Get-InstalledPowerShellVersion -ExecutablePath $pwshPath -WorkingDirectory $workingDirectory
        if ($installedVersion -lt $targetVersion) {
            throw "PowerShell version $installedVersion is older than required $targetVersion after MSI installation. See $logPath."
        }
        Write-Host "Verified PowerShell $installedVersion at $pwshPath."
    }
} finally {
    # Remove only this invocation's uniquely named download/probe directory.
    Remove-Item -LiteralPath $workingDirectory -Recurse -Force
}

# Continue in Windows PowerShell 5.1 for ServerManager/Hyper-V compatibility;
# installing PowerShell 7 does not replace Windows PowerShell or migrate this session.
$result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart:$false
if (-not $result.Success) {
    throw "Hyper-V installation failed: $($result.ExitCode)"
}

# Ensure the hypervisor is launched at the next boot. Native programs report
# failure through an exit code; ErrorActionPreference does not replace this check.
& bcdedit.exe /set hypervisorlaunchtype auto
if ($LASTEXITCODE -ne 0) {
    throw "Setting hypervisorlaunchtype failed with exit code $LASTEXITCODE."
}

# Deploy.ps1 treats this marker as part of the guest/host execution contract.
Write-Output 'HYPERV_INSTALL_OK'
