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

Citrix provides ready-made base images (Windows 11 Pro, Windows Server 2022/2025 with VDA pre-installed). These are sufficient for general deployments.

Custom images are needed when you want to:
- Pre-install line-of-business applications, reducing first-login provisioning time
- Apply a specific Citrix Optimizer profile for your workload type
- Control exactly which VDA version is deployed
- Enforce OS hardening baselines before machines are provisioned

---

## Pipeline Overview

```
Step 1 — Azure setup          Step 2 — Stage installers     Step 3 — Packer build
─────────────────────         ──────────────────────────    ──────────────────────
00-setup-azure         →      01-upload-installers    →     02-build
Create RG, storage            Upload VDA + Optimizer        Clone citrix-packer-tools
account, service              Generate SAS URLs             Run packer build
principal                                                   Output: Managed Image
                                                                    in your Azure sub

Step 4 — Export VHD           Step 5 — Register + deploy
────────────────────          ──────────────────────────
03-export-image        →      terraform apply
Copy Managed Image to         citrix_quickdeploy_template_image
VHD blob                      registers image in Flex library
Get blob URI                  citrix_quickdeploy_catalog
                              provisions machines from it
```

Scripts are provided in both PowerShell (`packer/scripts/powershell/`) and bash (`packer/scripts/bash/`).

---

## Step 1 — Azure Setup

Run once per environment. Creates the resource group, storage account, and service principal.

**PowerShell:**
```powershell
.\packer\scripts\powershell\00-setup-azure.ps1 `
    -SubscriptionId "your-azure-subscription-id" `
    -Location eastus `
    -Prefix flex-packer
```

**bash:**
```bash
./packer/scripts/bash/00-setup-azure.sh \
    --subscription "your-azure-subscription-id" \
    --location eastus \
    --prefix flex-packer
```

The script outputs the SP credentials and resource names to paste into your Packer variables file.

---

## Step 2 — Stage Installers

Download the VDA installer and Citrix Optimizer from [Citrix Downloads](https://www.citrix.com/downloads/) (requires Citrix account), then upload them to Azure Blob Storage.

**PowerShell:**
```powershell
.\packer\scripts\powershell\01-upload-installers.ps1 `
    -StorageAccount flexpackerbuild `
    -VdaPath C:\Downloads\VDASetup.exe `
    -OptimizerPath C:\Downloads\CitrixOptimizer.zip
```

**bash:**
```bash
./packer/scripts/bash/01-upload-installers.sh \
    --storage-account flexpackerbuild \
    --vda-path ~/Downloads/VDASetup.exe \
    --optimizer-path ~/Downloads/CitrixOptimizer.zip
```

The script generates time-limited SAS URLs and prints them. Copy these into your `.pkrvars.hcl` file.

> **SAS expiry:** URLs are valid for 4 hours by default. Start your Packer build promptly. Re-run the script to generate fresh URLs if needed.

---

## Step 3 — Configure Packer Variables

Copy the appropriate example file from `packer/variables/` and fill in all values:

```bash
cp packer/variables/win_server_2025.pkrvars.hcl.example \
   packer/variables/win_server_2025.pkrvars.hcl
```

The filled-in file is git-ignored — never commit it.

### Optimizer template names

| OS | optimizer_template value |
|----|--------------------------|
| Windows Server 2025 | `Citrix_Windows_Server_2025.xml` |
| Windows Server 2022 | `Citrix_Windows_Server_2022.xml` |
| Windows Server 2019 | `Citrix_Windows_Server_2019.xml` |
| Windows 11 23H2     | `Citrix_Windows_11_2009.xml` |

---

## Step 4 — Run Packer Build

**PowerShell:**
```powershell
.\packer\scripts\powershell\02-build.ps1 `
    -VarsFile win_server_2025.pkrvars.hcl `
    -Os win_server_2025_dc `
    -VdaVersion v2507
```

**bash:**
```bash
./packer/scripts/bash/02-build.sh \
    --vars-file win_server_2025.pkrvars.hcl \
    --os win_server_2025_dc \
    --vda-version v2507
```

The build script clones `citrix-packer-tools` automatically if not present. Build time is approximately 30–60 minutes depending on region and OS.

### Available OS templates

| Template name | OS |
|---------------|----|
| `win_desktop_11_23h2` | Windows 11 23H2 (Desktop) |
| `win_office_11_23h2`  | Windows 11 23H2 (with Office) |
| `win_server_2019_dc`  | Windows Server 2019 Datacenter |
| `win_server_2022_dc`  | Windows Server 2022 Datacenter |
| `win_server_2025_dc`  | Windows Server 2025 Datacenter |

---

## Step 5 — Export VHD

Packer creates an Azure Managed Image. The `citrix_quickdeploy_template_image` resource requires a VHD blob URI, so this step copies the image to a storage account blob.

**PowerShell:**
```powershell
.\packer\scripts\powershell\03-export-image.ps1 `
    -ResourceGroup rg-flex-packer-build `
    -ImageName win_server_2025_dc_202506261200 `
    -StorageAccount flexpackerbuild `
    -SubscriptionId "your-azure-subscription-id"
```

**bash:**
```bash
./packer/scripts/bash/03-export-image.sh \
    --resource-group rg-flex-packer-build \
    --image-name win_server_2025_dc_202506261200 \
    --storage-account flexpackerbuild \
    --subscription "your-azure-subscription-id"
```

The script prints the VHD URI. Copy it into `terraform.tfvars`:

```hcl
vhd_uri = "https://flexpackerbuild.blob.core.windows.net/vhd-output/win_server_2025_dc_202506261200.vhd"
```

> **Export time:** Copying a 30–40 GB OS disk typically takes 5–15 minutes.

---

## Step 6 — Deploy with Terraform

Use the `singlesession-custom-image` example:

```bash
cd infra/examples/singlesession-custom-image
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform plan
terraform apply
```

### What gets created

```hcl
resource "citrix_quickdeploy_template_image" "this" {
  name               = var.image_name
  os_platform        = "Windows"
  machine_generation = "V2"
  region             = var.region
  subscription_name  = "Citrix Managed"
  vhd_uri            = var.vhd_uri
}

module "catalog" {
  source            = "../../modules/catalog-singlesession"
  template_image_id = citrix_quickdeploy_template_image.this.id
  # ...
}
```

Terraform registers the image in Citrix's library, then creates a catalog that uses it. The image appears in Citrix Cloud > Full Configuration > Machine Catalogs after apply.

---

## Updating an Image

When you build a new version of the image:

1. Run steps 3–5 to produce a new VHD URI
2. Update `vhd_uri` in `terraform.tfvars`
3. `terraform apply` — Citrix will update the catalog to use the new image

Existing sessions are not interrupted immediately; machines are re-imaged on next restart.
