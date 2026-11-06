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

### Create the network connection

Create the connection **before** the catalog that uses it, because a catalog's connection type can't be changed afterwards. These steps follow [Citrix's network connections guide](https://docs.citrix.com/en-us/citrix-daas-azure/network-connections.html), which also covers what the console shows in more detail.

**Have these ready:**

- **An Entra account that owns the Azure subscription.** Citrix doesn't support live.com accounts, or guest accounts from a different tenant.
- **The subscription, resource group and VNet** to peer with.
- **An unused address range for the Citrix-managed network.** It must not overlap anything in Azure or on-premises. For example, if your VNet is `10.0.0.0/16`, use a range such as `192.168.0.0/24`, not `10.0.0.0/24`.
- **DNS servers** that catalog machines can use. If you use Secure DNS or a third-party DNS provider, add the address range to its allow list.
- **Network security groups** on your VNet that are open to that address range.
- **Routes** that let catalog machines reach your network locations.

**Create it:**

1. In Citrix DaaS for Azure, go to **Quick Deploy > Microsoft Azure**, and expand **Network Connections**.
2. Click **Add Connection**, then the **Add Azure VNet Peering** box.
3. Click **Authenticate Azure Account**, sign in as the subscription owner, and accept the terms.
4. Enter a name for the peer, then select the subscription, resource group and VNet.
5. Say whether the VNet uses an Azure Virtual Network Gateway. If it does, choose whether to turn on **route propagation**, which adds routes through the gateway automatically. Changing this later can interrupt VDA traffic.
6. Enter the IP address and choose the network mask for the address range.
7. Say whether to add custom routes. For each one, enter a name, a destination with a prefix between 16 and 24, and a next hop type. For **Virtual appliance**, also enter its internal IP address.
8. Click **Add VNet Peering**.

**Afterwards:**

- Check the connection under **Network Connections > Azure VNet Peers**. Its details show its region, network space, peered VNets, routes, and what's using it.
- If you added custom routes, update your company's route tables with the Citrix destination VNet information.
- Changing custom routes later can disrupt user sessions.
- To delete the connection, remove its catalogs first.

Citrix's guide doesn't say how long this takes, or whether the address range can be changed afterwards, so choose the range carefully.

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
