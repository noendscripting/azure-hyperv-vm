<#
.SYNOPSIS
Offline coverage of the machine-wide PowerShell installer and Hyper-V bootstrap.
.DESCRIPTION
Mocks downloads, signature checks, processes, file operations, and Windows role
installation. No software is installed and no real bootstrap files are deleted.
#>
BeforeAll {
    $path = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts\Install-HyperV.ps1'
    $source = Get-Content -LiteralPath $path -Raw
    $script:bootstrap = [scriptblock]::Create(($source -replace '(?m)^#Requires.*$', ''))
    function Install-WindowsFeature { param($Name, [switch]$IncludeManagementTools, [switch]$Restart) }
    function bcdedit.exe { param($Arguments) }
}

Describe 'Latest stable PowerShell and Hyper-V host bootstrap' {
    BeforeEach {
        $script:state = [pscustomobject]@{
            Present = $false
            VersionText = '7.6.7'
            InstalledVersionText = '7.6.7'
            InstallerExitCode = 0
            ProbeExitCode = 0
            CreateExecutable = $true
        }
        $state = $script:state
        $global:LASTEXITCODE = 0
        Mock Write-Host { }
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                tag_name = 'v7.6.7'; draft = $false; prerelease = $false
                assets = @([pscustomobject]@{
                    name = 'PowerShell-7.6.7-win-x64.msi'
                    browser_download_url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.7/PowerShell-7.6.7-win-x64.msi'
                })
            }
        }
        Mock Invoke-WebRequest { }
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = 'Valid'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US' }
            }
        }
        Mock New-Item { }
        Mock Remove-Item { }
        Mock Test-Path -MockWith ({ $state.Present }.GetNewClosure())
        Mock Get-Content -MockWith ({ $state.VersionText }.GetNewClosure())
        Mock Start-Process -MockWith ({
            param($FilePath)
            if ($FilePath -like '*\msiexec.exe') {
                $state.Present = $state.CreateExecutable
                $state.VersionText = $state.InstalledVersionText
                [pscustomobject]@{ ExitCode = $state.InstallerExitCode }
            } else {
                [pscustomobject]@{ ExitCode = $state.ProbeExitCode }
            }
        }.GetNewClosure())
        Mock Install-WindowsFeature { [pscustomobject]@{ Success = $true; ExitCode = 'Success' } }
        Mock bcdedit.exe { $global:LASTEXITCODE = 0 }
    }

    It 'installs the signed x64 MSI without rebooting and verifies pwsh before reporting success' {
        & $script:bootstrap | Should -Be 'HYPERV_INSTALL_OK'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
        }
        Should -Invoke Get-AuthenticodeSignature -Times 1 -Exactly
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -like '*\msiexec.exe' -and $ArgumentList -like '*/qn /norestart*' -and
            $ArgumentList -like '*ADD_PATH=1 USE_MU=1 ENABLE_MU=1*' -and $Wait -and $PassThru
        }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -like '*\PowerShell\7\pwsh.exe' -and $ArgumentList -like '*-NoProfile -NonInteractive*'
        }
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -like '*\AzureHyperV-PowerShell-*' -and $Recurse -and $Force
        }
        Should -Invoke Install-WindowsFeature -Times 1 -Exactly -ParameterFilter { -not $Restart }
    }

    It 'skips MSI installation when an equal or newer stable version is already installed' -ForEach @(
        @{ Version = '7.6.7' }, @{ Version = '7.7.0' }
    ) {
        $script:state.Present = $true
        $script:state.VersionText = $Version
        & $script:bootstrap | Should -Be 'HYPERV_INSTALL_OK'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly -ParameterFilter { $FilePath -like '*\msiexec.exe' }
    }

    It 'upgrades an older installation and verifies it again' {
        $script:state.Present = $true
        $script:state.VersionText = '7.4.0'
        & $script:bootstrap | Should -Be 'HYPERV_INSTALL_OK'
        Should -Invoke Start-Process -Times 2 -Exactly -ParameterFilter { $FilePath -like '*\pwsh.exe' }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -like '*\msiexec.exe' }
    }

    It 'accepts reboot-required MSI status without allowing MSI to restart the host' {
        $script:state.InstallerExitCode = 3010
        & $script:bootstrap | Should -Be 'HYPERV_INSTALL_OK'
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*requested a reboot*' }
    }

    It 'blocks an unsigned or untrusted download before executing the installer' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null }
        }
        { & $script:bootstrap } | Should -Throw '*valid trusted Microsoft Corporation signature*'
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Install-WindowsFeature -Times 0 -Exactly
        Should -Invoke Remove-Item -Times 1 -Exactly
    }

    It 'blocks a valid signature from a different publisher' {
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Other Publisher, C=US' }
            }
        }
        { & $script:bootstrap } | Should -Throw '*signature*'
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'fails explicitly on MSI errors and cleans only temporary download files' {
        $script:state.InstallerExitCode = 1603
        { & $script:bootstrap } | Should -Throw '*exit code 1603*'
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -like '*\AzureHyperV-PowerShell-*'
        }
        Should -Invoke Install-WindowsFeature -Times 0 -Exactly
    }

    It 'does not claim success if the MSI fails to create the executable' {
        $script:state.CreateExecutable = $false
        { & $script:bootstrap } | Should -Throw '*was not found*'
        Should -Invoke Install-WindowsFeature -Times 0 -Exactly
    }

    It 'does not claim success if the installed version is still too old' {
        $script:state.InstalledVersionText = '7.4.0'
        { & $script:bootstrap } | Should -Throw '*older than required*'
        Should -Invoke Install-WindowsFeature -Times 0 -Exactly
    }

    It 'does not claim success if pwsh cannot execute' {
        $script:state.ProbeExitCode = 1
        { & $script:bootstrap } | Should -Throw '*version verification failed*'
        Should -Invoke Install-WindowsFeature -Times 0 -Exactly
    }

    It 'rejects invalid version output from pwsh' {
        $script:state.InstalledVersionText = 'unexpected output'
        { & $script:bootstrap } | Should -Throw '*invalid version*'
    }

    It 'rejects preview releases instead of deploying them as stable' {
        Mock Invoke-RestMethod { [pscustomobject]@{ tag_name = 'v7.7.0-preview.1'; draft = $false; prerelease = $true } }
        { & $script:bootstrap } | Should -Throw '*stable version*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'rejects a release that does not contain the expected official MSI URL' {
        Mock Invoke-RestMethod {
            [pscustomobject]@{
                tag_name = 'v7.6.7'; draft = $false; prerelease = $false
                assets = @([pscustomobject]@{ name = 'PowerShell-7.6.7-win-x64.msi'; browser_download_url = 'https://example.invalid/installer.msi' })
            }
        }
        { & $script:bootstrap } | Should -Throw '*expected x64 MSI*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'propagates download failures and cleans the temporary directory' {
        Mock Invoke-WebRequest { throw 'Download failed' }
        { & $script:bootstrap } | Should -Throw '*Download failed*'
        Should -Invoke Remove-Item -Times 1 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
    }

    It 'still requires successful Hyper-V role installation after installing PowerShell' {
        Mock Install-WindowsFeature { [pscustomobject]@{ Success = $false; ExitCode = 'Failed' } }
        { & $script:bootstrap } | Should -Throw '*Hyper-V installation failed*'
        Should -Invoke bcdedit.exe -Times 0 -Exactly
    }
}
