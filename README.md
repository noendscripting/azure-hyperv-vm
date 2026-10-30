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
* **WinNAT does not provide DHCP or DNS.** By default, give each guest a unique static
  `192.168.100.2` through `192.168.100.254` address, prefix length `24`, gateway
  `192.168.100.1`, and DNS `1.1.1.1` / `8.8.8.8` (or reachable organizational DNS).
  Do not reuse the gateway, network address `.0`, or broadcast address `.255`.
  For automatic addressing during Windows OOBE, optionally
  [configure DHCP on the host](#optional-host-dhcp-for-guest-oobe).
* Guest-to-guest traffic stays on the internal switch. Azure NSGs do not filter
  this traffic; use guest firewalls if isolation is needed.
* The build intentionally does **not** publish guest ports to the Internet.
  Manage guests from the host via VMConnect or PowerShell Direct. An NSG rule
  alone cannot make a NATed guest reachable. Publishing a guest would also need
  an explicit WinNAT static mapping and appropriate firewall/NSG rules.
* The host supports a single WinNAT internal prefix. Conflicting existing NAT
  configurations (for example HNS/containers) cause an explicit failure; the
  scripts do not silently remove them.

## Optional host DHCP for guest OOBE

The deployment configures WinNAT but **does not install DHCP Server**. Add the
Windows Server DHCP role manually if guests need automatic networking during
Windows out-of-box experience (OOBE), including Microsoft Entra join. DHCP supplies
an address, gateway, and DNS server addresses; WinNAT supplies translation. DHCP
does not create Internet egress or provide a DNS resolver.

Run the following on the **Hyper-V host in elevated Windows PowerShell 5.1**,
not on your deployment workstation or inside a guest. These are operator-run
configuration steps, not changes made automatically by `Deploy.ps1`.

### 1. Check prerequisites and existing configuration

* Confirm that the host itself has working outbound DNS/HTTPS and that
  `192.168.100.0/24` does not overlap VNet, peering, VPN, or on-premises networks.
* Inventory guest addresses, including powered-off guests. This example reserves
  `.100` through `.200` for DHCP; move conflicting static guests or choose a
  different unused pool before activating it. Keep static addresses outside
  that pool, or create explicit DHCP exclusions/reservations.
* Bind the DHCP service **only to `vEthernet (NestedNAT)`**. Never serve DHCP on
  the Azure-facing NIC. Disabling a DHCP **server binding** does not disable the
  Azure NIC's DHCP **client** or change its IP configuration.
* If DHCP Server is already installed, inspect its bindings, scopes, options,
  and leases in `dhcpmgmt.msc` before proceeding. The DHCP example below is for a
  fresh, dedicated installation; do not overwrite or disable another workload's
  DHCP configuration.

```powershell
$ErrorActionPreference = 'Stop'
Get-WindowsFeature Hyper-V, DHCP
Get-VMSwitch
Get-NetIPAddress -AddressFamily IPv4
Get-NetNat
Test-NetConnection www.microsoft.com -Port 443
```

### 2. Verify or create the internal switch and WinNAT

After a successful deployment these settings already exist. The following
network-only commands reuse correct settings and reject conflicts; unlike
rerunning the full host configuration script, they do not touch storage or
create a boot-test VM.

```powershell
$ErrorActionPreference = 'Stop'
$switchName = 'NestedNAT'
$gateway = '192.168.100.1'
$prefix = '192.168.100.0/24'

$switch = Get-VMSwitch | Where-Object Name -eq $switchName
if ($switch -and $switch.SwitchType -ne 'Internal') {
    throw 'NestedNAT exists but is not an internal switch. Review it manually.'
}
if (-not $switch) {
    New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
}
$adapter = Get-NetAdapter -Name "vEthernet ($switchName)"
$addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4)
$conflicts = @($addresses | Where-Object {
    $_.IPAddress -notlike '169.254.*' -and
    ($_.IPAddress -ne $gateway -or $_.PrefixLength -ne 24)
})
if ($conflicts.Count -gt 0) {
    throw 'The internal adapter has conflicting addresses. Review it manually.'
}
if (-not ($addresses | Where-Object { $_.IPAddress -eq $gateway -and $_.PrefixLength -eq 24 })) {
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $gateway -PrefixLength 24 | Out-Null
}
if (Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 |
        Where-Object DestinationPrefix -eq '0.0.0.0/0') {
    throw 'The internal adapter must not have a default gateway. Review its routes.'
}

$nats = @(Get-NetNat)
if ($nats | Where-Object Name -ne $switchName) {
    throw 'Another WinNAT configuration exists. Resolve the conflict without deleting it blindly.'
}
$nat = $nats | Where-Object Name -eq $switchName
if ($nat -and $nat.InternalIPInterfaceAddressPrefix -ne $prefix) {
    throw 'NestedNAT has a different internal prefix. Review it manually.'
}
if (-not $nat) {
    New-NetNat -Name $switchName -InternalIPInterfaceAddressPrefix $prefix | Out-Null
}
if (-not (Get-NetNat -Name $switchName).Active) {
    throw 'NestedNAT is not active.'
}
```

Do not add a default gateway to the internal adapter or change the Azure NIC's
DHCP, DNS, switch attachment, or default route.

### 3. Install DHCP Server and restrict its bindings

For a **new DHCP installation only**, run:

```powershell
$ErrorActionPreference = 'Stop'
if ((Get-WindowsFeature DHCP).Installed) {
    throw 'DHCP is already installed. Inspect existing configuration before making changes.'
}
$installation = Install-WindowsFeature DHCP -IncludeManagementTools
if (-not $installation.Success) {
    throw 'DHCP Server installation did not succeed.'
}
Add-DhcpServerSecurityGroup
Restart-Service DHCPServer
Set-Service DHCPServer -StartupType Automatic

$internalAlias = 'vEthernet (NestedNAT)'
$bindings = @(Get-DhcpServerv4Binding)
if (-not ($bindings | Where-Object InterfaceAlias -eq $internalAlias)) {
    throw 'DHCP cannot bind to NestedNAT. Check the internal adapter and its static IPv4 address.'
}
foreach ($binding in $bindings) {
    Set-DhcpServerv4Binding -InterfaceAlias $binding.InterfaceAlias `
        -BindingState ($binding.InterfaceAlias -eq $internalAlias)
}
# This guide serves IPv4 only.
foreach ($binding in @(Get-DhcpServerv6Binding)) {
    Set-DhcpServerv6Binding -InterfaceAlias $binding.InterfaceAlias -BindingState $false
}
Get-DhcpServerv4Binding
Get-DhcpServerv6Binding
```

Verify that only the internal IPv4 binding is enabled before creating an active
scope. The DHCP role installs Windows Firewall rules; ensure applicable DHCP
server rules permit client UDP 68 to server UDP 67 on the internal interface.
Keep Windows Firewall enabled. Do not open DHCP ports in Azure NSGs: guest DHCP
broadcasts remain on the internal switch. Recheck bindings after adding host NICs.

**AD-domain-joined host:** have an authorized AD administrator authorize the DHCP
server using the host's actual AD DNS name and appropriate static server address,
then verify it with `Get-DhcpServerInDC`. Follow your domain's DHCP policy; do not
bypass authorization. See the linked Microsoft installation guide for
`Add-DhcpServerInDC` examples. **Workgroup host:** skip AD authorization.
Microsoft Entra join of a guest does not require the host to join AD DS or
the installation of an AD domain controller.

### 4. Create the scope, gateway, and DNS options

The scope starts inactive so it cannot lease addresses before its options are
configured. These creation commands are not a rerunnable configuration script:
if the scope already exists, inspect it instead of deleting/recreating it.

```powershell
$ErrorActionPreference = 'Stop'
Add-DhcpServerv4Scope -Name 'NestedNAT guests' `
    -StartRange 192.168.100.100 -EndRange 192.168.100.200 `
    -SubnetMask 255.255.255.0 -State InActive
Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 `
    -Router 192.168.100.1 -DnsServer 1.1.1.1, 8.8.8.8
Set-DhcpServerv4Scope -ScopeId 192.168.100.0 -State Active

Get-Service DHCPServer
Get-DhcpServerv4Scope -ScopeId 192.168.100.0
Get-DhcpServerv4OptionValue -ScopeId 192.168.100.0
```

