---
layout: default
title: Accelerated Networking
nav_order: 9
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

Every Platform Flex catalog should have Azure accelerated networking on. It's a **per-catalog setting that can only be chosen when the catalog is created**, and catalogs created from code come out with it **off**:

| How the catalog is created | Accelerated networking | Fix |
|---|---|---|
| Terraform, `citrix/citrix` provider up to v1.0.41 | **Off**: the provider has no attribute for it and never sends it | Provider attribute (proposed). Until it ships, create with `10-create-catalog.ps1` |
| Catalog Service API, `POST catalogs/$manageddeploy`, without the field | **Off** | Add `addCatalog.enableAcceleratedNetworking: true` |
| `10-create-catalog.ps1` (this repo) | **On**, checked after create | — |

The image pipeline (Packer, gallery export, `06-import-to-citrix.ps1`) needs **no change**: the setting isn't part of the image, and the Windows 11 and Server 2025 images built here already have the driver.

It can't be switched on for an existing catalog: no update call carries it. Create a new catalog and move users.

---

## What was tested

Lab: westus3, Citrix-managed capacity, VNet peering, domain-joined, all machines **Standard_D2as_v5**. On this AMD Dasv5 size accelerated networking is *supported* but not *required*, so Azure doesn't turn it on by itself.

| Test | Catalog created by | Image | Flag (read back) | In the guest |
|---|---|---|---|---|
| T1a baseline | Terraform v1.0.41 | Windows 11 26H2, Packer | `false` | Hyper-V adapter only |
| T1b baseline | Citrix (lab automation) | Server 2025, Citrix-prepared | `false` | Hyper-V adapter only |
| T2 | API, `10-create-catalog.ps1` | Server 2025, Packer | `true` | **Mellanox ConnectX-4 Lx Virtual Ethernet Adapter**, Up |
| T3 | Terraform, provider built with the proposed attribute | Windows 11 26H2, Packer | `true` | **Mellanox ConnectX-4 Lx Virtual Ethernet Adapter**, Up |

T1a and T3 differ only in the flag: same Windows 11 image, same size, same network. T1b and T2 show the same for Server 2025.

---

## Creating a catalog with it on

### API (works today)

```powershell
$env:TF_VAR_domain_service_account_password = "<join account password>"
.\packer\scripts\powershell\10-create-catalog.ps1 `
    -Name "Task Worker" -ImageName "<image>" -SessionType MultiSession `
    -VmSize Standard_D2as_v5 -NumberOfUsers 2 `
    -VnetPeeringName "<network connection>" `
    -Domain corp.example -DomainOu "OU=VDAs,DC=corp,DC=example" -ServiceAccount svc-join
```

The script reads the catalog back and fails if `enableAcceleratedNetworking` isn't `true`. That check matters: the API drops fields it doesn't know without an error.

Things the published API reference doesn't tell you, found while writing it:

- `enableAcceleratedNetworking` isn't in the published Quick Deploy reference. It's in Citrix's generated SDK (`citrix-daas-rest-go`, `AddCitrixManagedCatalogModel`, since v1.0.27).
- `computeWorker.instanceTypeId` takes the short SKU (`d2asv5`), not the Azure size name (`Standard_D2as_v5`). The size name fails with *"InstanceTypeId is not a valid Azure Instance Id"*.
- A request with only `scaleSettings: { maxInstances, minInstances }` is accepted, then the deployment fails later with *"Object validation failed"*. Send the full scale settings (peak hours, time zone, weekdays, disconnect actions), `minUniqueUsers`, and `sessionTimeout`, as the Terraform provider does.

### Terraform

`citrix_quickdeploy_catalog` has no attribute for it (up to v1.0.41), so Terraform-built catalogs are always off. An attribute has been proposed to the provider (`enable_accelerated_networking`: optional, set at creation, read back into state). Once a release has it, the catalog modules can pass it through; a released provider without it rejects the argument outright (*"An argument named "enable_accelerated_networking" is not expected here"*), even when the value is `null`, so the module change has to wait for that release. Until then, create catalogs that need it with `10-create-catalog.ps1`.

---

## Checking it in the guest

The catalog flag is what was asked for, not proof. On sizes where Azure *requires* accelerated networking (Intel Dsv5, all v6), it's on regardless of the flag; on Dasv5 it follows the flag. Only the guest knows:

```powershell
Get-NetAdapter | Format-Table Name, InterfaceDescription, Status
```

On: a second adapter, **Mellanox ConnectX-… Virtual Ethernet Adapter** (or **Microsoft Azure Network Adapter** on MANA hardware), Up, with the same MAC as the Hyper-V adapter.

Citrix-managed VDAs don't accept WinRM, RDP or SMB from the peered VNet, so the lab uses an outbound check: `packer/scripts/lab/nic-probe/lab-nic-probe-setup.ps1` links a startup-script GPO to the VDA OU, and each VDA writes its adapters to a share on the domain controller at boot. New catalog machines report without anyone signing in.

---

## Keeping it on

- Create catalogs only through `10-create-catalog.ps1`, or Terraform with the provider attribute.
- Image updates can't turn it off: `$updateImage` doesn't carry the setting.
- Changing size family can: re-run the guest check. For v6 sizes, the image needs the MANA driver.
