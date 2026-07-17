# Provider Feedback: citrix_quickdeploy_template_image — Trusted Launch configuration

**Provider:** `citrix/citrix` v1.0.37  
**Resource:** `citrix_quickdeploy_template_image`  
**Source file (from debug log):** `internal/quickdeploy/cma_image/template_image_resource.go:316`  
**Terraform version:** 1.15.4  

---

## Context

We are building an automated Trusted Launch image pipeline for Citrix Platform Flex using
the Terraform provider. Our workflow exports a custom Gen2 VHD and its associated VMGS
(VM Guest State) file from Azure to blob storage and then registers the image via
`citrix_quickdeploy_template_image` with `secure_boot_enabled = true` and a
`guest_disk_uri` pointing to the VMGS blob.

During testing we encountered behavior we want to bring to the engineering team's
attention. We want to understand whether this reflects a design intent we have missed, or
whether it is an unintended side-effect of how `ValidateResourceConfig` interacts with
`Optional+Computed` attributes in terraform-plugin-framework.

---

## Observed behavior

When `guest_disk_uri` is present in the resource configuration alongside
`secure_boot_enabled = true`, `terraform apply` (and `terraform destroy`) fail
at the `ValidateResourceConfig` phase with:

```
Error: Error validating Template Image configuration
Guest Disk URI is only applicable when Secure Boot is enabled
```

This error fires **even when `secure_boot_enabled = true` is explicitly set** in the
Terraform configuration. Debug logging (see below) shows that the provider's
`ValidateConfig` method receives an empty/zero-valued struct — all attributes appear as
their Go zero values at validation time, regardless of what the user configured.

---

## Reproduction

### Minimum config

```hcl
# provider.tf
terraform {
  required_providers {
    citrix = {
      source  = "citrix/citrix"
      version = ">= 1.0.37"
    }
  }
}
provider "citrix" {
  cvad_config = {
    customer_id = "<customer-id>"
    client_id   = "<client-id>"
    # client_secret from env CITRIX_CLIENT_SECRET
  }
}

# main.tf
resource "citrix_quickdeploy_template_image" "test" {
  name                = "TrustedLaunchTest"
  os_platform         = "Windows"
  machine_generation  = "V2"
  region              = "eastus"
  subscription_name   = "Citrix Managed"
  notes               = "Bug repro"
  vhd_uri             = "https://<storage>.blob.core.windows.net/<container>/<os>.vhd?<sas>"
  guest_disk_uri      = "https://<storage>.blob.core.windows.net/<container>/<vmgs>.vhd?<sas>"
  secure_boot_enabled = true
  vtpm_enabled        = true
}
```

### Steps to reproduce

```
export CITRIX_CLIENT_SECRET="<secret>"
terraform init
terraform apply -auto-approve
```

### Expected result

Plan proceeds; resource is created with Trusted Launch (Secure Boot + vTPM) enabled.

### Actual result

```
Error: Error validating Template Image configuration

  with citrix_quickdeploy_template_image.test,
  on main.tf line 1, in resource "citrix_quickdeploy_template_image" "test":
   1: resource "citrix_quickdeploy_template_image" "test" {

Guest Disk URI is only applicable when Secure Boot is enabled
```

Fails at `ValidateResourceConfig` before any API call is made.

---

## Root cause (from TF_LOG=JSON)

Enable JSON debug logging:

```powershell
$env:TF_LOG      = "JSON"
$env:TF_LOG_PATH = "tf-debug.log"
terraform apply -auto-approve
```

The provider's own debug log at the `ValidateConfig` call site shows:

```json
{
  "@caller": "github.com/citrix/terraform-provider-citrix/internal/quickdeploy/cma_image/template_image_resource.go:316",
  "@level": "debug",
  "@message": "Validate Config - *cma_image.CitrixManagedAzureImageResourceModel",
  "guest_disk_uri": "",
  "id": "",
  "machine_generation": "",
  "name": "",
  "notes": "",
  "os_platform": "",
  "region": "",
  "secure_boot_enabled": false,
  "subscription_name": "Citrix Managed",
  "vhd_uri": "",
  "vtpm_enabled": false
}
```

**Every attribute the user configured is zero-valued in the struct.**
The provider's `ValidateConfig` method is logging the struct BEFORE or AFTER a failed
deserialization — `req.Config.Get(ctx, &plan)` either is not being called or the
populated struct is not being used. Only `subscription_name` retains its correct value,
which suggests it may have a different deserialization path (e.g., a constant default
in the schema rather than read from config).

Because `secure_boot_enabled` is always `false` in the struct at validation time, the
check:

```
if guest_disk_uri is set && !secure_boot_enabled → error
```

fires unconditionally whenever `guest_disk_uri` is present in the user's config.

---

## Provider schema evidence

The provider declares `secure_boot_enabled` and `vtpm_enabled` as `Optional + Computed`:

```
$ terraform providers schema -json | jq '.provider_schemas["registry.terraform.io/citrix/citrix"].resource_schemas.citrix_quickdeploy_template_image.block.attributes | to_entries[] | select(.key | test("secure_boot|vtpm|guest_disk|vhd_uri")) | {(.key): {optional: .value.optional, computed: .value.computed, required: .value.required}}'

{
  "secure_boot_enabled": { "optional": true, "computed": true }
}
{
  "vtpm_enabled": { "optional": true, "computed": true }
}
{
  "guest_disk_uri": { "optional": true }
}
{
  "vhd_uri": { "required": true }
}
```

