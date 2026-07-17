---
layout: default
title: Custom Images
nav_order: 6
---

# Custom Images
{: .no_toc }

<details open markdown="block">
  <summary>Contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Why Custom Images

Citrix Platform Flex ships with ready-made base images (Windows 11, Windows Server 2022/2025 with VDA pre-installed). Those are sufficient for generic deployments, but custom images are needed when you want to:

- Pre-install line-of-business applications — reducing first-login provisioning time from minutes to seconds
- Apply a specific Citrix Optimizer profile tuned to your workload type
- Control exactly which VDA version is deployed across all machines
- Enforce OS hardening baselines before machines are provisioned
- Standardize browser versions, certificates, or GPO baselines baked into the image

The pipeline in this repo automates the entire path from a marketplace base image to a deployed Citrix catalog.

---

## Architecture

```
Step 1 — Azure setup          Step 2 — Stage installers     Step 3 — Packer build
─────────────────────         ──────────────────────────    ──────────────────────
00-setup-azure         →      01-upload-installers    →     02-build
Create RG, storage            Upload VDA + Optimizer        Clone citrix-packer-tools
account, service              Generate SAS URLs             Run packer build
principal                     (4 hour expiry)               ~45 min
                                                            Output: OS disk SNAPSHOT
                                                                    Managed Image

Step 4 — Export VHD           Step 5 — Register + deploy
────────────────────          ──────────────────────────
03-export-image        →      terraform apply
AzCopy snapshot to            citrix_quickdeploy_template_image
VHD blob (not image)          registers image in Flex library
Generate blob SAS URI         citrix_quickdeploy_catalog
(required by Citrix)          provisions machines from it
```

The key constraint that drives the whole architecture is that **Citrix Platform Flex imports images from Azure Blob Storage via a time-limited SAS URI** — not from Azure Managed Images and not from Azure Compute Gallery. Everything in the pipeline exists to bridge that gap.

---

## Design Decisions and Why

### Gen2 is the required baseline

All custom images must use Azure VM Generation 2. This is not optional:

- **Azure Trusted Launch** (Secure Boot + vTPM) only works on Gen2 VMs. Citrix requires Trusted Launch for production deployments.
- Gen2 uses UEFI instead of legacy BIOS. Secure Boot requires UEFI.
- Azure has deprecated Gen1 for most new VM sizes. The DS-v5 and similar families that Citrix uses for catalog machines are Gen2-only.

In the Packer template, Gen2 is selected by choosing a `-g2` marketplace SKU. The Packer Azure plugin (v2.6.3+) infers the generation from the source image SKU — there is no separate `hyper_v_generation` field. Older documentation and plugin versions showed this field; it was removed.

```json
"image_sku": "2025-datacenter-g2"
```

That single SKU choice determines that the entire chain — build VM, OS disk, snapshot, managed image — is all Gen2.

### Export the snapshot, not the managed image

This is the most critical and non-obvious point in the pipeline.

Packer's Azure ARM builder captures images in this sequence:

1. Runs provisioners (VDA install, optimizer, cleanup)
2. Powers off the VM
3. **Takes an OS disk snapshot** — this is the pre-generalization snapshot
4. Calls Azure's "generalize" API (equivalent to running Sysprep at the OS level)
5. Captures a Managed Image from the generalized disk

Citrix MCS (Machine Creation Services) provisions machines from a **non-sysprepped** disk image. It handles generalization itself during provisioning. If you give Citrix the managed image VHD (post-generalization), it will fail with a "master image could not be verified" error.

**Always export the snapshot (step 3 above), never the managed image (step 5).**

The snapshot is named identically to the managed image — Packer uses the same `image_name` for both. The `03-export-image.ps1` script takes `-SnapshotName` (not `-ImageName`) specifically to enforce this.

### Why AzCopy, not `az storage blob copy start`

The snapshot SAS URL returned by `az snapshot grant-access` uses Azure's internal blob format:

