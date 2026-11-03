---
layout: default
title: Troubleshooting
nav_order: 7
---

# Troubleshooting
{: .no_toc }

<details open markdown="block">
  <summary>Contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## FailedToExecuteSearchInAD

**Symptom:** `terraform apply` runs for 12–15 minutes then fails with a message containing `FailedToExecuteSearchInAD`.

**Root cause:** MCS performs an LDAP bind using the service account before creating any computer object. A locked account, expired password, or wrong password fails at the bind step. Citrix returns the same generic error regardless of the specific failure reason.

**Fix:**
1. Check the service account in AD — unlock if locked, reset password if expired
2. Set the account password to never expire
3. Wait a few minutes for AD replication, then re-run `terraform apply`

See [Domain Join](domain-join.md) for full details and an isolation test procedure.

---

## power_off_delay Unknown after apply (provider < 1.0.36)

**Symptom:** Apply completes but exits with: `Provider returned invalid result object after apply — provider still indicated an unknown value for power_schedule.power_off_delay`

**Root cause:** Provider bug in versions prior to 1.0.36. The `power_off_delay` attribute was returned as Unknown for SingleSession catalogs. The catalog **is** successfully created.

**Fix (if on older provider):**
```powershell
terraform untaint citrix_quickdeploy_catalog.<resource_name>
terraform plan   # expect: No changes
```

**Permanent fix:** Upgrade to provider >= 1.0.36. The `power_off_delay` attribute was removed and replaced with `session_timeout` in the reworked power schedule schema.

---

## Catalog name already in use

**Symptom:** `terraform apply` fails immediately with a message that the catalog name is already in use, even though the catalog doesn't appear in your Terraform state.

**Root cause:** A previous failed apply created the catalog in the Citrix backend. It may be in an Error or Deleting state but the name is still reserved.

**Fix:** Delete the catalog explicitly via the Catalog Service API, then wait for the name to clear before re-applying.

```powershell
# 1. Get a bearer token
$body = "grant_type=client_credentials&client_id=YOUR_CLIENT_ID&client_secret=YOUR_CLIENT_SECRET"
$token = (Invoke-RestMethod -Uri "https://api.cloud.com/cctrustoauth2/root/tokens/clients" `
    -Method POST -Body $body -ContentType "application/x-www-form-urlencoded").access_token

# 2. Delete the catalog
$headers = @{
    "Authorization"     = "CWSAuth bearer=$token"
    "Citrix-CustomerId" = "YOUR_CUSTOMER_ID"
    "Citrix-InstanceId" = "YOUR_SITE_ID"
    "Content-Type"      = "application/json; charset=utf-8"
}
$deleteBody = '{"forceDelete": true, "deleteResourceLocationIfUnused": false}'

Invoke-RestMethod `
    -Uri "https://api.cloud.com/catalogservice/YOUR_CUSTOMER_ID/YOUR_SITE_ID/catalogs/CATALOG_ID" `
    -Method DELETE -Headers $headers -Body $deleteBody
# Returns 204 NoContent on success

# 3. Wait 2-3 minutes, then verify name is gone before re-applying
```

```bash
# Get a bearer token
TOKEN=$(curl -s -X POST https://api.cloud.com/cctrustoauth2/root/tokens/clients \
  -d "grant_type=client_credentials&client_id=YOUR_CLIENT_ID&client_secret=YOUR_CLIENT_SECRET" \
  | jq -r '.access_token')

# Delete the catalog
curl -s -X DELETE \
  "https://api.cloud.com/catalogservice/YOUR_CUSTOMER_ID/YOUR_SITE_ID/catalogs/CATALOG_ID" \
  -H "Authorization: CWSAuth bearer=$TOKEN" \
  -H "Citrix-CustomerId: YOUR_CUSTOMER_ID" \
  -H "Citrix-InstanceId: YOUR_SITE_ID" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d '{"forceDelete": true, "deleteResourceLocationIfUnused": false}'
