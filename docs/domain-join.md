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

## Troubleshooting FailedToExecuteSearchInAD

**Step 1:** Check if the service account is locked in AD. Unlock it.

**Step 2:** Check if the password has expired or is close to expiry. Reset it and set to never expire.

**Step 3:** Run an isolation test — keep `onprem_network_connection_id` but remove `domain_identity`. If the catalog deploys successfully, the failure was isolated to the AD credentials, not the image, quota, or VNet configuration.

**Step 4:** Check connector type in Citrix Cloud > IAM > Domains. If Connector Appliance is shown instead of Cloud Connector, that is a separate root cause (see [CTX696525](https://support.citrix.com/external/article/CTX696525)).

**Step 5:** After resolving, re-run `terraform apply`. No state cleanup is needed unless the previous attempt left a catalog in an Error state — see [Troubleshooting](troubleshooting.md) for how to delete a stuck catalog.