```
https://<guid>.blob.storage.azure.net/<container>/<blob>
```

This is an internal Azure-to-Azure endpoint. The `az storage blob copy start` command uses Azure's server-side copy API, which rejects these internal source URLs with a 403 `AuthenticationFailed` error. The error message gives no hint that the URL format is the problem.

AzCopy v10 handles the transfer differently — it downloads and re-uploads via the client — and works correctly with internal snapshot SAS URLs.

**AzCopy must be installed separately** (`winget install Microsoft.Azure.AzCopy.10`). It is not part of the Azure CLI.

### Why blobs need a SAS token

Citrix Platform Flex accesses your blob storage directly from Citrix's backend infrastructure. It has no identity in your Azure subscription and cannot use managed identity or Azure RBAC to read your storage. **A plain blob URL will be rejected** with "The specified VHD URL is invalid."

The SAS token must grant read (`sp=r`) over HTTPS (`spr=https`). The `03-export-image.ps1` script generates this automatically and outputs the full SAS URI to paste into Terraform.

SAS tokens have an expiry. The script defaults to 7 days (`-SasDays 7`). If you need to re-apply Terraform after the SAS expires, re-run the export script with `-SasDays` set to however many days you need — it will skip the AzCopy transfer (the VHD blob already exists) and generate a fresh SAS token.

### OS requirements per catalog type

Not all Windows versions work with all catalog types:

| OS | Catalog type | Persona examples |
|----|-------------|-----------------|
| Windows 11 (multi-session EVD) | MultiSession | Knowledge Worker, Task Worker |
| Windows 11 Pro / Enterprise | SingleSession | Knowledge Worker |
| Windows Server 2022 / 2025 | **MultiSession only** | Task Worker |
| Windows Server 2022 / 2025 | ~~SingleSession~~ | Not supported |

Windows Server is a server OS and cannot legally or technically act as a single-session desktop under Citrix's Platform Flex licensing. Attempting to create a SingleSession catalog with a Server OS image will succeed at the image import step (Citrix registers the image without validation) but fail at catalog creation with: *"Master image must be running a Windows 10 Multi-Session compatible OS."*

The `catalog-multisession` module must be used for Server OS images. The `catalog-singlesession` module is for Windows 11 only.

---

## Trusted Launch (Secure Boot + vTPM)

**Trusted Launch is the default for all production catalogs.** The Packer template, export script, and Terraform variables are all implemented. The next Packer rebuild will be the first end-to-end Trusted Launch validation run — until then, Gen2 without Trusted Launch (`JMFlexCustomImageTest2`) is the validated baseline.

### What Trusted Launch requires

Azure Trusted Launch adds two security features to a Gen2 VM:

- **Secure Boot** — The VM firmware validates the OS bootloader signature against a known-good key database before allowing the OS to start. Prevents boot-level malware and rootkits.
- **vTPM** — A virtual Trusted Platform Module stores cryptographic keys and measurements. Required for Windows 11 compliance and BitLocker.

When Citrix provisions a Trusted Launch catalog machine, it needs two disk sources:

1. **`vhd_uri`** — The OS disk VHD (standard Packer output via `03-export-image.ps1`)
2. **`guest_disk_uri`** — The VM Guest State (VMGS) blob — stores UEFI Secure Boot key database and vTPM state

The `guest_disk_uri` field in `citrix_quickdeploy_template_image` is optional in the Terraform schema but **required by the Citrix API at runtime when `secure_boot_enabled = true`**. Omitting it while enabling Secure Boot returns: *"Guest Disk URI required."*

### How it works

When `security_type = "TrustedLaunch"` is set in the Packer builder, the build VM is provisioned as a Trusted Launch VM. Azure stores both the OS disk data and the VM Guest State (the Secure Boot key database and vTPM state) linked to the OS disk snapshot.