```

---

## terraform plan prompts for citrix_client_secret

**Symptom:** `terraform plan` prompts interactively for `var.citrix_client_secret`.

**Root cause:** Only `CITRIX_CLIENT_SECRET` was set, not `TF_VAR_citrix_client_secret`. Both are required.

**Fix:**
```powershell
$env:TF_VAR_citrix_client_secret = "your-client-secret"
```

```bash
export TF_VAR_citrix_client_secret="your-client-secret"
```

---

## ModifyPlan validation error (provider < 1.0.36)

**Symptom:** Plan fails with `Invalid catalog type` or `The specified catalog type is not valid as an add-on for the specified persona`.

**Root cause:** Provider bug in v1.0.35. Optional+Computed attributes are Unknown (not Null) for new resources, which triggers persona validation incorrectly.

**Fix (provider < 1.0.36):** Set `catalog_type` explicitly alongside `persona` for SingleSession catalogs:
```hcl
persona      = "Knowledge worker"
catalog_type = "SingleSessionStatic"
```

For MultiSession, there is no workaround in v1.0.35 — upgrade to >= 1.0.36.

**Permanent fix:** Upgrade to provider >= 1.0.36. Run:
```powershell
terraform init -upgrade
```

---

## A build fails within a minute: policy violation

**Symptom:** `02-build.ps1` stops shortly after `Deploying deployment template...` with:

```
ERROR: -> InvalidTemplateDeployment : The template deployment failed because of policy violation.
ERROR:   -> RequestDisallowedByPolicy : Resource 'pkrip…' was disallowed by policy. Policy identifiers: '[{"policyAssignment":{"name":"…"
```

**Cause:** an Azure Policy assignment denies a resource the build creates. The second line names both the resource and the policy assignment. A `pkrip…` resource is the build VM's **public IP**, and enterprise landing zones commonly deny public IPs on every subscription.

**Fix:** if it's the public IP, switch to a [private-network build](custom-images.md#private-network-builds-no-public-ip) instead of asking for an exemption. For anything else (for example, required tags, or allowed VM sizes or regions), match the policy in your vars file or template.

---

## A build fails after the download: optimizer_template is not in the zip

**Symptom:** about the time `Downloads complete.` would print, the build stops with:

```
optimizer_template 'Citrix_Windows_Server_2025.xml' is not in the Citrix Optimizer zip, so the image would not be optimized. Templates in this zip: Citrix_Windows_10_1607.xml, …
```

**Cause:** `optimizer_template` must match a file in the zip's `Templates` folder exactly, and the names carry a build suffix (`Citrix_Windows_Server_2025_2009.xml`). Before this check existed, the Optimizer step reported success on a wrong name, and the image was published without being optimized.

**Fix:** copy one of the names from the error, or from the list `01-upload-installers.ps1` prints, into your vars file and run the build again. See [Optimizer template names](custom-images.md#optimizer-template-names).

---

## A build keeps installing the same update

**Symptom:** during the Windows Update stage, the log shows the same update installed again after every reboot, a few minutes apart, and the build never moves on to the VDA install.

**Cause:** some updates are offered again even after they install. **KB5007651** (the Defender "Windows Security platform" update) does this, so `02-build.ps1` always excludes it, along with Preview updates.

**Fix:** stop the build and add the looping update with `-WindowsUpdateExclude`, for example `-WindowsUpdateExclude KB5012170`. It takes a KB number or any text from the update's title.

---

## A build fails in the app stage

**Symptom:** the build stops with `choco install failed for <id> (exit <code>)`.

**Cause:** usually one of these:
- the package ID is wrong (check it with `choco search <name>`);
- a pinned version doesn't exist;
- your internal feed (`-ChocoSource`) doesn't carry the package;
- the installer itself failed.

**Fix:** correct the list and build again. To see the installer's own error, rebuild with `-KeepOnError` and read `C:\ProgramData\chocolatey\logs\chocolatey.log` on the build VM through Run Command (see the next section).

---

## A build fails or hangs: getting into the build VM

**Background:** each build VM gets a one-time WinRM password. Packer generates it, never writes it anywhere and filters it from its logs, so there's no standing credential to leak. That also means there's no password for *you*. When a build fails or hangs, use the steps below instead. Each one leaves the build VM's image untouched until step 3.

### 1. Keep the VM

- **A failing build** deletes its VM by default. Re-run it with `-KeepOnError` (Packer's `-on-error=abort`), and the VM and its resources stay in the build resource group.
- **A hung build** (for example, stuck at `Waiting for WinRM` or at a provisioner) still has its VM. **Don't press Ctrl-C yet**, because that starts the cleanup.

The build VM is named `pkrvm<random>`. Its NIC, Key Vault and OS disk are named `pkrni…`, `pkrkv…` and `pkros…`. A public-network build also has a public IP, network security group and VNet, named `pkrip…`, `pkrsg…` and `pkrvn…`. A [private-network build](custom-images.md#private-network-builds-no-public-ip) uses your subnet instead.

```powershell
az vm list -g rg-flex-packer-build --query "[?starts_with(name,'pkrvm')].name" -o tsv
```

### 2. Look inside without logging in (Run Command)

Azure Run Command executes a script through the VM agent as SYSTEM. It needs no password and no open port, only Contributor (or Virtual Machine Contributor) on the resource group.

```powershell
$vm = "<pkrvm name>"
az vm run-command invoke -g rg-flex-packer-build -n $vm --command-id RunPowerShellScript --scripts '
  "== C:\setup";        Get-ChildItem C:\setup -ErrorAction SilentlyContinue | Select Name,Length,LastWriteTime
  "== VDA installer log"; Get-ChildItem "C:\Users\*\AppData\Local\Temp\Citrix\XenDesktop Installer\*.log" -ErrorAction SilentlyContinue |
                          ForEach-Object { $_.FullName; Get-Content $_.FullName -Tail 40 }
  "== Pending reboot";    Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
  "== Busy processes";    Get-Process | Sort-Object CPU -Descending | Select -First 10 Name,CPU,StartTime
  "== WinRM listeners";   winrm enumerate winrm/config/listener
  "== Recent errors";     Get-WinEvent -FilterHashtable @{LogName="Application","System"; Level=1,2} -MaxEvents 20 -ErrorAction SilentlyContinue |
                          Select TimeCreated,ProviderName,Message
