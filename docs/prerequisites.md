---
layout: default
title: Prerequisites
nav_order: 2
---

# Prerequisites
{: .no_toc }

<details open markdown="block">
  <summary>Contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Citrix Cloud

- A Citrix Cloud account with **Platform Flex entitlement**
- An API key (client ID + client secret) from **Citrix Cloud > Identity and Access Management > API Access**
- At least one **Citrix Cloud Connector** registered on your AD domain (not Connector Appliance — see [Domain Join](domain-join.md))

## Networking

- A **VNet peering / Network Connection** configured in Citrix Cloud linking Platform Flex to your on-premises or Azure network
- Required even if you are not domain-joining — VNet peering routes catalog egress through your network firewall rather than directly to the internet

The Network Connection ID (a GUID) is found in **Citrix DaaS > Manage > Network Connections**.

### Recommended connectivity: dual ExpressRoute

Citrix-managed capacity peers with a VNet you manage, and that VNet connects to your locations. [Citrix leaves that connection up to you](https://docs.citrix.com/en-us/citrix-daas-azure/network-connections.html). For production, start with two metered ExpressRoute circuits at different peering locations:

| Component | Recommendation |
|---|---|
| **Primary circuit** | 10 Gbps, Standard, metered data, at peering location A |
| **Secondary circuit** | 5 Gbps, Standard, metered data, at peering location B |
| **ExpressRoute gateway** | Ultra Performance or ErGw3AZ, shared by both circuits. [Rated for 10 Gbps](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-faqs) |

**Plan for these:**

- **Failover capacity:** if the primary fails, the secondary carries only 5 Gbps. Check that this covers your traffic, or size the secondary to match.
- **Costs:** a monthly fee for each circuit, an hourly fee for the gateway, and outbound data on whichever circuit carries it. Inbound is free. Carrier and cross-connect fees are extra. Metered plans suit most environments, but compare them with unlimited plans if you send a lot of data out. Get current rates from the [Azure pricing calculator](https://azure.microsoft.com/en-us/pricing/calculator/), and confirm them before you quote them.
- **Address space:** the peered range [can't overlap](https://docs.citrix.com/en-us/citrix-daas-azure/network-connections.html) any address in Azure or on-premises.

A [test lab](lab-environment.md) doesn't need ExpressRoute.

## Active Directory (domain-joined catalogs only)

- A **dedicated service account** (e.g. `flexsp`) with:
  - Permission to create and delete computer objects in the target OU
  - List Contents + Read All Properties on the target OU
  - Password set to **never expire** (MCS will lock the account after repeated failed bind attempts — see [Troubleshooting](troubleshooting.md))
- The target **OU path** in `OU=Name,DC=domain,DC=com` format

## Tooling

| Tool | Minimum version | Install |
|---|---|---|
| Terraform | 1.5 | [terraform.io](https://developer.hashicorp.com/terraform/install) |
| Citrix Terraform provider | 1.0.36 | Declared in `versions.tf`, auto-installed by `terraform init` |

**Windows:**
```powershell
winget install HashiCorp.Terraform
```

**macOS / Linux:**
```bash
brew install terraform
```

## Azure Quota (optional — relevant for large deployments)

Platform Flex provisions VMs in a **Citrix-managed Azure subscription**, so standard customer quota limits do not apply. However, for `SingleSessionStatic` catalogs, one VM is provisioned per user — verify your `number_of_users` setting is appropriate before applying.

Setting up a place to test? See [Lab Environment](lab-environment.md).

---

Next: [Getting Started](getting-started.md)