The `az snapshot grant-access` command supports a `--security-data-access-level Read` flag. When the snapshot was created from a Trusted Launch VM, this returns both an `accessSAS` (for the OS disk) and a `securityDataAccessSAS` (for the VMGS data) in a single call. The export script uses AzCopy to copy both blobs to storage and generates individual read SAS URIs for each.

### What the pipeline produces

After a Trusted Launch Packer build and `03-export-image.ps1`:

```
vhd-output/
  win_server_2025_dc_202607160709.vhd          ← OS disk  → vhd_uri
  win_server_2025_dc_202607160709-vmgs.vhd     ← VMGS     → guest_disk_uri
```

Both URIs go into `terraform.tfvars`:

```hcl
machine_generation   = "V2"
secure_boot_enabled  = true
vtpm_enabled         = true
vhd_uri              = "https://.../<name>.vhd?<sas>"
guest_disk_uri       = "https://.../<name>-vmgs.vhd?<sas>"
```

### Verification

Once a catalog VM provisions, RDP in and run:

```powershell
Confirm-SecureBootUEFI   # returns True when Secure Boot is active
```

### Current validation state

The export script and Terraform variables are implemented. The next Packer rebuild (with `security_type = "TrustedLaunch"` now in the template) will be the first end-to-end Trusted Launch validation run. The Gen2-without-Trusted-Launch pipeline has been validated (`JMFlexCustomImageTest2` catalog, ID `30641284-ee7c-4fd5-87b8-53a35978fdbc`).

> **If `03-export-image.ps1` outputs "VMGS SAS not returned"**: the snapshot was built without `security_type = "TrustedLaunch"`. Rebuild with the updated Packer template — it is now the default for `win_server_2025_dc`.

---

## Provider Compatibility

The `citrix/citrix` Terraform provider has had breaking schema changes across minor versions. Always pin to a tested version.

| Provider version | Breaking changes |
|-----------------|-----------------|
| v1.0.35 | `customer_id`, `client_id`, `client_secret` at provider root |
| v1.0.36 | Fixes for power schedule schema |
| **v1.0.37** | Provider credentials moved into `cvad_config = { }` block. `client_secret` removed from Terraform config — must be set via `CITRIX_CLIENT_SECRET` environment variable only. `on_prem_connectivity` and `domain_identity` changed from HCL block syntax to object attribute syntax (`= { }`) |

### v1.0.37 provider configuration

```hcl
provider "citrix" {
  cvad_config = {
    customer_id = var.citrix_customer_id
    client_id   = var.citrix_client_id
    # client_secret is read from CITRIX_CLIENT_SECRET environment variable
  }
}
```

The `client_secret` must be passed via environment variable, not as a Terraform variable. This prevents it from appearing in plan output or state files.

```powershell
$env:CITRIX_CLIENT_SECRET = "your-secret"
$env:TF_VAR_citrix_client_secret = $env:CITRIX_CLIENT_SECRET  # if any module reads it
```

### on_prem_connectivity object syntax (v1.0.37)

In v1.0.35/36, `on_prem_connectivity` was a nested block:

```hcl
# OLD — v1.0.35/36 block syntax (does not work in v1.0.37)
on_prem_connectivity {
  onprem_network_connection_id = var.connection_id
  domain_identity {
    domain = var.domain_name
  }
}
```

In v1.0.37 it is an object attribute:

```hcl
# CORRECT — v1.0.37 object attribute syntax
on_prem_connectivity = {
  onprem_network_connection_id = var.connection_id
  domain_identity = {
    domain                   = var.domain_name
    domain_ou                = var.domain_ou
    service_account          = var.domain_service_account
    service_account_password = var.domain_service_account_password
  }
}
```

The error when using the old syntax is: *"`on_prem_connectivity`: Blocks are not allowed here."*

### Child modules must declare the provider source

Terraform resolves provider names to registry paths using the `required_providers` block. If a child module (e.g., `modules/catalog-multisession`) does not declare the provider, Terraform defaults to `hashicorp/citrix` — which does not exist.

Every module that uses a `citrix_*` resource must have a `versions.tf`:

