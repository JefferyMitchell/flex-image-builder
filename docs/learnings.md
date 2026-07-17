---
layout: default
title: Learnings & Outcomes
nav_order: 8
---

# Learnings & Outcomes
{: .no_toc }

This page captures discoveries, platform constraints, and process insights from building
and validating the custom image pipeline — particularly around Trusted Launch
(Secure Boot + vTPM). The intent is to accelerate future development and to surface
feedback that benefits the broader Citrix and partner ecosystem.

<details open markdown="block">
  <summary>Contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Goal and context

The project goal is to give Citrix Platform Flex customers a repeatable, code-first path
for deploying catalogs from custom golden images. The Trusted Launch workstream extended
this to support Gen2 VMs with Secure Boot and vTPM — a security baseline that enterprise
customers increasingly require for Windows Server workloads.

This required solving problems across four layers: Packer, Azure, the Citrix REST API,
and the Citrix Terraform provider. Each layer surfaced distinct learnings.

---

## What we validated works

- **Packer builds Gen2 TrustedLaunch images** with `"security_type": "TrustedLaunch"` in the
  Azure builder. The OS disk snapshot is preserved in the resource group even when the
  build exits non-zero (see [Managed image restriction](#managed-image-restriction-packer--trustedlaunch)).

- **VMGS extraction via Azure REST API** works reliably. Using `beginGetAccess` with
  `getSecureVMGuestStateSAS: true` returns both the OS SAS and the VMGS (VM Guest State)
  SAS in a single LRO response. The `az snapshot grant-access` CLI command does not expose
  this flag, so the REST path is required.

- **AzCopy v10 successfully transfers both OS VHD and VMGS** (~130 GB OS + ~4 MB VMGS)
  from Azure snapshot SAS URLs to a customer-controlled storage account. The Azure Blob
  copy API cannot handle internal Azure snapshot URLs (`*.blob.storage.azure.net`) and
  must not be used as a substitute.

- **The export scripts work end-to-end** for both the snapshot workflow
  (`03-export-image.ps1`) and the Azure Compute Gallery workflow
  (`04-export-from-gallery.ps1`). Both produce the `vhd_uri` and `guest_disk_uri` SAS
  URIs that `citrix_quickdeploy_template_image` expects.

- **The Citrix provider (v1.0.37) accepts `secure_boot_enabled` and `vtpm_enabled`**
  in the schema — the attributes exist and are settable in principle.

---

## What we discovered does not yet work

### Provider validation blocks `guest_disk_uri` on apply

`terraform apply` fails at the `ValidateResourceConfig` phase when `guest_disk_uri` is
present in the configuration, even when `secure_boot_enabled = true` is set alongside it.

Debug logging (`TF_LOG=JSON`) revealed that the provider's `ValidateConfig` method
receives a zero-valued struct — all user-configured attributes are empty — and the
cross-attribute check fires unconditionally. This is documented fully in
[bug-report-provider-validate-config.md](bug-report-provider-validate-config.md).

**Open question for Citrix engineering:** Is `guest_disk_uri` intended to be a
customer-supplied input, or is it a computed attribute that Citrix resolves internally
from the uploaded VHD? The answer determines whether this is a provider defect or a
workflow misunderstanding.

**Current state:** Trusted Launch catalogs cannot be deployed end-to-end via Terraform
in provider v1.0.37. Manual portal creation is required for the template image step.

### `terraform destroy` fails for domain-joined catalogs

When `citrix_quickdeploy_catalog` is configured with `on_prem_connectivity.domain_identity`,
`terraform destroy` occasionally triggers the Citrix async deletion backend and the
catalog enters an Error state after approximately 30 seconds:

```
Error: Catalog deletion is no longer in progress for catalog ID: ..., current state: Error
```

The provider does pass the service account credentials in the destroy plan — this is not
a credentials problem. The Citrix backend fails the unjoin or VM deprovision step
asynchronously, and the provider surfaces the final Error state as a Terraform error.

**Workaround:** Delete the catalog via the Citrix Cloud portal (Platform Flex → Catalogs
→ Delete), which appears to use a more robust deletion path. Then clean Terraform state:

```powershell
terraform state rm module.catalog.citrix_quickdeploy_catalog.this
terraform state rm citrix_quickdeploy_template_image.this
```

Retain the Citrix `TransactionId` from the Terraform error output for support escalation
if the pattern repeats.

---

## Key technical gotchas

### SAS expiry must be calculated in UTC

PowerShell's `(Get-Date)` returns **local time**. Appending `"Z"` to that value tells
Azure the expiry is UTC, but it is not — the resulting SAS is rejected with
`AuthenticationFailed: Signed expiry time must be after signed start time` on any machine
not running in the UTC timezone.

**Always use `[System.DateTime]::UtcNow`** when generating SAS tokens.

```powershell
# Wrong — local time with misleading Z suffix
$expiry = (Get-Date).AddHours(2).ToString("yyyy-MM-ddTHH:mmZ")

# Correct
$expiry = [System.DateTime]::UtcNow.AddHours(2).ToString("yyyy-MM-ddTHH:mmZ")
```

### Managed images cannot be created from TrustedLaunch VMs

Azure returns `OperationNotAllowed: Creation of managed images are not supported for
virtual machine with TrustedLaunch security type` when Packer tries to capture the VM
after the provisioning steps.

The OS disk **snapshot is preserved** in the resource group even though Packer exits with
code 1. The snapshot can be found and exported manually. Long-term fix: switch the Packer
template from `managed_image_name` to `shared_image_gallery_destination`, which is
supported for TrustedLaunch VMs.

### `az snapshot grant-access` does not support VMGS

`az snapshot grant-access --security-data-access-level Read` is not recognized in
az CLI v2.88.0. The VMGS SAS must be obtained via the Azure Compute REST API:

```
POST .../snapshots/{name}/beginGetAccess?api-version=2024-03-02
Body: {"access":"Read","durationInSeconds":86400,"getSecureVMGuestStateSAS":true}
```

The response is an LRO (202 Accepted). Poll the `Azure-AsyncOperation` header URL until
`status == "Succeeded"`, then read `properties.output.accessSAS` (OS disk) and
`properties.output.securityDataAccessSAS` (VMGS).

The same pattern applies to Azure Compute Gallery image versions — same endpoint shape,
same response structure.

### Provider validates config on every Terraform operation

The Citrix provider's `ValidateResourceConfig` runs on `plan`, `apply`, and `destroy`.
When `guest_disk_uri` is present as an attribute in `main.tf` (even with `null` value),
validation fails regardless of the operation type. Temporarily removing the attribute
line from HCL is currently the only workaround for `terraform destroy`.

---

## Process outcomes

### What the pipeline development taught us about the platform

1. **The VMGS file is the Trusted Launch primitive.** Citrix doesn't generate it — it
   must come from the Azure-side build. If a customer's image was built without
   `security_type = TrustedLaunch`, there is no way to retrofit Secure Boot after the
   fact. The image build is the point of no return.

2. **Azure Compute Gallery is the right long-term home for customer images.** The snapshot
   export path we built is an interim measure. ACG provides versioning, replication, and
   direct API access with the same `beginGetAccess` pattern. `04-export-from-gallery.ps1`
   unblocks customers who are already there.

3. **The REST API is more capable than the CLI.** Two CLI gaps were discovered in this
   project (`az snapshot grant-access` missing the VMGS flag, `az rest` mixing stderr
   into JSON output). Defaulting to direct REST calls via `Invoke-WebRequest` with a
   bearer token is more reliable for new or recently added Azure features.

4. **Terraform provider coverage lags feature availability.** The `guest_disk_uri`
   attribute was added in v1.0.37 but is not yet usable. Planning for a manual portal
   step as a temporary bridge is a realistic posture for features that are at the
   provider's leading edge.

### Recommendations for the next phase

- **Engage Citrix engineering** with the provider feedback document
  ([bug-report-provider-validate-config.md](bug-report-provider-validate-config.md)) to
  clarify whether `guest_disk_uri` is a user input or a computed attribute, and to surface
  the `ValidateConfig` deserialization behavior.

- **Fix the Packer template** to use `shared_image_gallery_destination` instead of
  `managed_image_name` so that builds succeed end-to-end without manual snapshot recovery.

- **Test the `04-export-from-gallery.ps1` script** against a real customer gallery image
  to validate the response shape differences between snapshot and gallery versions.

- **Verify Trusted Launch end-to-end** once the provider validation issue is resolved:
  RDP into a catalog VM and run `Confirm-SecureBootUEFI` — should return `True`.

- **Document the destroy workaround** for domain-joined catalogs in any runbook given to
  customers, so they know to use the portal for deletion rather than `terraform destroy`.
