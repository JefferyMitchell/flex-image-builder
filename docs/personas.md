---
layout: default
title: Personas
nav_order: 4
---

# Personas
{: .no_toc }

<details open markdown="block">
  <summary>Contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

Platform Flex uses personas to drive all sizing decisions — VM SKU, storage, session type, and sessions-per-VM. You choose a persona; Citrix provisions the right infrastructure for it.

## Available Personas

| Persona | Session type | VM SKU | vCPU | RAM | Disk | Sessions/VM |
|---|---|---|---|---|---|---|
| Task worker (medium) | MultiSession | Standard_D8as_v5 | 8 | 32 GB | 128 GB SSD | 8 |
| Task worker (heavy) | MultiSession | Standard_D8as_v5 | 8 | 32 GB | 128 GB SSD | 4 |
| Knowledge worker | SingleSession | Standard_D4as_v5 | 4 | 16 GB | 128 GB SSD | 1 |
| Power worker | SingleSession | Higher spec / GPU | — | — | — | 1 |

## Choosing a Persona

**Task worker (medium)** — Shared desktop users running standard applications (browser, Office, line-of-business apps). Best cost-per-user for general office workloads.

**Task worker (heavy)** — Shared desktop users with resource-intensive applications. Fewer sessions per VM than medium, more CPU/RAM headroom per user.

**Knowledge worker** — Dedicated VM per user. Suitable for users who need consistent, isolated performance — call centre agents, developers on lighter workloads, users with peripherals or personalisation requirements.

**Power worker** — Dedicated VM per user with higher compute. For AI, 3D modelling, video editing, or any GPU-accelerated workload.

## Terraform Configuration

```hcl
resource "citrix_quickdeploy_catalog" "example" {
  persona = "Knowledge worker"   # exact string, case-sensitive
  # ...
}
```

### Persona strings (exact values required)

```
"Task worker (medium)"
"Task worker (heavy)"
"Knowledge worker"
"Power worker"
```

### catalog_type

For **SingleSession** personas (Knowledge worker, Power worker), specify `catalog_type` explicitly alongside `persona`. This is required to work around a validation bug in provider versions prior to 1.0.36, and is harmless in newer versions:

```hcl
persona      = "Knowledge worker"
catalog_type = "SingleSessionStatic"
```

For **MultiSession** personas (Task worker medium/heavy), do **not** specify `catalog_type` — the provider derives it from the persona and will error if you set it explicitly.

## number_of_users

For `SingleSessionStatic`, one VM is provisioned per user. Set `number_of_users = 1` for testing. For production, this is your total licensed user count for the catalog.

For MultiSession, `number_of_users` drives the total session capacity. The provider divides this by `sessions_per_vm` (derived from persona) to determine VM count.