```hcl
terraform {
  required_providers {
    citrix = {
      source = "citrix/citrix"
    }
  }
}
```

The error without this is: *"Could not retrieve the list of available versions for provider hashicorp/citrix."*

---

## Step-by-Step Build and Deploy

### Step 1 — Azure Setup

Run once per environment. Creates the resource group, storage account, and service principal.

```powershell
.\packer\scripts\powershell\00-setup-azure.ps1 `
    -SubscriptionId "your-azure-subscription-id" `
    -Location eastus `
    -Prefix flex-packer
```

The script outputs SP credentials and resource names to paste into your Packer variables file. Keep the output — the client secret is shown once.

---

### Step 2 — Stage Installers

Download the VDA installer and Citrix Optimizer from [Citrix Downloads](https://www.citrix.com/downloads/), then upload them:

```powershell
.\packer\scripts\powershell\01-upload-installers.ps1 `
    -StorageAccount flexpackerbuild `
    -VdaPath C:\Downloads\VDASetup.exe `
    -OptimizerPath C:\Downloads\CitrixOptimizer.zip
```

The script generates SAS URLs and writes them into your Packer variables file automatically.

> **Gotcha — SAS expiry on installer blobs:** The SAS URLs generated for the VDA installer and Optimizer default to a short expiry. If you don't start the Packer build within that window, Packer will fail when trying to download the VDA installer — it will appear as a generic download error. Re-run `01-upload-installers.ps1` to get fresh SAS URLs before retrying the build.

---

### Step 3 — Configure Packer Variables

Copy the template and fill in all values:

```powershell
copy packer\variables\win_server_2025.json.example packer\variables\win_server_2025.json
```

The filled-in file is git-ignored — never commit it (it contains the service principal secret).

#### Gen2 SKU selection

For Windows Server 2025, the marketplace SKU must end in `-g2`:

```json
"image_sku": "2025-datacenter-g2"
```

Using the non-g2 SKU (`2025-datacenter`) builds a Gen1 image. The resulting catalog machines will be Gen1, which cannot support Secure Boot regardless of what you set in Terraform.

> **Gotcha — `hyper_v_generation` removed in plugin v2.6.3:** Older Packer documentation and templates include `"hyper_v_generation": "V2"` in the builder config. The `packer-plugin-azure` v2.6.3+ removed this field — it is now inferred from the source image SKU. If your template includes this field, Packer will error: *"unknown configuration key: 'hyper_v_generation'"*. Remove the field; the `-g2` SKU is sufficient.

#### Optimizer template names

| OS | optimizer_template value |
|----|--------------------------|
| Windows Server 2025 | `Citrix_Windows_Server_2025.xml` |
| Windows Server 2022 | `Citrix_Windows_Server_2022.xml` |
| Windows Server 2019 | `Citrix_Windows_Server_2019.xml` |
| Windows 11 23H2     | `Citrix_Windows_11_2009.xml` |

---

### Step 4 — Run Packer Build

```powershell
.\packer\scripts\powershell\02-build.ps1 `
    -VarsFile win_server_2025.json `
    -Os win_server_2025_dc `
    -VdaVersion v2507
```

Build time is approximately 40–50 minutes. The build script clones `citrix-packer-tools` automatically if not present.

At completion Packer outputs:

```
ManagedImageName: win_server_2025_dc_202607160709
ManagedImageOSDiskSnapshotName: win_server_2025_dc_202607160709
```

Note both names — they are identical. You will pass the snapshot name to `03-export-image.ps1`.

#### What Packer does internally

Understanding the build sequence prevents the "wrong VHD" mistake:

1. Creates a temporary resource group and deploys a VM from the marketplace image
2. Runs all provisioners (VDA install, restart, VDA install phase 2, Ngen, Optimizer, Chrome, cleanup)
3. **Powers off the VM**
4. **Snapshots the OS disk** — this snapshot is the correct source for Citrix MCS
5. Calls Azure's Generalize API on the VM (marks the OS as sysprepped)
6. Captures a Managed Image from the generalized disk
7. Deletes the temporary resource group

The snapshot (step 4) is taken from a running, non-sysprepped disk. The managed image (step 6) is taken after generalization. Citrix needs the non-sysprepped disk — always use the snapshot.

---

### Step 5 — Export Snapshot VHD

```powershell
.\packer\scripts\powershell\03-export-image.ps1 `
    -ResourceGroup    rg-flex-packer-build `
    -SnapshotName     win_server_2025_dc_202607160709 `
    -StorageAccount   flexpackerbuild `
    -SubscriptionId   "your-azure-subscription-id"
