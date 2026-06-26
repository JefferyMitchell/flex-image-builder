---
layout: default
title: Getting Started
nav_order: 3
---

# Getting Started
{: .no_toc }

<details open markdown="block">
  <summary>Contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## 1. Clone the repository

**Windows (PowerShell):**
```powershell
git clone https://github.com/JefferyMitchell/flex-image-builder.git
cd flex-image-builder
```

**macOS / Linux (bash):**
```bash
git clone https://github.com/JefferyMitchell/flex-image-builder.git
cd flex-image-builder
```

## 2. Choose an example

Pick the example that matches your scenario from `infra/examples/`:

| Example | Persona | Domain join |
|---|---|---|
| `singlesession-domain-joined` | Knowledge Worker | Yes |
| `multisession-no-domain-join` | Task Worker (medium) | No (VNet peering only) |

```powershell
cd infra\examples\singlesession-domain-joined
```

```bash
cd infra/examples/singlesession-domain-joined
```

## 3. Set environment variables

Never put secrets in files. Set them as environment variables before every session.

**Windows (PowerShell):**
```powershell
$env:CITRIX_CLIENT_SECRET                   = "your-client-secret"
$env:TF_VAR_citrix_client_secret            = "your-client-secret"
$env:TF_VAR_domain_service_account_password = "your-service-account-password"
```

**macOS / Linux (bash/zsh):**
```bash
export CITRIX_CLIENT_SECRET="your-client-secret"
export TF_VAR_citrix_client_secret="your-client-secret"
export TF_VAR_domain_service_account_password="your-service-account-password"
```

> **Why two client secret variables?** The Citrix provider binary reads `CITRIX_CLIENT_SECRET` directly. Terraform's variable substitution in the `provider {}` block reads `TF_VAR_citrix_client_secret`. Both must be set or Terraform will prompt interactively for the missing value.

## 4. Configure variables

Copy the example vars file and edit it:

**Windows:**
```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars
```

**macOS / Linux:**
```bash
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

`terraform.tfvars` is git-ignored and must never be committed. It contains non-secret configuration values (catalog name, region, image ID, etc.). Secrets always stay in environment variables.

## 5. Pre-flight check (domain-joined catalogs only)

Before running `terraform apply` on any domain-joined catalog, verify:

| Check | How |
|---|---|
| Service account not locked | AD Users & Computers → confirm account is not locked out |
| Password not expiring | Set to "Password never expires" for dedicated service accounts |
| Cloud Connector registered | Citrix Cloud > Identity and Access Management > Domains → must show Cloud Connector, not Connector Appliance |

Skipping this check is the most common cause of failed deployments. Each failed apply attempt can lock the service account after repeated failed LDAP bind attempts. See [Domain Join](domain-join.md) for full details.

## 6. Initialise, plan, apply

```powershell
terraform init
terraform plan
terraform apply
```

```bash
terraform init
terraform plan
terraform apply
```

A SingleSession catalog typically deploys in **15–20 minutes**. MultiSession takes **25–35 minutes** due to the larger Windows Server image.

---

Next: [Personas](personas.md)
