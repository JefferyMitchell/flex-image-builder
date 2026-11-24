---
layout: default
title: Domain Join
nav_order: 5
---

# Domain Join
{: .no_toc }

<details open markdown="block">
  <summary>Contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Overview

Domain join is configured via the `on_prem_connectivity` block in `citrix_quickdeploy_catalog`. This block serves two purposes:

1. **VNet peering** — routes catalog egress through your network firewall (`onprem_network_connection_id`)
2. **Domain join** — creates machine accounts in your AD and joins VMs to the domain (`domain_identity`)

VNet peering is required even without domain join if you need traffic routed through a firewall rather than directly to the internet.

> **Important:** `on_prem_connectivity` cannot be added to or removed from an existing catalog. It forces a destroy and recreate. Decide whether you need it before first deploy.

## Terraform Configuration

```hcl
on_prem_connectivity = {
  onprem_network_connection_id = var.onprem_network_connection_id

  domain_identity = {
    domain                   = "flexnova.net"
    domain_ou                = "OU=Citrix-Servers,DC=flexnova,DC=net"
    service_account          = "flexsp"                         # username only — no domain prefix
    service_account_password = var.domain_service_account_password
  }
}
```

For **VNet peering only** (no domain join), omit `domain_identity`:

```hcl
on_prem_connectivity = {
  onprem_network_connection_id = var.onprem_network_connection_id
}
```

## Service Account Requirements

The service account used for domain join must be able to:

- Bind to the domain via LDAP
- Search for existing machine objects in the target OU
- Create and delete computer accounts in the target OU

Minimum AD permissions on the target OU:
- List Contents
- Read All Properties
- Create Computer Objects
- Delete Computer Objects

> **Username format:** Supply the username only — `flexsp`, not `DOMAIN\flexsp` or `flexsp@domain.com`. The provider rejects the full UPN and SAM-with-domain formats.

## Pre-flight Checklist

Run this before every `terraform apply` on a domain-joined catalog.

| Check | Why |
|---|---|
| Service account is not locked out | MCS performs an LDAP bind before creating any computer object. A locked account fails at bind. |
| Service account password is not expired | Same as above — expired password = failed bind = `FailedToExecuteSearchInAD` |
| Password set to never expire | MCS compounds lockout with each failed apply attempt. A password close to expiry will expire mid-deployment. |
| Cloud Connector (not Connector Appliance) registered | Citrix Cloud > IAM > Domains — must show Cloud Connector |

## How MCS Uses the Service Account

MCS performs a two-step process before creating any VM:

1. **LDAP bind** — authenticates to the domain using the service account
2. **LDAP search** — checks the target OU for existing machine name conflicts

A locked or expired service account fails at step 1. Citrix surfaces this as `FailedToExecuteSearchInAD` regardless of whether the password is wrong, expired, or the account is locked. The error message gives no further detail.

Each failed apply attempt triggers another bind attempt, which can lock a nearly-expired or already-weakened account further. After 3–4 failures the account may be fully locked.

## Microsoft Entra hybrid join

A Quick Deploy catalog's machine identity is the console's **Domain type**: Active Directory, Microsoft Entra ID, or Microsoft Entra hybrid. **Terraform creates Active Directory joined catalogs only.** `citrix/citrix` (through v1.0.43) always sends `isAzureAdJoined: false`, and `domain_identity` has no identity setting.

### When you need it

- **Non-persistent machines that should be Entra hybrid joined.** Multi-session and random single-session machines reset at every boot. With the Active Directory identity, Windows does its own hybrid join at every boot and writes a new device certificate to the computer object's `userCertificate`, so Entra is always a sync behind. `dsregcmd /status` shows `AzureAdJoined : NO`, with error `0x801c005b` (signature verification failed). With the hybrid identity, MCS writes `userCertificate` when it creates the computer account, before the VM exists. After the next Entra Connect sync the machine joins at boot, and the join holds across reboots and image updates.
- **Features that require hybrid joined VDAs**, such as Citrix Profiles Flex.

### Creating one

- **Console:** create the catalog with Domain type **Microsoft Entra hybrid**.
- **API:** `POST catalogservice/{customerId}/{siteId}/catalogs/$manageddeploy` with `addCatalog.isDomainJoined: true` **and** `addCatalog.isAzureAdJoined: true`, plus the usual `addCatalogDomain`. The catalog reads back `catalogType: ManagedHybridEntraIdJoined` (an Active Directory joined one reads back `ManagedDomainJoined`). The published API reference doesn't say that both flags together mean hybrid.
- **This repo:** `10-create-catalog.ps1 -HybridEntraJoin` (**test script**) sends both, and fails unless the catalog reads back `ManagedHybridEntraIdJoined`:

```powershell
$env:TF_VAR_domain_service_account_password = "<join account password>"
.\packer\scripts\powershell\10-create-catalog.ps1 `
    -Name "Task Worker" -ImageName "<image>" -SessionType MultiSession -Region <azure-region> `
    -VnetPeeringName "<network connection>" -Domain corp.example -DomainOu "OU=VDAs,DC=corp,DC=example" `
    -ServiceAccount svc-join -HybridEntraJoin
```

### Prerequisites

- **The join account can write `userCertificate`** on computer objects in the catalog's OU, on top of the rights in [Service Account Requirements](#service-account-requirements).
- **Microsoft Entra Connect syncs the catalog's OU**, and the domain has the service connection point (SCP) for hybrid join: the usual Entra hybrid join setup.
- **A sync between account creation and first boot.** Run a delta sync (`Start-ADSyncSyncCycle -PolicyType Delta` on the Entra Connect server) after the catalog creates its computer accounts, or wait for the 30-minute cycle before the machines start.

### Checking it

In the guest, `dsregcmd /status` shows `DomainJoined : YES` and `AzureAdJoined : YES`. Reboot the machine and check again: on a hybrid catalog the join holds, and the computer object's `userCertificate` doesn't change.

### Terraform and hybrid catalogs

Terraform has no way to describe a hybrid catalog. If you import one, **the first replacement Terraform makes recreates it Active Directory joined**: an `enable_accelerated_networking` change, or the replacement that every import plans (see [Importing an existing catalog](accelerated-networking.md#importing-an-existing-catalog)). The plan doesn't say the identity is changing. Manage hybrid catalogs with the console or the API until the provider has an identity setting; if you do import one, use the `ignore_changes` workaround and never apply a plan that replaces it.

## Troubleshooting FailedToExecuteSearchInAD

**Step 1:** Check if the service account is locked in AD. Unlock it.

**Step 2:** Check if the password has expired or is close to expiry. Reset it and set to never expire.

**Step 3:** Run an isolation test — keep `onprem_network_connection_id` but remove `domain_identity`. If the catalog deploys successfully, the failure was isolated to the AD credentials, not the image, quota, or VNet configuration.

**Step 4:** Check connector type in Citrix Cloud > IAM > Domains. If Connector Appliance is shown instead of Cloud Connector, that is a separate root cause (see [CTX696525](https://support.citrix.com/external/article/CTX696525)).

**Step 5:** After resolving, re-run `terraform apply`. No state cleanup is needed unless the previous attempt left a catalog in an Error state — see [Troubleshooting](troubleshooting.md) for how to delete a stuck catalog.
