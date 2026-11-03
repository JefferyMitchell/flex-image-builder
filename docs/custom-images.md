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
account, service              Print blob URLs (build VM     Run packer build
principal, managed identity   reads via managed identity)   ~45 min
                                                            Output: gallery image
                                                            version (specialized,
                                                            Trusted Launch)

Step 4 — Export VHD           Step 5 — Register + deploy
────────────────────          ──────────────────────────
04-export-from-gallery →      terraform apply
Temp disk; AzCopy OS VHD      citrix_quickdeploy_template_image
+ VMGS to a blob              registers image in Flex library
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

> **Current templates:** the templates publish straight into a *specialized* gallery image version (`"specialized": true`), so Packer never calls Generalize and no managed image is created. The gallery version holds the same pre-generalization disk the snapshot below describes, and `04-export-from-gallery.ps1` exports it (OS VHD + VMGS). The snapshot path (`03-export-image.ps1`) remains for builds that produce snapshots.

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

**How the SAS is made:** the export scripts generate a **user-delegation SAS**. It's signed with your Entra sign-in, not the storage account key, and the scripts never read account keys.

- It lasts at most 7 days (`-SasDays`, default 7).
- You can revoke it early with `az storage account revoke-delegation-keys`. An account-key SAS can only be revoked by rotating the key.
- AzCopy writes the blobs using your `az` sign-in (`AZCOPY_AUTO_LOGIN_TYPE=AZCLI`), so no write SAS exists either.
- You need **Storage Blob Data Contributor** on the storage account. `00-setup-azure.ps1` assigns it.

If the SAS expires before you've imported the image, re-run the export script to get a fresh one.

### SAS expiry must be calculated in UTC, not local time

Azure SAS tokens are validated against UTC. When PowerShell generates an expiry with `(Get-Date).AddHours(N).ToString("yyyy-MM-ddTHH:mmZ")`, it uses **local time** but appends `Z` — telling Azure the value is UTC when it is not.

**What happens:** If your machine is in a timezone behind UTC (e.g. UTC-5), `(Get-Date)` returns local time that is 5 hours behind UTC. Adding 2 hours gives a time that is still 3 hours in the past from Azure's perspective. Azure rejects the SAS with:

```
AuthenticationFailed: Signed expiry time [...] must be after signed start time [...]
```

AzCopy exits with an authentication error on the destination PUT — the source SAS is fine, only the destination container SAS fails.

**The fix:** Always use `[System.DateTime]::UtcNow` instead of `Get-Date` for SAS expiry calculations. The `03-export-image.ps1` script uses `UtcNow` consistently. This is the only correct approach on Windows machines that are not running in the UTC timezone.

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

**Trusted Launch is the default for all production catalogs.** The Packer template, export script, and Terraform variables are all implemented. The next Packer rebuild will be the first end-to-end Trusted Launch validation run — until then, Gen2 without Trusted Launch (`test-catalog`) is the validated baseline.

### What Trusted Launch requires

Azure Trusted Launch adds two security features to a Gen2 VM:

- **Secure Boot** — The VM firmware validates the OS bootloader signature against a known-good key database before allowing the OS to start. Prevents boot-level malware and rootkits.
- **vTPM** — A virtual Trusted Platform Module stores cryptographic keys and measurements. Required for Windows 11 compliance and BitLocker.

When Citrix provisions a Trusted Launch catalog machine, it needs two disk sources:

1. **`vhd_uri`** — The OS disk VHD (standard Packer output via `03-export-image.ps1`)
2. **`guest_disk_uri`** — The VM Guest State (VMGS) blob — stores UEFI Secure Boot key database and vTPM state

The `guest_disk_uri` field in `citrix_quickdeploy_template_image` is optional in the Terraform schema but **required by the Citrix API at runtime when `secure_boot_enabled = true`**. Omitting it while enabling Secure Boot returns: *"Guest Disk URI required."*

### How it works

When `security_type = "TrustedLaunch"` is set in the Packer builder, the build VM is provisioned as a Trusted Launch VM. The templates also set `secure_boot_enabled` and `vtpm_enabled` to `true`: with `security_type` alone, the plugin creates a Trusted Launch VM with **both turned off**, so the image would be built and captured on a VM that never booted with Secure Boot. Azure stores both the OS disk data and the VM Guest State (the Secure Boot key database and vTPM state) linked to the OS disk snapshot.

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