Replace the example public DNS servers with reachable organizational resolvers if
required by your egress policy. Do not use `192.168.100.1` as DNS unless you
separately install/configure a DNS service there; WinNAT is not a DNS proxy.

### 5. Verify a guest during OOBE

Create a guest connected to `NestedNAT` using the helper below and leave its
network adapter set to obtain IP and DNS automatically. A fresh Windows guest
should receive a lease during OOBE without a local administrator sign-in.

On the host, verify the connection and lease:

```powershell
Get-VMNetworkAdapter -VMName lab01 |
    Select-Object VMName, SwitchName, MacAddress, Status
Get-DhcpServerv4Lease -ScopeId 192.168.100.0
```

Where available, press **Shift+F10** in guest OOBE and run:

```text
ipconfig /renew
ipconfig /all
nslookup login.microsoftonline.com
```

Expect an address in `.100` through `.200`, mask `255.255.255.0`, gateway
`192.168.100.1`, and the configured DNS servers. From PowerShell in that guest,
`Test-NetConnection login.microsoftonline.com -Port 443` checks one sign-in
endpoint, not all Entra/Intune requirements. Return to OOBE and retry networking.
Use a supported Windows client edition (for example Pro or Enterprise, not Home)
and ensure tenant join/enrollment policy and required Microsoft endpoints allow
the intended flow. DHCP alone does not configure Entra join or Windows Autopilot.