'
```

Run Command answers most "why is it stuck" questions:

- an installer waiting on a reboot;
- a looping update;
- a WinRM listener that never came up;
- a failed provisioner script.

### 3. Interactive access (break-glass)

If you need a desktop session:

1. **Set a known password on that one VM.** This uses the VMAccess extension:
   ```powershell
   az vm user update -g rg-flex-packer-build -n $vm -u packer -p "<a new strong password>"
   ```
2. **Open RDP from your address only,** on the build VM's network security group (`pkrsg…`). WinRM is already limited to your address:
   ```powershell
   $nsg = az network nsg list -g rg-flex-packer-build --query "[?starts_with(name,'pkrsg')].name" -o tsv
   az network nsg rule create -g rg-flex-packer-build --nsg-name $nsg -n allow-rdp-debug `
       --priority 200 --access Allow --protocol Tcp --direction Inbound `
       --source-address-prefixes "<your egress IP>/32" --destination-port-ranges 3389
   ```
3. **Connect.** RDP to the `pkrip…` public IP as `packer`, using Microsoft Remote Desktop / Windows App on macOS.

**On a private-network build** there's no public IP and no `pkrsg…` group, so skip step 2. Instead, RDP to the build VM's private IP from a machine inside the network, or connect through Azure Bastion. Your subnet's network security group must allow 3389 from that machine; that rule belongs to your network team.

**Rules for break-glass access:**

- Resetting the password breaks Packer's own WinRM session. Treat that build as dead.
- **Never publish an image from a VM you've logged into or changed.** VMAccess installs an extension, and your session leaves profile data, logs and possibly credentials on the disk. Fix the cause, then rebuild from scratch.

### 4. Clean up

Delete what the failed build left behind. Run it again if a resource is still in use; the VM goes first, then the NIC, then the rest.

```powershell
az vm delete -g rg-flex-packer-build -n $vm --yes
az resource list -g rg-flex-packer-build --query "[?starts_with(name,'pkr')].id" -o tsv |
    ForEach-Object { az resource delete --ids $_ }
```

A soft-deleted `pkrkv…` Key Vault can be purged with `az keyvault purge -n <name>` if your policy allows it.