The export script and Terraform variables are implemented. The next Packer rebuild (with `security_type = "TrustedLaunch"` now in the template) will be the first end-to-end Trusted Launch validation run. The Gen2-without-Trusted-Launch pipeline has been validated (`test-catalog` catalog, ID `<catalog-id>`).

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

Run once per environment. Creates:

- the resource group, storage account and containers;
- **Storage Blob Data Contributor for you** on that storage account, because uploads and exports use your sign-in, not account keys;
- the build VM's managed identity;
- the Azure Compute Gallery, with one Trusted Launch image definition per template (Gen2, `SecurityType=TrustedLaunch`, Specialized). Packer publishes into these but doesn't create them.

**How Packer signs in (`-AuthMode`):**

| Mode | Packer runs as | Secret | Use for |
|---|---|---|---|
| `Cli` (default) | your `az login` session | none | interactive builds |
| `ServicePrincipal` | a service principal with Contributor on the build resource group | a client secret, shown once | unattended builds where federation isn't available |

For CI, prefer workload identity federation (OIDC), which needs no stored secret. `ServicePrincipal` needs rights to register applications in Entra ID.

In both modes, Packer builds **inside** the build resource group (`build_resource_group_name`). It never creates a temporary resource group, so resource-group-scoped rights are enough.

**Roles:**

- **To run setup:** Owner, or Contributor + User Access Administrator, on the subscription. Setup creates role assignments.
- **For builds:** Contributor on the build resource group, plus Storage Blob Data Contributor on its storage account.

```powershell
.\packer\scripts\powershell\00-setup-azure.ps1 `
    -SubscriptionId "your-azure-subscription-id" `
    -Location eastus `
    -Prefix flex-packer
```

The script prints the values to paste into your Packer variables file. In `ServicePrincipal` mode that includes the client secret. It's shown once, so put it in a secret manager, not in a file you might commit.

---

### Step 2 — Stage Installers

Download the VDA installer and Citrix Optimizer from [Citrix Downloads](https://www.citrix.com/downloads/), then upload them:

```powershell
.\packer\scripts\powershell\01-upload-installers.ps1 `
    -StorageAccount flexpackerbuild `
    -VdaPath C:\Downloads\VDAServerSetup_2507.exe `
    -OptimizerPath C:\Downloads\CitrixOptimizer.zip
```

The installers keep their file names in storage (`VDAServerSetup_2507.exe`), so each version stays side by side and you can always tell which VDA a build used. The script prints four values to paste into your Packer variables file:

- `vda_blob_url` and `optimizer_blob_url`: plain blob URLs. There is no SAS and no expiry: the build VM downloads the installers with its user-assigned managed identity (`managed_identity_id`, from Step 1).
- `vda_sha256` and `optimizer_sha256`: each file's SHA-256, also stored as blob metadata. The build VM checks both downloads against them before installing anything (see [What the build verifies and records](#what-the-build-verifies-and-records)).

It also lists the Optimizer templates in your zip, for `optimizer_template`.

> **Note:** `--auth-mode login` uploads need a data-plane role on the storage account for the signed-in user (Storage Blob Data Contributor). Owner or Contributor alone is not enough.

---

### Step 3 — Configure Packer Variables

Copy the example and fill in all values. The templates are legacy JSON, so the variables file must be JSON too (an HCL `.pkrvars.hcl` file fails with `Error reading variables`):

```powershell
Copy-Item packer\variables\win_server_2025.json.example packer\variables\win_server_2025.json
```

```bash
cp packer/variables/win_server_2025.json.example packer/variables/win_server_2025.json
```

Leave `vda_location` and `optimizer_location` out: they are the download paths *on the build VM* and the template defaults are correct.

`vda_sha256` and `optimizer_sha256` are required: the build stops without them. `vda_signer` (default `Citrix Systems, Inc.`) is the organization the VDA installer's signature must come from. Leave `image_version` at `latest`: the build script resolves it to the exact marketplace version and records it.

Leave `userpass` out. Packer generates a one-time WinRM password for each build VM and filters it from its logs, so there's no password to store.