For no lease or a `169.254.x.x` address, check switch attachment, guest DHCP-client
settings, server bindings, scope state/free addresses, authorization (if applicable),
Windows Firewall, and DHCP Server event logs. If a lease is present but Internet
access fails, check guest DNS/default route, host NAT, and upstream egress.

Existing guests configured with the static helper remain static: enabling the
server does not migrate them. To migrate one, record its old settings, then use
its console to select automatic IPv4 **and** DNS assignment and renew the lease.
Do not run the static helper on guests intended to use DHCP.

## Optional: prefer IPv4 on the host and Windows guests

To stop IPv6 being the preferred protocol, configure Windows to **prefer IPv4
over IPv6**, rather than disabling IPv6 or unchecking its adapter binding.
Microsoft recommends keeping IPv6 enabled because Windows components depend on
it. This machine-wide preference does not supply a DHCP lease or fix mismatched
WinNAT, gateway, or DHCP-scope settings.

Run the following in **elevated PowerShell separately on the host and inside
each Windows guest**. Changing the host does not change its guests. During guest
OOBE, where available, press **Shift+F10**, launch `powershell.exe`, and run the
same commands.

Record the existing `DisabledComponents` value before changing it. If Group
Policy or device management controls this setting, change the managing policy
instead. The guard below rejects existing IPv6-disable flags rather than
silently replacing another administrator's configuration.

```powershell
$ErrorActionPreference = 'Stop'
$path = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
$settings = Get-ItemProperty -LiteralPath $path
$existing = $settings.PSObject.Properties['DisabledComponents']
if ($null -ne $existing) {
    Write-Output "Previous DisabledComponents: $($existing.Value)"
    if ($existing.Value -notin @(0, 32)) {
        throw 'Existing IPv6 flags require review before changing protocol preference.'
    }
} else {
    Write-Output 'Previous DisabledComponents: absent (Windows default).'
}
New-ItemProperty -LiteralPath $path -Name DisabledComponents `
    -PropertyType DWord -Value 0x20 -Force | Out-Null
Get-ItemProperty -LiteralPath $path -Name DisabledComponents
```

`0x20` is decimal `32`: prefer IPv4 while keeping IPv6 enabled. **Restart each
changed machine for the setting to take effect.** Save guest work and shut down
nested VMs cleanly before restarting the host; a host restart interrupts every
guest. Run this only when ready, separately on each changed machine:

```powershell
Restart-Computer -Confirm
```

After restart, verify the registry value and effective address-selection policy
on both the host and each guest:

```powershell
Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' `
    -Name DisabledComponents
netsh interface ipv6 show prefixpolicies
```

Expect `DisabledComponents` to be `32` and the IPv4-mapped prefix
`::ffff:0:0/96` to have a higher precedence than `::/0`. Applications can still
explicitly use IPv6; this setting changes preference, not availability.
To undo the change, restore the recorded DWORD value, or remove only the
`DisabledComponents` value if it was originally absent, then restart again.

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

If you configured [host DHCP](#optional-host-dhcp-for-guest-oobe), leave the guest
on automatic IP/DNS assignment and skip the static helper below. For static-only
networking, after a **Windows** guest is installed, configure and test its network from the
host without needing an existing guest network connection:

```powershell
$guestCredential = Get-Credential -Message 'Administrator account inside lab01'
.\scripts\Set-NestedVMNetwork.ps1 `
    -VMName lab01 -IPAddress 192.168.100.10 -GuestCredential $guestCredential
```

This uses PowerShell Direct, sets the static IP/gateway/DNS, and checks outbound
DNS and TCP 443 to `www.microsoft.com`. Use a different address for each guest;
keep it outside any DHCP pool. The helper cannot detect addresses used by
powered-off VMs. For Linux or older
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
* [Install and configure DHCP Server on Windows Server](https://learn.microsoft.com/en-us/windows-server/networking/technologies/dhcp/quickstart-install-configure-dhcp-server)
* [DHCP Server IPv4 interface bindings](https://learn.microsoft.com/en-us/powershell/module/dhcpserver/set-dhcpserverv4binding)
* [Prefer IPv4 over IPv6 in Windows](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/configure-ipv6-in-windows)
* [Dsv5 series](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/dsv5-series)
* [Managed disk types](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-types)
* [Install PowerShell on Windows, including unattended MSI options](https://learn.microsoft.com/en-us/powershell/scripting/install/install-powershell-on-windows)
* [WinGet installation and App Installer registration](https://learn.microsoft.com/en-us/windows/package-manager/winget/)
