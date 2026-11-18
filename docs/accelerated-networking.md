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

Every Platform Flex catalog should have Azure accelerated networking on. It's a **per-catalog setting that can only be chosen when the catalog is created**, and catalogs created from code come out with it **off**:

| How the catalog is created | Accelerated networking | Fix |
|---|---|---|
| Terraform, `citrix/citrix` provider through v1.0.43-tech-preview | **Off**: the provider has no attribute for it and never sends it | Coming: a provider attribute ([Terraform](#terraform-coming)). Until it ships, create with `10-create-catalog.ps1`, then import the catalog into Terraform |
| Catalog Service API, `POST catalogs/$manageddeploy`, without the field | **Off** | Add `addCatalog.enableAcceleratedNetworking: true` |
| `10-create-catalog.ps1` (this repo, **test script**) | **On**, checked after create | — |

Terraform is still how this repo creates and manages catalogs. `10-create-catalog.ps1` is a stopgap until the provider can set the flag.

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
| T3 | Terraform, a provider build with the coming attribute | Windows 11 26H2, Packer | `true` | **Mellanox ConnectX-4 Lx Virtual Ethernet Adapter**, Up |

T1a and T3 differ only in the flag: same Windows 11 image, same size, same network. T1b and T2 show the same for Server 2025.

---

## Creating a catalog with it on

### API (works today, test script)

`10-create-catalog.ps1` is a **test script**: not yet validated for production. Use it on a test catalog.

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

Things the published API reference doesn't tell you, found while writing it:

- `enableAcceleratedNetworking` isn't in the published Quick Deploy reference. It's in Citrix's generated SDK (`citrix-daas-rest-go`, `AddCitrixManagedCatalogModel`, since v1.0.27).
- `computeWorker.instanceTypeId` takes the short SKU (`d2asv5`), not the Azure size name (`Standard_D2as_v5`). The size name fails with *"InstanceTypeId is not a valid Azure Instance Id"*.
- A request with only `scaleSettings: { maxInstances, minInstances }` is accepted, then the deployment fails later with *"Object validation failed"*. Send the full scale settings (peak hours, time zone, weekdays, disconnect actions), `minUniqueUsers`, and `sessionTimeout`, as the Terraform provider does.

### Bring the catalog under Terraform

A catalog created by `10-create-catalog.ps1` isn't in Terraform's state. To manage it with Terraform from then on:

1. Write its configuration with one of the [examples](https://github.com/JefferyMitchell/flex-image-builder/tree/main/infra/examples), using the same name, region, size, image, network connection and domain settings you passed to the script.
2. Import it with the catalog ID the script printed:

   ```bash
   terraform import module.catalog.citrix_quickdeploy_catalog.this <catalog-id>
   ```

3. Run `terraform plan` and check it shows no changes. If it plans to replace the catalog, fix the configuration first: a replacement deletes the catalog and creates a new one with accelerated networking off.

### Terraform (coming)

`citrix_quickdeploy_catalog` has no attribute for it through v1.0.43-tech-preview, so Terraform-built catalogs are always off. An `enable_accelerated_networking` attribute is a coming feature: optional, set at creation, and read back into state. When a provider release has it, the catalog modules will pass it through. Until then the modules can't add it: a provider without the attribute rejects the argument outright (*"An argument named "enable_accelerated_networking" is not expected here"*), even when the value is `null`.

When it arrives, run `terraform plan` before you apply to a catalog you imported earlier. A setting that can only be chosen at creation can show up as a replacement.

---

## Checking it in the guest

The catalog flag is what was asked for, not proof. On sizes where Azure *requires* accelerated networking (Intel Dsv5, all v6), it's on regardless of the flag; on Dasv5 it follows the flag. `11-check-catalog.ps1 -CatalogName "<name>" -ExpectAcceleratedNetworking $true` reads back what the catalog asked for, from Quick Deploy and from the provisioning scheme MCS uses (read-only). Only the guest knows whether the NIC is accelerated:

```powershell
Get-NetAdapter | Format-Table Name, InterfaceDescription, Status
```

On: a second adapter, **Mellanox ConnectX-… Virtual Ethernet Adapter** (or **Microsoft Azure Network Adapter** on MANA hardware), Up, with the same MAC as the Hyper-V adapter.

Citrix-managed VDAs don't accept WinRM, RDP or SMB from the peered VNet, so the lab uses an outbound check: `packer/scripts/lab/nic-probe/lab-nic-probe-setup.ps1` links a startup-script GPO to the VDA OU, and each VDA writes its adapters to a share on the domain controller at boot. New catalog machines report without anyone signing in.

> **Lab only.** Never link the probe to an OU with production machines. It runs a startup script with `-ExecutionPolicy Bypass` on every computer in the OU, and gives Domain Computers write access to a share on the domain controller. Run `lab-nic-probe-setup.ps1 -Remove` when you're done.

**A new single-session machine may be Off.** Right after a catalog deploys, Quick Deploy's smart scale can leave a new single-session machine powered off until the catalog's autoscale settings are changed. A machine that never boots never reports, so power it on before waiting for its probe.

---

## Keeping it on

- Until the provider attribute ships, create catalogs that need it with `10-create-catalog.ps1`, then import them into Terraform. After that, use Terraform with the attribute.
- Image updates can't turn it off: `$updateImage` doesn't carry the setting.
- Changing size family can: re-run the guest check. For v6 sizes, the image needs the MANA driver.
