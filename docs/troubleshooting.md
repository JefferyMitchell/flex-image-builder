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
