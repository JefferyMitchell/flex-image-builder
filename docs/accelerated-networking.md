---
layout: default
title: Accelerated Networking
nav_order: 10
---

# Accelerated Networking
{: .no_toc }

<details open markdown="block">
  <summary>Contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Summary

Every Platform Flex catalog should have Azure accelerated networking on. It's a **per-catalog setting that can only be chosen when the catalog is created**:

| How the catalog is created | Accelerated networking | Notes |
|---|---|---|
| Terraform, `citrix/citrix` **v1.0.43 or later**, this repo's modules | **On** (module default) | The modules pass `enable_accelerated_networking`, default `true` |
| Terraform, `citrix_quickdeploy_catalog` written directly, attribute not set | **Off** | The provider's default is `false` |
| Terraform, provider v1.0.42 or earlier | **Off** | No attribute; the modules need `>= 1.0.43` |
| Catalog Service API, `POST catalogs/$manageddeploy`, without the field | **Off** | Add `addCatalog.enableAcceleratedNetworking: true` |
| `10-create-catalog.ps1` (this repo, **test script**) | **On**, checked after create | No longer needed for Terraform users |

The image pipeline (Packer, gallery export, `06-import-to-citrix.ps1`) needs **no change**: the setting isn't part of the image, and the Windows 11 and Server 2025 images built here already have the driver.