```

The script:
1. Grants a temporary SAS on the snapshot
2. Uses AzCopy to copy the snapshot VHD to the `vhd-output` container in your storage account
3. Revokes the snapshot SAS (snapshot no longer accessible externally)
4. Generates a read SAS on the blob (7-day default)
5. Outputs the full SAS URI

> **Gotcha — `az storage blob copy start` does not work:** The snapshot SAS URL returned by Azure is in the internal format `https://<guid>.blob.storage.azure.net/...`. Azure's server-side copy API rejects this as a source — you get a 403 `AuthenticationFailed` error with no explanation that the URL format is the problem. AzCopy v10 must be used instead. Install via `winget install Microsoft.Azure.AzCopy.10`.

> **Gotcha — Re-granting SAS on an active snapshot:** If you run the script a second time on a snapshot that already has an active SAS, `az snapshot grant-access` returns nothing (empty output). The script handles this by revoking the existing SAS first (`az snapshot revoke-access`) before re-granting. If you're scripting this yourself, be aware that re-granting without revoking first returns empty, which causes the AzCopy source URL to be blank.

Copy the output URI into `terraform.tfvars`:

```hcl
vhd_uri = "https://flexpackerbuild.blob.core.windows.net/vhd-output/win_server_2025_dc_202607160709.vhd?se=2026-07-23T15%3A01Z&sp=r&spr=https&sv=2026-04-06&sr=b&sig=..."
```

---

### Step 6 — Deploy with Terraform

```powershell
# Set secrets — never put these in terraform.tfvars
$env:CITRIX_CLIENT_SECRET            = "your-citrix-client-secret"
$env:TF_VAR_service_account_password = "your-domain-service-account-password"

cd infra\examples\singlesession-custom-image
terraform init
terraform plan
terraform apply
```

`terraform.tfvars` holds all non-secret values. It is git-ignored — never commit it.

#### What gets created

Two resources are created in order:

**1. `citrix_quickdeploy_template_image`** — Registers the VHD as a Citrix image:

```hcl
resource "citrix_quickdeploy_template_image" "this" {
  name               = var.image_name
  os_platform        = "Windows"
  machine_generation = "V2"
  region             = var.region
  subscription_name  = "Citrix Managed"
  vhd_uri            = var.vhd_uri
  secure_boot_enabled = var.secure_boot_enabled   # false until VMGS export is implemented
  vtpm_enabled        = var.vtpm_enabled           # false until VMGS export is implemented
  # guest_disk_uri   = var.guest_disk_uri          # required when secure_boot_enabled = true
}
```

**2. `citrix_quickdeploy_catalog`** (via module) — Creates the machine catalog:

```hcl
module "catalog" {
  source            = "../../modules/catalog-multisession"
  catalog_name      = var.catalog_name
  persona           = "Task worker (medium)"
  region            = var.region
  template_image_id = citrix_quickdeploy_template_image.this.id
  number_of_users   = var.number_of_users
  onprem_network_connection_id = var.onprem_network_connection_id
  domain_name       = var.domain_name
  domain_ou         = var.domain_ou
  domain_service_account          = var.service_account
  domain_service_account_password = var.service_account_password
}
```

Catalog creation takes 35–40 minutes. It provisions the Azure VMs, domain-joins them, installs Citrix agents, and makes them available in the Citrix delivery group.

