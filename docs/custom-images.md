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

> **Status: Coming Soon.** This section documents the planned custom image pipeline. Validation of `citrix_quickdeploy_template_image` end-to-end is in progress. The Terraform resource schema is documented here for reference.

---

## Why Custom Images

Citrix provides ready-made base images (Windows 11 Pro, Windows Server 2022/2025 with VDA pre-installed). These are sufficient for general deployments.

Custom images are needed when you want to:
- Pre-install line-of-business applications, reducing first-login provisioning time
- Apply a specific Citrix Optimizer profile for your workload type
- Control exactly which VDA version is deployed
- Enforce OS hardening baselines before machines are provisioned

## Pipeline Overview

```
citrix-packer-tools          Your Azure subscription         Platform Flex
───────────────────          ─────────────────────────       ──────────────────────────────────
Packer build (local   →      Temp VM spins up          →     citrix_quickdeploy_template_image
CLI or CI runner)            VDA + apps installed             registers image in Flex library
                             Image captured as
                             Managed Image
                             Temp VM deleted
                                                         →    citrix_quickdeploy_catalog
                                                              references image by ID
```

## citrix-packer-tools

[github.com/citrix/citrix-packer-tools](https://github.com/citrix/citrix-packer-tools) provides Packer templates for:

- Windows 10/11 (Desktop, Office editions)
- Windows Server 2019 / 2022 / 2025
- VDA versions: 2407, 2411, 2503, 2507

Packer runs on your local machine or CI runner. The build happens in your customer Azure subscription — Packer spins up a temporary VM, provisions it, captures the image, and deletes the VM. The resulting Managed Image stays in your resource group.

**Prerequisites for a Packer build:**
- Packer installed locally
- Azure service principal with Contributor access to the target resource group
- Azure Storage Account with VDA installer and Citrix Optimizer pre-staged as blobs
- Customer-owned Azure subscription (not the Citrix Managed subscription)

## Terraform Resource

```hcl
resource "citrix_quickdeploy_template_image" "custom_image" {
  name               = "Win11-VDA2507-AppImage"
  os_platform        = "Windows"
  machine_generation = "V2"
  region             = "eastus"
  subscription_name  = "Citrix Managed"
  notes              = "Built with citrix-packer-tools v2507. Win 11 Pro, VDA 2507."
  vhd_uri            = var.packer_image_vhd_uri
}

resource "citrix_quickdeploy_catalog" "custom" {
  name              = var.catalog_name
  persona           = "Knowledge worker"
  catalog_type      = "SingleSessionStatic"
  region            = "eastus"
  subscription_name = "Citrix Managed"
  template_image_id = citrix_quickdeploy_template_image.custom_image.id
  number_of_users   = var.number_of_users

  # ... on_prem_connectivity, power_schedule
}
```

### Getting the VHD URI

After a Packer build completes, retrieve the VHD URI from the resulting Azure Managed Image:

**PowerShell:**
```powershell
$img = Get-AzImage -ResourceGroupName "your-rg" -ImageName "win_desktop_11_v2507_20260624"
$img.StorageProfile.OsDisk.BlobUri
```

**Azure CLI (bash):**
```bash
az image show \
  --resource-group your-rg \
  --name win_desktop_11_v2507_20260624 \
  --query storageProfile.osDisk.blobUri -o tsv
```

This URI is passed as `var.packer_image_vhd_uri` to the Terraform resource.

> **Note:** The VHD must be accessible to the Citrix Managed Azure subscription. Full validation of this access pattern is in progress.