Changing it on an existing catalog **replaces** the catalog: the provider deletes it and creates a new one. For a domain-joined catalog, the delete fails unless you run it with credentials. See [Changing it on an existing catalog](#changing-it-on-an-existing-catalog).

> **Known issue, Server 2025 builds before 26100.33828.** About a minute after boot, `Get-NetAdapter` shows the Mellanox adapter *Not Present*, but the VF still carries all the traffic. The machine is accelerated: check byte counters, not adapter status. Citrix's own Server 2025 + VDA 2607 LTSR image (August 2026, 26100.33296) is affected. See [Known issue: Server 2025 shows the VF as Not Present](#known-issue-server-2025-shows-the-vf-as-not-present).

---

## What was tested

Lab: westus3, Citrix-managed capacity, VNet peering, domain-joined. On AMD Dasv5 sizes accelerated networking is *supported* but not *required*, so Azure follows the catalog flag.

| Test | Catalog created by | Image | Size | Flag (read back) | In the guest |
|---|---|---|---|---|---|
| T1a baseline | Terraform v1.0.41 | Windows 11 26H2, Packer | D2as_v5 | `false` | Hyper-V adapter only |
| T1b baseline | Citrix (lab automation) | Server 2025, Citrix-prepared | D2as_v5 | `false` | Hyper-V adapter only |
| T2 | API, `10-create-catalog.ps1` | Server 2025, Packer | D2as_v5 | `true` | Mellanox VF, Up |
| T3 | Terraform, pre-release provider build | Windows 11 26H2, Packer | D2as_v5 | `true` | Mellanox VF, Up |
| **1.0.43 TC1** | Terraform **v1.0.43**, single-session module | Windows 11 26H2, Packer | D2as_v5 | `true` | Mellanox VF, Up at +240s, 4 of 4 boots |
| **1.0.43 TC4** | TC1 after an in-place image update | Windows 11 26H2, Packer (second copy) | D2as_v5 | `true` | Mellanox VF, Up |
| **1.0.43 TC6** | Terraform v1.0.43, `machine_size = "d2asv5"` | Server 2025, Packer | D2as_v5 | `true` | Mellanox VF, Up at +240s, 3 of 3 boots |
| **1.0.43 TC2b** | Terraform v1.0.43, multi-session module, `Task worker (light)` | Server 2025, Packer (26100.33674) | **D8as_v5** | `true` | Mellanox adapter Up at boot, *Not Present* by +240s, 5 of 5 boots (see the retest) |
| **1.0.43 TC7** | Terraform v1.0.43, multi-session module, `Task worker (light)` | Server 2025 + VDA 2607 LTSR, **Citrix-prepared** (26100.33296) | **D8as_v5** | `true` | Mellanox adapter Up at boot, *Not Present* by +240s, 3 of 3 boots (see the retest) |

Upgrading from v1.0.42 to v1.0.43 with an existing catalog plans **no changes**: the refresh fills in `enable_accelerated_networking = false`.

**Retest of TC2b and TC7.** Two westus3 tenants, catalogs created with `10-create-catalog.ps1`, every power cycle on a different Azure host. In-guest sampling every 5 seconds from boot to +600s, and on some boots a 200 MB copy to a file share and back with per-adapter byte counters before and after:

| Image (build) | Size | Boots | Mellanox adapter in `Get-NetAdapter` | Byte counters during the copy |
|---|---|---|---|---|
| Server 2025 + VDA 2607 LTSR, Citrix-prepared (26100.33296) | D8as_v5 | 8 | *Not Present* by +45–104s, every boot | All of it on the VF |
| Server 2025 + VDA 2607 LTSR, Citrix-prepared (26100.33296) | D4as_v5 | 6 | *Not Present* by +55–78s, every boot | All of it on the VF |
| Server 2025, Packer (26100.33674, the TC2b image) | D8as_v5 | 2 | *Not Present*, every boot | All of it on the VF |
| Server 2025, Packer (26100.33828) | D8as_v5 | 3 | **Up** to +600s, every boot | All of it on the VF |
| Server 2025, Packer (26100.33828) | D2as_v5 | 3 | Up | — |
| Windows 11 26H2, Packer | D8as_v5, D4as_v5 | 7 | Up | — |

So TC2b and TC7 never lost the VF: Windows stopped reporting it. See the [known issue](#known-issue-server-2025-shows-the-vf-as-not-present).

---

## Terraform (v1.0.43 and later)

The catalog modules pass `enable_accelerated_networking` to `citrix_quickdeploy_catalog`. It defaults to `true` and can't be `null`:

```hcl
module "catalog" {
  source = "../../modules/catalog-multisession"
  # ...
  enable_accelerated_networking = true   # the default; set false only to match an existing catalog that's off
}
```

- **The examples require `citrix/citrix >= 1.0.43`.** Older providers reject the argument outright (*"An argument named "enable_accelerated_networking" is not expected here"*).
- **The variable is `nullable = false`.** Passing `null` to the provider gives `false`, its own default, even if the module's default is `true`. With `nullable = false`, a `null` from a caller falls back to the module default.
- **It can only be set at creation.** Changing it replaces the catalog: see the next section.

---

## Changing it on an existing catalog

`false → true` (or back) plans `-/+ destroy and then create replacement`. Expect downtime: the old catalog is deleted before the new one is created.

**On a domain-joined catalog the provider's delete fails.** It doesn't send the join account, so the catalog goes to `Error` (*"username, domainName, and password must be provided when validating account information"*), and Terraform stops before it creates the new one. Until the provider sends credentials on delete, do it in two steps:

```powershell
$env:TF_VAR_domain_service_account_password = "<join account password>"
# 1. Credentialed delete, then remove the catalog from state
.\packer\scripts\powershell\08-delete-catalog.ps1 -CatalogName "<name>" -TerraformDir <dir> -Confirm:$false
# 2. Create the replacement with the new setting
terraform -chdir=<dir> apply
```

If you already ran `apply` and the catalog is in `Error`, step 1 also recovers it: `08` re-sends the credentialed delete.

---

## Importing an existing catalog

`terraform import` doesn't fill in `persona` or `on_prem_connectivity.domain_identity`, and both force replacement. So **the first plan after importing a persona-based or domain-joined catalog always replaces it**, whatever `enable_accelerated_networking` says. That has been true since at least v1.0.42.

Only a direct `citrix_quickdeploy_catalog` resource can work around it, because the modules can't take a `lifecycle` block from the caller:

```hcl
resource "citrix_quickdeploy_catalog" "this" {
  # ... same settings as the catalog, including enable_accelerated_networking = true if it's on
  lifecycle {
    ignore_changes = [persona, on_prem_connectivity]
  }
}
```

With that, the plan after import showed *"No changes"*. **Never apply an import whose plan says "must be replaced".**

---

## Creating a catalog with the API (test script)

`10-create-catalog.ps1` is a **test script** for the API path. Terraform users don't need it from provider v1.0.43 on.

```powershell
$env:TF_VAR_domain_service_account_password = "<join account password>"
.\packer\scripts\powershell\10-create-catalog.ps1 `
    -Name "Task Worker" -ImageName "<image>" -SessionType MultiSession `
    -Region <azure-region> -VmSize Standard_D2as_v5 -NumberOfUsers 2 `
    -VnetPeeringName "<network connection>" `
    -Domain corp.example -DomainOu "OU=VDAs,DC=corp,DC=example" -ServiceAccount svc-join
```

The script reads the catalog back and fails if `enableAcceleratedNetworking` isn't `true`. That check matters: the API drops fields it doesn't know without an error.

`-NamingScheme vda-tw-##` names the machines (digits; `isSchemeTypeNumeric` is the field the API honours, while `namingSchemeType` is silently dropped and gives letters). `-SessionTimeoutMinutes` sets the idle-session timeout (default 15). Never use 0, which disconnects an idle session at once; demo and lab catalogs often want a day (`1440`).

Things the published API reference doesn't tell you:

- `enableAcceleratedNetworking` isn't in the published Quick Deploy reference. It's in Citrix's generated SDK (`citrix-daas-rest-go`, `AddCitrixManagedCatalogModel`, since v1.0.27).
- `computeWorker.instanceTypeId` takes the short SKU (`d2asv5`), not the Azure size name (`Standard_D2as_v5`). The size name fails with *"InstanceTypeId is not a valid Azure Instance Id"*.
- A request with only `scaleSettings: { maxInstances, minInstances }` is accepted, then the deployment fails later with *"Object validation failed"*. Send the full scale settings (peak hours, time zone, weekdays, disconnect actions), `minUniqueUsers`, and `sessionTimeout`, as the Terraform provider does.

---

## Checking it in the guest

The catalog flag is what was asked for, not proof. `11-check-catalog.ps1 -CatalogName "<name>"` reads back what the catalog asked for, from Quick Deploy and from the provisioning scheme MCS uses (read-only), and by default expects it on. Only the guest knows whether the NIC is accelerated, and the reliable check is which adapters carry traffic:

```powershell
# Per-adapter byte counters before and after copying 200 MB to a file share and back
function Get-NicBytes {
    Get-CimInstance Win32_PerfRawData_Tcpip_NetworkAdapter |
        ForEach-Object { [pscustomobject]@{ Adapter = $_.Name; Bytes = [int64]$_.BytesTotalPersec } }
}
$share  = '\\<server>\<share>'                      # any share this machine can write to
$local  = Join-Path $env:TEMP 'nictest.bin'
$remote = Join-Path $share "nictest-$env:COMPUTERNAME.bin"
$buf = New-Object byte[] (200MB); (New-Object Random).NextBytes($buf); [IO.File]::WriteAllBytes($local, $buf); $buf = $null
$before = Get-NicBytes
Copy-Item $local $remote; Copy-Item $remote "$local.back"
$after = Get-NicBytes
Remove-Item $local, "$local.back", $remote
$after | ForEach-Object {
    $b = ($before | Where-Object Adapter -eq $_.Adapter).Bytes
    [pscustomobject]@{ Adapter = $_.Adapter; MB = [int](($_.Bytes - $b) / 1MB) }
} | Where-Object MB -gt 0
```

The Hyper-V adapter counts all the traffic, accelerated or not.

- **On:** a **Mellanox ConnectX-… Virtual Ethernet Adapter** (or **Microsoft Azure Network Adapter** on MANA hardware) counts about as much. On Server 2025 builds before 26100.33828, the instance that counts is one `Get-NetAdapter` doesn't show:

  ```
  Adapter                                               MB
  -------                                               --
  Microsoft Hyper-V Network Adapter                    445
  Mellanox ConnectX-4 Lx Virtual Ethernet Adapter _2#1 452
  ```

- **Off, or the VF really lost:** only the Hyper-V adapter moves.

`Get-NetAdapter` is quicker, but it only proves one way. A Mellanox (or MANA) adapter that's Up, with the same MAC as the Hyper-V adapter, means it's on. *Not Present* doesn't mean it's off: see the [known issue](#known-issue-server-2025-shows-the-vf-as-not-present).

```powershell
Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, MacAddress
```

Citrix-managed VDAs don't accept WinRM, RDP or SMB from the peered VNet, so the lab uses an outbound check: `packer/scripts/lab/nic-probe/lab-nic-probe-setup.ps1` links a startup-script GPO to the VDA OU, and each VDA writes its adapters to a share on the domain controller at boot. New catalog machines report without anyone signing in. The probe reads adapter status, so on Server 2025 builds before 26100.33828 its `accelNetActive` can be `false` on a machine that's accelerated.

> **Lab only.** Never link the probe to an OU with production machines. It runs a startup script with `-ExecutionPolicy Bypass` on every computer in the OU, and gives Domain Computers write access to a share on the domain controller. Run `lab-nic-probe-setup.ps1 -Remove` when you're done.

**Keep the machine on long enough to report.** With no users assigned, smart scale powers new and rebooted machines Off within about a minute. In a lab, put the machine in maintenance mode *before* you start or reboot it; a start sent first is cancelled when maintenance mode is applied.

---

## Known issue: Server 2025 shows the VF as Not Present

Accelerated networking works on these machines; Windows reports it wrong. On Server 2025 builds before 26100.33828, at D4as_v5 and larger, on every boot:

| After boot | What happens |
|---|---|
| +5–16s | netvsc binds the Mellanox VF and switches the data path to it (System events 50, 52, 54, provider Hyper-V-Netvsc) |
| +45–104s | `Get-NetAdapter -IncludeHidden` shows the Mellanox adapter *Not Present*, with no MAC. Nothing in the System log records a VF removal. |
| afterwards | The VF's PnP device stays present and OK, and a second performance-counter instance of the adapter (`Mellanox … Adapter _2#1`) carries all the traffic. |

- **Seen on:** Citrix's "Win 2025 Server + VDA 2607 LTSR" (26100.33296) at D8as_v5 and D4as_v5, and a Packer image on 26100.33674 at D8as_v5. Every boot, in two tenants, on a different Azure host each time. Same NIC every time: ConnectX-4 Lx VF, mlx5 driver 23.4.26054.0.
- **Not seen on:** Server 2025 26100.33828 at D8as_v5 and D2as_v5; Server 2025 26100.33674 at D2as_v5 (TC6); Windows 11 26H2 at D8as_v5 and D4as_v5.
- **Not the cause:** the VDA's uberAgent. It installs its network driver `uberAgentNetMon` in the same window, and netvsc pauses and restarts the synthetic adapter when it loads (events 10 and 11, again at each uberAgent restart). But with uberAgent stopped before its drivers loaded, the adapter still went *Not Present*, and the builds that report correctly go through the same pause.
- **Once it's Not Present, it stays that way.** Restarting the adapter, or Windows, doesn't bring it back. A power cycle from Citrix (a new VM) shows it Up again, until it changes.

What to do:

- No action needed for performance: the traffic is on the VF.
- Check with byte counters, not status: see [Checking it in the guest](#checking-it-in-the-guest).
- Build images with current cumulative updates. Images on 26100.33828 or later report it correctly.

---

## Keeping it on

- Create catalogs with the modules and provider v1.0.43 or later; the default is on.
- Image updates keep it on: `template_image_id` updates in place, and both the catalog and the guest stay accelerated (tested).
- Changing the size family can turn it off: re-run the guest check. For v6 sizes, the image needs the MANA driver.