> **Gotcha — machine_generation must match the disk:** The `machine_generation` field in `citrix_quickdeploy_template_image` must match the actual generation of the VHD. Setting `"V2"` for a Gen1 VHD (built from a non-g2 SKU) fails at catalog creation with: *"master image could not be verified."* The generation comes from the SKU you used in Packer — not from this Terraform field.

> **Gotcha — vTPM + Secure Boot only valid on V2:** Setting `secure_boot_enabled = true` or `vtpm_enabled = true` with `machine_generation = "V1"` is rejected by the API. Both require `"V2"`.

---

## Updating an Image

When you build a new version:

1. Run steps 4–5 to produce a new snapshot and VHD URI
2. Update `vhd_uri` in `terraform.tfvars` with the new SAS URI
3. Update `image_name` if you want a versioned name in the Citrix library
4. `terraform apply`

Terraform will update the template image in place and trigger Citrix to update the catalog. Existing sessions are not interrupted; machines are re-imaged on next restart.

---

## Terraform State Recovery

If `terraform apply` is interrupted mid-run (machine reboot, network drop, timeout), the state file may be partially written. Resources created in Citrix before the interruption will not be in state.

### Symptom

Re-running `terraform apply` fails with: *"Catalog name must be unique for a customer"* — the catalog was created in Citrix but Terraform doesn't know about it.

### Recovery procedure

**1. Find the orphaned catalog ID via the Citrix API:**

```powershell
# Get bearer token
$body = "grant_type=client_credentials&client_id=<client_id>&client_secret=<secret>"
$token = (Invoke-RestMethod -Uri "https://api-us.cloud.com/cctrustoauth2/<customer_id>/tokens/clients" `
    -Method POST -Body $body -ContentType "application/x-www-form-urlencoded").access_token

$headers = @{ "Authorization" = "CWSAuth Bearer=$token"; "Citrix-CustomerId" = "<customer_id>" }

# List all catalogs — find your catalog by name and note its id
$catalogs = Invoke-RestMethod -Uri "https://api.cloud.com/catalogservice/<customer_id>/<site_id>/catalogs" `
    -Method GET -Headers $headers
$catalogs.items | Where-Object { $_.name -eq "YourCatalogName" } | Select-Object id, name, state
```

> The `<site_id>` GUID is not shown in the Citrix UI. Find it by enabling Terraform debug logging (`TF_LOG=DEBUG`) and searching the output for `catalogservice/<customer_id>/` — the GUID after the customer ID is the site ID.

**2. Import the catalog into Terraform state:**

```powershell
terraform import module.catalog.citrix_quickdeploy_catalog.this <catalog-id-from-api>
```

**3. Run `terraform plan`** to check for drift. If the plan shows a destroy+recreate (common due to `catalog_type` vs `persona` drift in imported state), the catalog has no active sessions and it is safe to apply. The apply will delete the imported catalog and create a fresh one with the correct Terraform-managed config.

**4. If the deletion fails** (Citrix API returns an error state), the catalog can get stuck. Remove it from state and use a different name:

```powershell
terraform state rm module.catalog.citrix_quickdeploy_catalog.this
# Edit terraform.tfvars: catalog_name = "YourCatalogName2"
terraform apply
```

Manually delete the stuck catalog from Citrix Cloud > Platform Flex > Catalogs in the UI.

---

## Available OS Templates

| Template name | OS | Catalog type | Notes |
|---------------|----|-------------|-------|
| `win_desktop_11_23h2` | Windows 11 23H2 | SingleSession or MultiSession (EVD) | |
| `win_office_11_23h2`  | Windows 11 23H2 + Office | SingleSession or MultiSession (EVD) | |
| `win_server_2019_dc`  | Windows Server 2019 | MultiSession only | |
| `win_server_2022_dc`  | Windows Server 2022 | MultiSession only | |
| `win_server_2025_dc`  | Windows Server 2025 | MultiSession only | Validated end-to-end |
