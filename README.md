# Azure nested Hyper-V host

End-to-end ARM and PowerShell build based on the structure of
[vm-base.json](https://raw.githubusercontent.com/noendscripting/azuredeploy/refs/heads/master/vm-base.json).
It provisions the Azure host, installs Hyper-V, restarts Windows, configures storage
and nested networking, then boots and removes a temporary diskless VM to verify
that nested virtualization actually works.

## Defaults

| Component | Configuration |
| --- | --- |
| Host | `Standard_D8s_v5`: 8 vCPUs, 32 GiB RAM |
| OS | Windows Server 2025 Datacenter, Desktop Experience, Gen2 (`MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:latest`) |
| Security type | Explicit `Standard`; not Trusted Launch or Confidential VM |
| OS disk | 127 GiB, `StandardSSD_LRS` |
| Data disk | 256 GiB, **`Standard_LRS` (Standard HDD LRS)**, LUN 0, no host caching |
| Data volume | `F:`, GPT/NTFS, 64-KiB allocation units, label `HyperVData` |
| VM configuration files | `F:\Hyper-V\VMs` |
| Virtual disks / ISO files | `F:\Hyper-V\Virtual Hard Disks` / `F:\Hyper-V\ISO` |
| Azure network | Private NIC in your existing subnet, accelerated networking; no VNet or subnet creation |
| Management / outbound | Your existing VPN and network egress; no public IP, NSG, or RDP rule creation |
| Nested network | Internal switch `NestedNAT`, WinNAT `192.168.100.0/24`, host gateway `192.168.100.1` |
| Region | `centralus`, non-zonal; must match the existing VNet |

There are exactly two attached managed disks. This SKU has no local temporary
disk. Standard HDD is the cheapest managed disk tier, **not** the fastest choice
for running multiple guests. It has capacity-tier billing and transaction costs;
the VM, OS disk, and bandwidth are also billable. There is no public IP, NAT
Gateway, Bastion, paid bootstrap storage, or Windows Admin Center extension.

Availability changes; the deployment script checks the existing VNet region and
subnet, VM size, subscription restrictions, nested-capable family, Gen2,
accelerated networking, regional/family vCPU quota, OS image, and both disk SKUs
and their capacity limits before creating deployment resources.

## Deploy

Use PowerShell 7.2+ on the deployment workstation and an account allowed to create
resource groups, NICs, managed disks, VMs, and execute VM Run Command, plus read
the existing VNet and join its subnet. The subnet can be in a different resource
group but must be in the same subscription and region as the VM.
Install the existing Azure PowerShell modules if needed:

```powershell
Install-Module Az -Scope CurrentUser
Connect-AzAccount

$password = Read-Host 'Host administrator password (12+ characters, Azure complexity rules)' -AsSecureString
.\Deploy.ps1 `
    -SubscriptionId '<subscription-guid>' `
    -AdminPassword $password `
    -VNetResourceGroupName '<network-rg>' `
    -VNetName '<existing-vnet>' `
    -SubnetName '<existing-subnet>'
```

Do not put the password in source control or command-line plaintext. It is passed
as a `SecureString` to ARM's `securestring` parameter, not written to a parameter
file or sent to the host configuration scripts.

All three network names are mandatory command-line parameters with no hardcoded
defaults. The subnet resource ID is built automatically from those names and
`SubscriptionId`.

Supply an ordinary VM subnet, not `GatewaySubnet`, `AzureBastionSubnet`, or a
subnet delegated exclusively to another service. The build does not create or
modify your VNet, subnet, VPN, routes, DNS, NSGs, or outbound connectivity.

To change the name and disk capacity:

```powershell
.\Deploy.ps1 `
    -SubscriptionId '<subscription-guid>' `
    -ResourceGroupName 'rg-hyperv-lab' `
    -VirtualMachineName 'hyperv02' `
    -Location 'centralus' `
    -DataDiskSizeGB 512 `
    -AdminPassword $password `
    -VNetResourceGroupName '<network-rg>' `
    -VNetName '<existing-vnet>' `
    -SubnetName '<existing-subnet>'
```

Add `-ValidateOnly` to run preflight and ARM validation without creating a VM.
**This mode creates the resource group if necessary.** Do not run validation
against an unapproved subscription/resource group. A normal build creates
billable resources and restarts the host even on reruns. Do not rerun it while
guests are in use. Insufficient quota or a location restriction stops the build
before resource group creation. ARM errors and guest script failures stop the
build explicitly.

### Monitoring execution

The script prints timestamped status messages with total elapsed time and a
stage number, and displays a PowerShell progress bar. A normal deployment has
10 stages; `-ValidateOnly` has 5. Percentages represent workflow stages, not
Azure resource completion or a time estimate.

Messages identify module/network checks, regional preflight, resource group
creation, ARM validation/deployment, Hyper-V installation, restart, VM agent
readiness, and host configuration/boot verification. During the post-restart
wait, each poll reports VM running/agent ready status and the timeout remaining,
with 15-second pauses between unsuccessful polls.

ARM and guest Run Command operations are synchronous. Their stage remains
visible while they execute; guest output is printed when Run Command returns,
not streamed live. For resource-level ARM details, open the named
`<VM-name>-build` deployment under your resource group's **Deployments** page.
Timestamped status messages remain visible even in hosts that hide progress
bars, and can be captured using PowerShell's `Start-Transcript` /
`Stop-Transcript`. Status messages do not replace the final result object.
On failure, the current stage is reported and the original error is rethrown.
The progress bar is cleared on success, validation-only completion, and failure.

### Regional availability and alternatives

`Deploy.ps1` checks the actual subscription's regional compute catalog, not just
whether a SKU name exists globally. Zone-only restrictions do not block this
non-zonal build. VM choices are limited to Intel Dsv3-v5/Esv3-v5 families suitable
for this nested Hyper-V/SCSI/Standard-security configuration.

For images, Azure PowerShell's `Get-AzVMImage -Version latest` can return a
version-list record with no `HyperVGeneration`. That missing metadata does not
mean the image is unavailable. The build resolves the latest published version,
queries its concrete details, verifies Windows/Gen2/x64 compatibility, and passes
the exact verified version to ARM.

If any selected component fails preflight, the script reports all detected
availability/compatibility problems and offers **up to five verified alternatives
per failed component**, with command-line arguments to select them. VM alternatives
have at least 8 vCPUs/32 GiB RAM and pass networking, regional restrictions, and
quota checks. Image alternatives are verified Windows Server 2025/2022/2019
Gen2 images, preferring newer releases. Older OS versions and Server Core are
explicit choices, never automatic substitutions.

There may be fewer than five valid alternatives, particularly for disks: this
build supports Standard HDD, Standard SSD LRS/ZRS, and Premium SSD LRS/ZRS.
Ultra Disk and Premium SSD v2 are not drop-in OS/data-disk replacements in this
configuration. The script reports the actual count rather than listing
unavailable or incompatible options. Premium alternatives require PremiumIO
support on the selected VM. Disk alternatives may cost more; `Standard_LRS`
remains the default low-cost data disk.

Select the displayed choices by adding the relevant arguments to your existing
deployment command:

```powershell
# Examples only: use the regional alternatives printed by your own preflight.
-VirtualMachineSize 'Standard_D16s_v5'
-ImageSku '2022-datacenter-g2' -ImageVersion '<verified-version>'
-OSDiskSku 'StandardSSD_LRS' -DataDiskSku 'Standard_LRS'
```

`ImageSku` is within `MicrosoftWindowsServer:WindowsServer`. `ImageVersion`
defaults to `latest`, or accepts a concrete `major.minor.build` version.
No alternatives are applied automatically. Preflight failures stop before
resource group creation; authentication/service errors propagate instead of
being misreported as SKU unavailability. Catalog checks cannot guarantee live
allocation capacity; ARM validation and deployment remain authoritative.
Larger Dsv3/v4 or Esv3/v4 alternatives may have a local temporary disk in addition
to the two managed disks; temporary storage is never used for VM images.

The workflow is:

1. Validate inputs, existing subnet/VNet region, selected subscription, SKU/image availability, and vCPU quota.
2. Create the resource group and validate/deploy [azuredeploy.json](azuredeploy.json).
3. Run [Install-HyperV.ps1](scripts/Install-HyperV.ps1) using Azure VM Run Command
   to install the latest stable PowerShell 7 and the Hyper-V role/tools.
4. Restart through Azure and wait up to 15 minutes for the VM agent.
5. Run [Configure-HyperV.ps1](scripts/Configure-HyperV.ps1), including the nested VM boot test.
6. Return the host's private IP and host/guest network settings.

**Deploy.ps1 is the end-to-end entry point.** Deploying only the ARM JSON creates
Azure infrastructure; it does not install or configure Hyper-V. There are no
external linked templates or publicly hosted script dependencies.

### PowerShell 7 on the Hyper-V host

The host bootstrap installs the latest **stable** x64 PowerShell 7 machine-wide,
alongside Windows PowerShell 5.1. It resolves the official
`PowerShell/PowerShell` GitHub release, downloads that version's MSI, validates
its trusted Microsoft Corporation Authenticode signature, installs silently
without rebooting, and executes the installed `pwsh.exe` to verify its version.
An equal/newer installed version is reused. MSI exit code `3010` (reboot required)
is deferred to the existing Hyper-V restart; other installer failures stop the build.
MSI logs are retained in `%ProgramData%\AzureHyperV\Logs`; temporary downloads
and version-probe files are removed.

The MSI adds PowerShell to the machine PATH and enables Microsoft Update
integration (`USE_MU=1`, `ENABLE_MU=1`), subject to your organization's update
policies. Open a new session after installation or run
`C:\Program Files\PowerShell\7\pwsh.exe` explicitly. Bootstrap and Hyper-V
configuration scripts continue using Windows PowerShell 5.1; installing PowerShell
7 does not switch the current process or configure PowerShell remoting.
This installs PowerShell on the **host**, not inside nested guest VMs.

Your existing network egress must permit HTTPS to `api.github.com`, `github.com`,
GitHub release asset download endpoints, and the endpoints needed for Windows
certificate trust/revocation checks. Failure to download or verify the installer
is explicit; the bootstrap does not silently continue without PowerShell 7.

For comparison, on **Server 2025 Desktop Experience**, an interactive user can
register App Installer and use WinGet:

```powershell
Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
winget install --id Microsoft.PowerShell --source winget
```

Those commands are not used by this unattended build: App Installer registration
is user-specific, Azure Run Command runs as SYSTEM, and WinGet is not included
on Server 2022/2019 or Server 2025 Core. Microsoft's signed MSI supports unattended
installation without relying on that interactive registration.

## Why this networking works in Azure

```text
Nested VM: 192.168.100.10/24
    gateway: 192.168.100.1
    DNS: 1.1.1.1, 8.8.8.8
          |
    NestedNAT (internal Hyper-V switch)
          |
    WinNAT on the Hyper-V host
          |
    Host Azure NIC: private IP in your existing subnet
          |
    Existing VNet routes/firewall/NAT or VPN egress -> Internet
```

* Do **not** create an external virtual switch on the Azure NIC. The Azure fabric
  does not expose nested guests as independent L2/MAC endpoints.
* WinNAT translates nested guest traffic to the host's address. Azure NIC IP
  forwarding and MAC address spoofing are not needed for this topology.
* The internal host adapter has `192.168.100.1/24`, **no default gateway** and no
  custom DNS changes. The Azure NIC retains DHCP, the existing VNet's DNS settings, its default route,
  and its management connectivity.
* Management uses your existing VPN to the host's private IP. No inbound RDP
  source parameter or deployment-created rule is required. Existing NSGs and
  Windows Firewall must still allow whichever management protocol you use.
  VPN connectivity itself does not replace a management protocol.
* Your existing network must provide outbound access, for example through an
  existing NAT Gateway, Azure Firewall, or routed on-premises egress. A VPN alone
  does not guarantee Internet egress. Azure VM Agent/Run Command needs access
  to its Azure service endpoints; nested guests need egress after host NAT.
  The build does not add egress resources or alter subnet outbound settings.
* The nested `192.168.100.0/24` prefix must not overlap your VNet, peered networks,
  or VPN/on-premises routes. Verify this before deployment.
* **WinNAT does not provide DHCP or DNS.** Give each guest a unique static
  `192.168.100.2` through `192.168.100.254` address, prefix length `24`, gateway
  `192.168.100.1`, and DNS `1.1.1.1` / `8.8.8.8` (or reachable organizational DNS).
  Do not reuse the gateway, network address `.0`, or broadcast address `.255`.
* Guest-to-guest traffic stays on the internal switch. Azure NSGs do not filter
  this traffic; use guest firewalls if isolation is needed.
* The build intentionally does **not** publish guest ports to the Internet.
  Manage guests from the host via VMConnect or PowerShell Direct. An NSG rule
  alone cannot make a NATed guest reachable. Publishing a guest would also need
  an explicit WinNAT static mapping and appropriate firewall/NSG rules.
* The host supports a single WinNAT internal prefix. Conflicting existing NAT
  configurations (for example HNS/containers) cause an explicit failure; the
  scripts do not silently remove them.

## Create and network a guest

Connect to the host's returned private IP over your VPN using your preferred
management method, copy the repository's guest helper scripts to the
host, and open **elevated Windows PowerShell**. Supply your own licensed guest
OS installation ISO, for example at `F:\Hyper-V\ISO\server.iso`.

```powershell
.\scripts\New-NestedVM.ps1 -Name 'lab01' -IsoPath 'F:\Hyper-V\ISO\server.iso'
vmconnect.exe localhost lab01
```

The helper creates a Gen2 VM with 2 vCPUs, 8 GiB fixed RAM, and a dynamically
expanding 64-GiB VHDX on the data volume. Complete the guest installation in
VMConnect. For a Linux guest, pass `-GuestOS Linux` to select the Linux-compatible
Secure Boot certificate template.

To enable a **virtual TPM** on a new guest, add the opt-in switch:

```powershell
.\scripts\New-NestedVM.ps1 `
    -Name 'lab-tpm01' -IsoPath 'F:\Hyper-V\ISO\server.iso' -EnableVTPM
```

The script assigns a local key protector with `Set-VMKeyProtector
-NewLocalKeyProtector`, enables vTPM with `Enable-VMTPM`, and confirms
`Get-VMSecurity` reports `TpmEnabled` before the first boot. Secure Boot remains
enabled with the existing Windows/Linux certificate selection. If key protection
or vTPM configuration fails, the error is returned and the new VM is not started;
its partial configuration is retained for inspection. Omitting the switch keeps
the previous behavior. This option applies only to a **new nested guest**, not
the Azure host's TPM/security profile, and is also available with `-GuestOS Linux`.

**Recovery/migration:** this is a host-local key protector, not an HGS/shielded VM
configuration. Preserve the host key material and guest configuration, and keep
BitLocker recovery keys separately. Plan key transfer/recovery before migrating
or restoring to another Hyper-V host; copying a VHDX alone does not preserve
vTPM state or guarantee that the VM can boot. Do not casually replace an existing
encrypted VM's protector or clear its TPM.

After a **Windows** guest is installed, configure and test its network from the
host without needing an existing guest network connection:

```powershell
$guestCredential = Get-Credential -Message 'Administrator account inside lab01'
.\scripts\Set-NestedVMNetwork.ps1 `
    -VMName lab01 -IPAddress 192.168.100.10 -GuestCredential $guestCredential
```

This uses PowerShell Direct, sets the static IP/gateway/DNS, and checks outbound
DNS and TCP 443 to `www.microsoft.com`. Use a different address for each guest;
the helper cannot detect addresses used by powered-off VMs. For Linux or older
Windows guests without PowerShell Direct support, configure the same settings
inside the guest using its native network tools. Disconnect the ISO or adjust
the firmware boot order after installation.

Guest OS downloads, installation, licensing, backups, and high availability are
not included. Budget RAM and vCPU allocations across guests; leave capacity for
the host. Nested VMs do not become Azure VM resources or receive individual
Azure VM agents. The diskless boot test verifies nesting, not guest Internet
access; the guest network helper performs that separate test after OS install.

## Verify and recover

In elevated Windows PowerShell on the host:

```powershell
Get-WindowsFeature Hyper-V
Get-Service vmms
Get-VMHost | Select-Object VirtualMachinePath, VirtualHardDiskPath
Get-Disk | Format-Table Number, BusType, PartitionStyle, IsBoot, IsSystem
Get-Volume -DriveLetter F
Get-VMSwitch -Name NestedNAT
Get-NetIPAddress -InterfaceAlias 'vEthernet (NestedNAT)' -AddressFamily IPv4
Get-NetNat -Name NestedNAT
```

Configuration is repeatable: existing correct storage/switch/NAT is reused.
Only an uninitialized, non-OS SCSI disk at LUN 0 can be formatted. An initialized
disk must already have the expected `F:` NTFS volume and label; conflicting
drives, switches, addresses, or NATs cause a failure rather than destructive
reconfiguration. Do not resize/shrink or recreate populated disks by blindly
redeploying the template; plan disk expansion and guest downtime explicitly.

If Azure infrastructure deployed but a host step failed, inspect the error and
Azure Run Command output/boot diagnostics. Resolve the cause and invoke the
specific local host script through `Invoke-AzVMRunCommand`, or run it elevated
on the host. After installing Hyper-V, restart before configuration.
No rollback deletes data or billable resources on failure.

To stop compute billing, shut down guests cleanly and **deallocate the Azure
host**, not just shut down Windows. Managed disks remain billable.
To remove everything, first back up any required VHDX files, then explicitly
delete the dedicated VM resource group using Azure tooling. Keep it separate
from the existing network resource group so that cleanup does not remove your
VNet or VPN. If an older public-IP version of this build was deployed previously,
incremental ARM deployment does not delete its old public IP, NSG, or VNet:
review and explicitly remove unused old resources after verifying VPN access.

## Code documentation

Each operational PowerShell script includes comment-based help describing where
it runs, its parameters, outputs, prerequisites, and safety boundaries. Read it
without executing a deployment:

```powershell
Get-Help .\Deploy.ps1 -Full
Get-Help .\scripts\Configure-HyperV.ps1 -Full
Get-Help .\scripts\Test-DeploymentAvailability.ps1 -Full
```

Inline comments explain storage safeguards, image-version resolution, NAT design,
failure handling, and the mocked test harness. The ARM template uses valid JSON
`metadata.description` fields and resource `comments` fields instead of JSON
comment syntax. Its top-level metadata also records the current security-setting
discrepancy: the resource requests `TrustedLaunch`, while the original design and
security contract test expect `Standard`. Documentation does not change that
setting or bypass the test.

## Local tests

With Pester 5 installed:

```powershell
Invoke-Pester -Path .\tests -Output Detailed
```

The tests validate JSON/PowerShell syntax, the template contract, deployment
orchestration/error handling, and mocked host/guest storage and network safety,
repeatability, and boot validation. They do not provision Azure resources.
Real ARM validation is available through
`Deploy.ps1 -ValidateOnly`; complete provisioning and guest Internet access
require a user-authorized Azure deployment.

## Microsoft references

* [Nested virtualization overview](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization)
* [Azure nested virtualization and NAT](https://learn.microsoft.com/en-us/azure/lab-services/how-to-enable-nested-virtualization-template-vm)
* [Hyper-V NAT networking](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/setup-nat-network)
* [Dsv5 series](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/dsv5-series)
* [Managed disk types](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types)
* [Install PowerShell on Windows, including unattended MSI options](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows)
* [WinGet installation and App Installer registration](https://learn.microsoft.com/en-us/windows/package-manager/winget/)