`secure_boot_enabled` and `vtpm_enabled` are `Optional+Computed`. For such attributes,
terraform-plugin-framework may pass the config value as `Unknown` during
`ValidateResourceConfig` (since the computed final value isn't resolved until Create).
If the provider's validation code calls `plan.SecureBootEnabled.ValueBool()` on an
`Unknown` value, it returns the zero value (`false`), which is incorrect.

The fix would be to check `!plan.SecureBootEnabled.IsUnknown() &&
!plan.SecureBootEnabled.IsNull() && !plan.SecureBootEnabled.ValueBool()` before raising
the diagnostic, or to defer this check to `ModifyPlan`/`Create` where computed values
are resolved.

---

## Design intent question

Before treating this as a defect, we want to raise a design question:

**Is `guest_disk_uri` intended to be set by the customer in HCL configuration?**

Because `secure_boot_enabled` and `vtpm_enabled` are marked `Optional+Computed` in the
provider schema, it is possible the intended workflow is:

1. Customer supplies only `vhd_uri` (the OS disk).
2. Citrix inspects the uploaded VHD and automatically detects whether it was built with
   `security_type = TrustedLaunch`.
3. The provider computes `secure_boot_enabled`, `vtpm_enabled`, and `guest_disk_uri` back
   to Terraform state as read-only facts from the Citrix API — without the customer
   needing to supply them.

If this is the correct model, then `guest_disk_uri` is an output attribute, not an input,
and the validation error is a side-effect of us setting it explicitly rather than a
provider defect. In that case, we would need guidance on:

- Whether Citrix auto-discovers and links the VMGS file when only `vhd_uri` is supplied.
- Whether the Citrix Platform Flex API supports Trusted Launch VMs that were built
  outside of Citrix's own pipeline (i.e., via a customer's Packer build).

If `guest_disk_uri` IS intended to be a customer-supplied input (which the `Optional`
schema flag would suggest), then the behavior below appears to be unintended, and the
notes in the "Technical detail" section may help locate the issue.

---

## Impact on our automation

Regardless of the root cause, the practical effect is:

1. We cannot automate Trusted Launch catalog creation end-to-end via Terraform. The
   `guest_disk_uri` + `secure_boot_enabled` combination blocks every `terraform apply`.

2. `terraform destroy` also fails when `guest_disk_uri` is present as an HCL attribute
   (even with a null value), because `ValidateResourceConfig` runs on every
   plan/apply/destroy cycle. We had to temporarily remove the attribute line from `main.tf`
   before each destroy to work around this.

3. Our customers have Trusted Launch images in Azure Compute Gallery today. If there is
   no Terraform path to consume them, they cannot use IaC for their catalog lifecycle.

---

## Current workaround

We have built a PowerShell script (`packer/scripts/powershell/04-export-from-gallery.ps1`)
that exports the OS VHD and VMGS from an Azure Compute Gallery image version to blob
storage and outputs SAS URIs. This step works well. The blocker is the Terraform provider
not accepting `guest_disk_uri` in config.

In the interim we are creating template images and catalogs manually via the portal for
Trusted Launch scenarios.

---

## Technical detail (for the provider team)

Enable JSON debug logging to reproduce:

```powershell
$env:TF_LOG      = "JSON"
$env:TF_LOG_PATH = "tf-debug.log"
terraform apply -auto-approve
```

The provider's own debug statement at the `ValidateConfig` call site (line 316 of
`template_image_resource.go`) logs the struct it is about to validate:

```json
{
  "@caller": "...internal/quickdeploy/cma_image/template_image_resource.go:316",
  "@level": "debug",
  "@message": "Validate Config - *cma_image.CitrixManagedAzureImageResourceModel",
  "guest_disk_uri": "",
  "id": "",
  "machine_generation": "",
  "name": "",
  "notes": "",
  "os_platform": "",
  "region": "",
  "secure_boot_enabled": false,
  "subscription_name": "Citrix Managed",
  "vhd_uri": "",
  "vtpm_enabled": false
}
```

All user-configured values are zero at the point of validation. The provider schema
marks `secure_boot_enabled` and `vtpm_enabled` as `Optional+Computed`. In
terraform-plugin-framework, `Optional+Computed` attributes may be passed as `Unknown`
during `ValidateResourceConfig` (because the computed value is not yet resolved). If the
validation code evaluates `plan.SecureBootEnabled.ValueBool()` on an `Unknown` value, it
returns `false`, which causes the check to fire even when the user configured `true`.

One approach that may resolve this: guard the diagnostic with
`!plan.SecureBootEnabled.IsUnknown() && !plan.SecureBootEnabled.IsNull()` before calling
`.ValueBool()`, or move the cross-attribute check to `ModifyPlan` or `Create` where
computed values are fully resolved.

We share this in the spirit of collaboration — happy to provide the full debug log or
answer any questions to help clarify the behavior.

---

## Evidence files

| File | Contents |
|------|---------|
| `tf-debug.log` | Full `TF_LOG=JSON` output from failed apply — key struct at line 1150 |
| Call stack | `ValidateResourceConfig` → `server_validateresourceconfig.go:95` → `template_image_resource.go:316` |
| Destroy TransactionId | `fe8966d3-6b6b-47e8-a5e3-4fbe40a1ae33` (separate async deletion issue, domain-joined catalog) |

Full debug log available on request.