Leave the three `virtual_network_*` keys empty unless your subscription forbids public IPs. Then see [Private-network builds](#private-network-builds-no-public-ip) under Step 4.

The filled-in file is git-ignored, but never commit it anyway: in `ServicePrincipal` mode it holds the client secret.

#### Gen2 SKU selection

For Windows Server 2025, the marketplace SKU must end in `-g2`:

```json
"image_sku": "2025-datacenter-g2"
```

Using the non-g2 SKU (`2025-datacenter`) builds a Gen1 image. The resulting catalog machines will be Gen1, which cannot support Secure Boot regardless of what you set in Terraform.

> **Gotcha — `hyper_v_generation` removed in plugin v2.6.3:** Older Packer documentation and templates include `"hyper_v_generation": "V2"` in the builder config. The `packer-plugin-azure` v2.6.3+ removed this field — it is now inferred from the source image SKU. If your template includes this field, Packer will error: *"unknown configuration key: 'hyper_v_generation'"*. Remove the field; the `-g2` SKU is sufficient.

#### Optimizer template names

`optimizer_template` must be the exact file name from the `Templates` folder of your Optimizer zip. The names carry a build suffix that can change between Optimizer releases. These are from Citrix Optimizer 2.9:

| OS | optimizer_template value |
|----|--------------------------|
| Windows Server 2025 | `Citrix_Windows_Server_2025_2009.xml` |
| Windows Server 2022 | `Citrix_Windows_Server_2022_2009.xml` |
| Windows Server 2019 | `Citrix_Windows_Server_2019_1809.xml` |
| Windows 11 23H2     | `Citrix_Windows_11_2009.xml` |

`01-upload-installers.ps1` prints the template names in the zip you upload. If `optimizer_template` isn't one of them, the build stops right after the installer download, before the VDA install, and lists the names the zip has.

---

### Step 4 — Run Packer Build

```powershell
.\packer\scripts\powershell\02-build.ps1 `
    -VarsFile win_server_2025.json `
    -Os win_server_2025_dc `
    -VdaVersion v2507 `
    -AllowedInboundIp 203.0.113.10/32
```

Add `-KeepOnError` when you're chasing a failing build: the build VM then survives a failure so you can inspect it (see [Troubleshooting → A build fails or hangs](troubleshooting.md#a-build-fails-or-hangs-getting-into-the-build-vm)).

`-AllowedInboundIp` is the address your traffic leaves from. By default Packer reaches the build VM over WinRM through a public IP, and without this setting its network rule allows any source. The script refuses to build without it. Behind a corporate proxy with several egress addresses, give the range your network team provides.

#### Private-network builds (no public IP)

Many enterprise subscriptions deny public IP addresses by policy; Azure Landing Zone "corp" policies do, for example. The default build then fails within a minute with `InvalidTemplateDeployment` and `policy violation`. In that case, build on your own network:

| You need | Details |
|---|---|
| **A subnet for the build VM** | An existing subnet, in the **same subscription and region** as the build resource group (a NIC can't join a VNet in another subscription). The build VM needs outbound HTTPS, through your firewall or NAT, to your storage account (the installers) and, if you install browsers, to `dl.google.com` and `download.mozilla.org`. It needs no inbound access from outside the VNet. If the VNet uses custom DNS servers (for example, domain controllers), they must be running during the build. |
| **A machine to run the build from** | Something that can reach the subnet on TCP 5986 (WinRM over HTTPS): a small VM in the same or a peered VNet, or a self-hosted CI agent. It needs PowerShell 7, Azure CLI, Packer and git, plus outbound HTTPS to Azure Resource Manager, Microsoft Entra ID and GitHub (for the Packer plugin and `citrix-packer-tools`). On an Azure VM, run `az login --identity` first: Packer then signs in as the VM's managed identity, and no secret is stored on the machine. |
| **Permission to join the subnet** | The identity Packer runs as needs `Microsoft.Network/virtualNetworks/subnets/join/action` on the subnet, in addition to Contributor on the build resource group. Network Contributor scoped to just that subnet is enough. |

Then set the three keys in your vars file:

```json
"virtual_network_name":                "vnet-build",
"virtual_network_subnet_name":         "snet-image-build",
"virtual_network_resource_group_name": "rg-network"
```

With `virtual_network_name` set, `02-build.ps1` runs a private-network build:

- Packer creates no VNet, public IP or network security group.
- The build VM's NIC joins your subnet, so the subnet's own network security group and routes apply.
- `allowed_inbound_ip` and `-AllowedInboundIp` are ignored. Packer refuses them alongside `virtual_network_name`, so the script builds from a temporary copy of the template without that setting.

Run `02-build.ps1` from the machine inside the network. Steps 1, 2, 5 and 6 can still run from your workstation, because they only call Azure and Citrix Cloud APIs.

Build time is about 1 hour, plus 30–60 minutes for Windows Update depending on how far behind the marketplace image is. The build script clones `citrix-packer-tools` automatically if not present.

#### Windows Update

`02-build.ps1` installs Windows updates **before anything else**, so the VDA and apps go onto a patched OS. It renders a temporary copy of the template with a [`windows-update`](https://github.com/rgl/packer-plugin-windows-update) provisioner (plugin v0.18.5, installed by the script) as the first step:

- **Excluded:** Preview updates, and **KB5007651** (the Defender "Windows Security platform" update). KB5007651 is offered again after every install, so without the exclusion the provisioner loops indefinitely: six install-and-reboot cycles about three minutes apart before we stopped it.
- **`-WindowsUpdateExclude KB…`** adds exclusions, by KB number or title text, if another update loops or breaks a build.
- **`-SkipWindowsUpdate`** leaves it out. Use it only for quick test builds; an image for users should be patched.

#### Apps (optional)

Pass an app list to install apps into the image:

```powershell
.\02-build.ps1 -VarsFile win_server_2025.json -Os win_server_2025_dc -AppsFile example.apps.txt
```

- **The list** is a text file of [Chocolatey](https://community.chocolatey.org/packages) package IDs, one per line. `#` starts a comment, and `id version` pins a version. Start from [`packer/apps/example.apps.txt`](../packer/apps/example.apps.txt); keep one list per image or persona.
- **When it runs:** after the template's own steps (VDA, Optimizer, browsers) and just before cleanup, followed by a restart, because some installers need one.
- **Failures stop the build.** Exit codes 0, 1641 and 3010 pass; anything else fails the build and names the package.
- **What went in:** the build log lists every installed package and version (`installed-app:` lines). Pin versions in the list when you need a build to be repeatable.
- **Chocolatey itself** is installed from its pinned release MSI (2.7.4). The build VM checks the MSI against a recorded SHA-256 and its Chocolatey Software signature before installing it, and stops on a mismatch. `-ChocoMsiUrl <url>` downloads the same file from your own mirror; the same checks apply. To upgrade, change `$chocoVersion` and `$chocoMsiSha256` in `02-build.ps1` together.
- **Internal feed:** `-ChocoSource <url>` installs the packages from your own feed and disables the community source.
- **Why not winget:** its community source fails to initialize in Packer's unattended WinRM session (`0x8a15000f`, "Data required by the source is missing"), even after bootstrapping App Installer.

At completion Packer outputs the gallery image version it published:

```
ManagedImageSharedImageGalleryId: /subscriptions/<sub>/resourceGroups/rg-flex-packer-build/providers/Microsoft.Compute/galleries/FlexPackerGallery/images/WinServer2025DC/versions/1.0.0
SharedImageGalleryImageVersion: 1.0.0
```

Bump `gallery_image_version` in your vars file for every build: a published version cannot be overwritten.

#### What the build verifies and records

**Before installing anything**, the build VM checks what it downloaded (`packer/scripts/provisioners/get-installers.ps1`):

- **Hashes:** the VDA installer and the Optimizer zip must match `vda_sha256` and `optimizer_sha256`.
- **Signature:** the VDA installer's Authenticode signature must be `Valid`, from `O=Citrix Systems, Inc.` (`vda_signer`).
- **Optimizer template:** `optimizer_template` must exist in the zip.

Any failure stops the build. It downloads with `curl.exe` and logs each download's time and speed.

**Pinned inputs**, so two builds from the same commit and vars file get the same parts:

| Input | Pinned to | Change it with |
|---|---|---|
| citrix-packer-tools (VDA, Optimizer and cleanup scripts) | the commit this repo was last validated with | `-PackerToolsRef <commit or tag>` |
| Marketplace image | `latest` resolved to an exact version before the build | `image_version` in the vars file |
| Packer plugins | azure v2.6.5, windows-update v0.18.5 | the script (legacy JSON uses the newest installed plugin, so the script warns if that isn't the pinned one) |
| Chocolatey | 2.7.4 | the script |

**The build record.** After a successful build (and only then), `02-build.ps1` writes `build-records/<image>-<version>.json` with:
- the installers' names, hashes, signer and thumbprint;
- the exact base image version and the citrix-packer-tools commit;
- the Windows updates installed and those excluded;
- the apps with versions;
- the OS build, and the build VM's Secure Boot and TPM state;
- the download times;
- the Packer and plugin versions.

It uploads a copy to the `build-records` container of your storage account, and tags the gallery version with the key fields (`vda`, `vdaSha256`, `baseImage`, `packerTools`, `buildRecord`). The full Packer log sits next to it in `build-records/`.

#### What Packer does internally

Understanding the build sequence prevents the "wrong VHD" mistake:

1. Deploys a VM from the marketplace image into the build resource group
2. Installs Windows updates (unless `-SkipWindowsUpdate`), then runs the template's provisioners (VDA install, restart, VDA install phase 2, Ngen, Optimizer, Chrome, cleanup)
3. **Powers off the VM**
4. **Publishes the OS disk (and its VM guest state) straight into the gallery image version.** With `"specialized": true` Packer skips the Generalize call, so the disk stays non-sysprepped — the state Citrix MCS needs
5. Deletes the build VM and its temporary resources

---

### Step 5 — Export the Gallery Version to VHD

```powershell
.\packer\scripts\powershell\04-export-from-gallery.ps1 `
    -GallerySubscriptionId "your-azure-subscription-id" `
    -GalleryResourceGroup  rg-flex-packer-build `
    -GalleryName           FlexPackerGallery `
    -ImageDefinition       WinServer2025DC `
    -ImageVersion          1.0.0 `
    -DestStorageAccount    flexpackerbuild `
    -DestResourceGroup     rg-flex-packer-build `
    -DestSubscriptionId    "your-azure-subscription-id"
```

The script creates a temporary managed disk from the gallery version, copies the OS VHD and the VMGS blob to `vhd-output` with AzCopy, deletes the temporary disk, and prints `vhd_uri` and `guest_disk_uri` with read SAS tokens. See [Exporting from Azure Compute Gallery](#exporting-from-azure-compute-gallery-customer-provided-images) for how it works.

#### Snapshot-based builds (`03-export-image.ps1`)

If you have a Packer OS-disk snapshot instead (a managed-image build), export it with:

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

1. Bump `gallery_image_version`, then run steps 4–5 to produce a new gallery version and VHD URI
2. Update `vhd_uri` in `terraform.tfvars` with the new SAS URI
3. Update `image_name` if you want a versioned name in the Citrix library
4. `terraform apply`

Terraform will update the template image in place and trigger Citrix to update the catalog. Existing sessions are not interrupted; machines are re-imaged on next restart.

> **Two warnings, from updates made through the API** (the Terraform path sits on the same service but is untested here):
> - **The new image's generation and Trusted Launch flags must match the catalog's.** If `hyperVGen`, `vtpmEnabled` or `secureBootEnabled` differ, the update reports success and then the catalog quietly goes back to the old image. So you can't move an existing catalog from a non-Trusted Launch image to a Trusted Launch one this way: create a new catalog from the new image.
> - **Static (dedicated) single-session catalogs are re-provisioned**, and the users' disks don't survive.
>
> [`07-update-catalog-image.ps1`](#update-a-catalogs-image) checks both before it changes anything, and confirms afterwards that the update held.

---

## Lifecycle with the API

Three scripts take an image through Citrix with the Quick Deploy API instead of Terraform: import it, move a catalog to it, and delete a domain-joined catalog. Use them in a scripted pipeline, to update the image of a catalog that already exists, or to delete a domain-joined catalog that `terraform destroy` can't.

| Script | What it does | What it changes |
|---|---|---|
| `06-import-to-citrix.ps1` | Imports the exported OS VHD and VMGS, waits for `Ready`, reads back the generation and Trusted Launch flags | Adds an image to the library |
| `07-update-catalog-image.ps1` | Pre-checks, the image update, then a read-back that catches a silent revert | The catalog's image; machines restart onto it |
| `08-delete-catalog.ps1` | A delete that carries the domain join credentials; waits until the catalog is gone; optionally removes it from Terraform state | Deletes the catalog and its machines |

`07` and `08` take `-CatalogName` or `-CatalogId`. All three are in `packer/scripts/powershell/` and run under PowerShell 7 on Windows, macOS or Linux.

### Credentials and site ID

The scripts read the API client from the same environment variables as the Citrix Terraform provider:

```powershell
$env:CITRIX_CUSTOMER_ID   = "your-customer-id"
$env:CITRIX_CLIENT_ID     = "your-api-client-id"
$env:CITRIX_CLIENT_SECRET = "your-api-client-secret"   # from your secret manager
```

- **The client secret** is read from `CITRIX_CLIENT_SECRET` only, never from a parameter, so it stays out of your shell history. It's sent once, to the token endpoint, and never printed.
- **The token** comes from `POST https://api.cloud.com/cctrustoauth2/root/tokens/clients` (client credentials). Calls send it as `Authorization: CwsAuth Bearer=<token>`. That's Citrix's `CwsAuth` scheme, not a plain `Bearer` header. Tokens last an hour, and the scripts renew them during long waits.
- **The site ID:** image and catalog calls are site-scoped, `/catalogservice/{customerId}/{siteId}/...`. The console doesn't show the site ID. The scripts read it from `GET https://api.cloud.com/cvad/manage/me` (`Customers[0].Sites[0].Id`); pass `-SiteId` to skip the lookup.
- **Outside the US**, pass `-ApiHost`: `api-eu.cloud.com`, `api-ap-s.cloud.com` or `api.citrixcloud.jp`.

### Import an image

After [Step 5](#step-5--export-the-gallery-version-to-vhd), pass the two URIs the export printed:

```powershell
.\packer\scripts\powershell\06-import-to-citrix.ps1 `
    -Name         WinServer2025DC-1.1.0 `
    -VhdUri       "<vhd_uri from the export>" `
    -GuestDiskUri "<guest_disk_uri from the export>" `
    -Region       eastus
```

**Before it calls Citrix,** the script checks that:
- both URIs carry a read SAS that hasn't expired (it warns under two hours left);
- Secure Boot has its VMGS blob;
- no image already has that name.

**It sends** `POST https://api.cloud.com/catalogservice/{customerId}/{siteId}/images/$import`:

```json
{
  "name": "WinServer2025DC-1.1.0",
  "vhdUri": "<vhd_uri>",
  "vhdEncryptionUri": "<guest_disk_uri>",
  "osPlatform": "Windows",
  "region": "eastus",
  "hyperVGen": "V2",
  "vtpmEnabled": true,
  "secureBootEnabled": true,
  "notes": "Imported by flex-image-builder 06-import-to-citrix.ps1"
}
```

**Then it waits** while the image goes `Pending` → `Importing` → `Ready`, usually 15–25 minutes.

**Then it reads back** `hyperVGen`, `vtpmEnabled` and `secureBootEnabled` from the image. It fails unless all three are what it asked for. The API ignores fields it doesn't recognize and still returns success (see the [field map](#terraform--api-field-map)), so this read-back is the only proof the image is right.

Trusted Launch (Gen2, vTPM, Secure Boot) is the default. For a Gen2 image without guest state, add `-NoSecureBoot` and leave out `-GuestDiskUri`; vTPM alone works from a plain Gen2 VHD.

To check an image that's already imported, or to keep waiting after a timeout, run `06-import-to-citrix.ps1 -ImageId <id>`. Add the same `-NoSecureBoot` / `-NoVtpm` you imported with.

> **Use the site-scoped route.** `POST /catalogservice/{customerId}/images`, without the site ID, looks right but is the bring-your-own-subscription route. Its images stay `Pending` forever. See [Troubleshooting](troubleshooting.md#an-imported-image-stays-pending-forever).

### Update a catalog's image

Run the checks first. `-CheckOnly` makes no changes:

```powershell
.\packer\scripts\powershell\07-update-catalog-image.ps1 -CatalogName "Task Worker Desktop" -ImageId <image id> -CheckOnly
.\packer\scripts\powershell\07-update-catalog-image.ps1 -CatalogName "Task Worker Desktop" -ImageId <image id>
```

**Pre-checks.** The script stops, and changes nothing, unless all of these hold:
- the new image is `Ready`;
- it has the catalog's session type (single- or multi-session);
- the catalog is `Active` or `InputRequired`;
- its `hyperVGen`, `vtpmEnabled` and `secureBootEnabled` match the catalog's **current image**. A mismatch is the silent revert described under [Updating an Image](#updating-an-image);
- the catalog isn't static (dedicated) single-session. Those machines are re-provisioned and users lose their disks; `-Force` overrides this check only.

**The update** is `POST .../catalogs/{catalogId}/$updateImage` with `{"TemplateId": "<image id>", "CitrixPrepared": false, "VdaUpdateDelay": 0}`, in that exact casing. `CitrixPrepared` is `false` for an image you imported; the script takes it from the image. `-VdaUpdateDelay` sets when machines restart onto the new image:

| `-VdaUpdateDelay` | Machines restart |
|---|---|
| `0` (default) | now, all of them; sessions on them end |
| `-1` | at each machine's next shutdown |
| `N` | spread over N minutes, with a warning to users first |

**The read-back.** The script waits for the catalog to go `Processing` → `Active`. It waits `-SettleMinutes` more (default 5), because a revert shows up only after the update has reported success. Then it confirms the catalog's `imageId` is the new image, and fails if it isn't.

> **Citrix-prepared images report the wrong generation in their detail view.** `GET .../images/{id}` returns `hyperVGen: V1` (and no region) for Citrix-prepared Gen2 images. The image list, `GET .../images`, has the right value. The script compares flags from the list, and says so when the two disagree.

### Delete a domain-joined catalog

A domain-joined catalog's delete needs the domain service account, so the backend can remove the machines' computer accounts. Without it, the delete ends in `Error` (`ErrorDeletionUnknown`). The Terraform provider's delete doesn't send the credentials, even though they're in state, so `terraform destroy` fails this way. Sending a credentialed delete again also recovers a catalog left in `Error` by an earlier delete.

```powershell
$env:TF_VAR_domain_service_account_password = "<join account password>"   # same variable Terraform uses
.\packer\scripts\powershell\08-delete-catalog.ps1 -CatalogName "Task Worker Desktop" -WhatIf
.\packer\scripts\powershell\08-delete-catalog.ps1 -CatalogName "Task Worker Desktop"
```

The script asks you to confirm. It sends `DELETE .../catalogs/{catalogId}?async=true` with `Content-Type: application/json` (without that header the call fails with HTTP 415), and this body:

```json
{"forceDelete": false, "deleteVm": true, "deleteResourceLocationIfUnused": false,
 "serviceAccount": "<account>", "serviceAccountPassword": "<password>"}
```

Then it polls `GET .../catalogs/status?catalogId={catalogId}` until the catalog is `NotFound`, usually 8–15 minutes.

- **The account** defaults to the one the catalog was created with. Pass `-ServiceAccount` to use another.
- **The password** comes from the environment variable named by `-PasswordVariable` (default `TF_VAR_domain_service_account_password`) and is never printed.
- **Your domain controllers must be running.** The delete reaches AD through the catalog's connectors.
- **`-DeleteResourceLocationIfUnused`** also removes the catalog's resource location and its connectors when no other catalog uses them. The connectors' computer accounts can stay behind in AD; remove them yourself.

**With Terraform, the order matters:**

1. `08-delete-catalog.ps1 -CatalogName <name> -TerraformDir <example dir>`: the credentialed delete, the wait for `NotFound`, then `terraform state rm` for the catalog. The address defaults to `module.catalog.citrix_quickdeploy_catalog.this`; set `-TerraformAddress` for another one.
2. `terraform destroy` for everything else.

If you run `terraform destroy` while the delete is still running, the provider's own delete fails with "Deletion of this catalog is already in progress", and the destroy stops.

### Terraform ↔ API field map

The Quick Deploy API reads request bodies leniently. It drops property names it doesn't recognize, with no warning, and the call still succeeds. A field named as in Terraform is the easy mistake:

- sending `machineGeneration: "V2"` imports a **Gen1** image, and a later catalog update with it reverts;
- sending `guestDiskUri` imports no guest state.

| Terraform (`citrix_quickdeploy_template_image`) | Quick Deploy API (`.../images/$import`) |
|---|---|
| `machine_generation` | `hyperVGen` |
| `vhd_uri` | `vhdUri` |
| `guest_disk_uri` | `vhdEncryptionUri` |
| `vtpm_enabled` | `vtpmEnabled` |
| `secure_boot_enabled` | `secureBootEnabled` |
| `os_platform` | `osPlatform` |
| `notes` | `notes` |

For catalog naming, the API shape is `"machineNamingScheme": {"namingScheme": "abc##", "isSchemeTypeNumeric": true}`. Sending `namingSchemeType: "Numeric"` names machines alphabetically.

The API names come from Citrix's public Go SDK models ([`ImportTemplateImageModel`](https://github.com/citrix/citrix-daas-rest-go/blob/main/citrixquickdeploy/docs/ImportTemplateImageModel.md)). **Rule of thumb:** after any import, read back `hyperVGen`, `vtpmEnabled` and `secureBootEnabled` before you use the image; `06-import-to-citrix.ps1 -ImageId <id>` does that.

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

> The `<site_id>` GUID is not shown in the Citrix UI. Get it from `GET https://api.cloud.com/cvad/manage/me` with the same headers: it's `Customers[0].Sites[0].Id`. (Or enable Terraform debug logging, `TF_LOG=DEBUG`, and search the output for `catalogservice/<customer_id>/`: the GUID after the customer ID is the site ID.)

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

## Trusted Launch → `terraform destroy` blocked by provider validation

**Symptom:** After setting `guest_disk_uri` in `main.tf`, `terraform destroy` fails with:

```
Error: Error validating Template Image configuration
Guest Disk URI is only applicable when Secure Boot is enabled
```

This happens even when the `guest_disk_uri` variable value is `null` in `terraform.tfvars`.

**Why it happens:** The citrix/citrix provider's `ValidateResourceConfig` hook runs against the HCL configuration on every plan/apply/destroy cycle, not just on apply. When `guest_disk_uri = var.guest_disk_uri` is present as an attribute in `main.tf`, the provider evaluates it even if the resolved value is null. This appears to be a provider validation bug — a null value should not trigger the "URI is only applicable when..." check.

**Fix for destroy:** Temporarily remove the `guest_disk_uri = var.guest_disk_uri` line from `main.tf`, run the destroy, then restore it before the next apply.

```hcl
# Temporarily remove this line from main.tf before terraform destroy:
guest_disk_uri = var.guest_disk_uri
```

This is the **only workaround** — passing `-var "guest_disk_uri=null"` on the command line does not work because Terraform passes the literal string `"null"` rather than HCL null to the provider.

---

## Exporting from Azure Compute Gallery (customer-provided images)

If images are already published to an Azure Compute Gallery (via Azure Image Builder, a customer's Packer pipeline, or any other build process), use `packer/scripts/powershell/04-export-from-gallery.ps1` instead of the snapshot-based `03-export-image.ps1`.

```powershell
.\packer\scripts\powershell\04-export-from-gallery.ps1 `
    -GallerySubscriptionId <gallery-subscription-id> `
    -GalleryResourceGroup  <gallery-rg> `
    -GalleryName           <gallery-name> `
    -ImageDefinition       <image-definition-name> `
    -ImageVersion          1.0.0 `
    -DestStorageAccount    <dest-storage-account> `
    -DestResourceGroup     <dest-rg> `
    -DestSubscriptionId    <dest-subscription-id>
```

`GallerySubscriptionId` and `DestSubscriptionId` can be different — this is the typical customer scenario where the gallery and the Citrix-facing storage are in different Azure subscriptions.

### How the gallery script works

The Azure Compute REST API `beginGetAccess` endpoint — which returns the VMGS SAS for snapshots — does not exist for gallery image versions. The gallery export script uses a different path:

1. Creates a temporary managed disk from the gallery image version using `az disk create --gallery-image-reference`.
2. For TrustedLaunch images, detects the security type from the image definition and passes `--security-type TrustedLaunch` to `az disk create`. Without this flag, Azure rejects the disk creation: *"The provided gallery image supports creation of OS disk only with SecurityType as TrustedLaunch."*
3. Calls `az disk grant-access --secure-vm-guest-state-sas` — the managed disk CLI command exposes this flag natively (unlike `az snapshot grant-access`, which does not support a VMGS flag in az CLI).
4. AzCopies the OS VHD and VMGS to destination blob storage.
5. Deletes the temporary managed disk.

This means a managed disk of the full image size is created and billed for the duration of the export (~10–30 minutes). Use Standard_LRS to minimize cost.

### Key differences from the snapshot path

| | Snapshot (`03-export-image.ps1`) | Gallery (`04-export-from-gallery.ps1`) |
|---|---|---|
| VMGS access method | REST `beginGetAccess` with `getSecureVMGuestStateSAS` | `az disk grant-access --secure-vm-guest-state-sas` |
| az CLI VMGS flag | ❌ Not supported (`--security-data-access-level Read` is unrecognized) | ✅ `--secure-vm-guest-state-sas` |
| Temp resource created | None | Managed disk (~10-30 min, Standard_LRS billing) |
| Source URL format | Internal blob (`*.blob.storage.azure.net`) — requires AzCopy | Disk SAS — requires AzCopy |

The gallery image must have been published with `security_type = TrustedLaunch` (not just `TrustedLaunchSupported`) for the VMGS SAS to be returned. Images without Trusted Launch guest state will produce a `vhd_uri` only; the script outputs `secure_boot_enabled = false` in that case.

---

## Available OS Templates

| Template name | OS | Catalog type | Notes |
|---------------|----|-------------|-------|
| `win_desktop_11_23h2` | Windows 11 23H2 | SingleSession or MultiSession (EVD) | |
| `win_office_11_23h2`  | Windows 11 23H2 + Office | SingleSession or MultiSession (EVD) | |
| `win_server_2019_dc`  | Windows Server 2019 | MultiSession only | |
| `win_server_2022_dc`  | Windows Server 2022 | MultiSession only | |
| `win_server_2025_dc`  | Windows Server 2025 | MultiSession only | Validated end-to-end |
