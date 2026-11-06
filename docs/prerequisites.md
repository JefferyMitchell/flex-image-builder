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

Citrix-managed capacity peers with a VNet you manage, and that VNet connects to your locations. [Citrix leaves that connection up to you](https://docs.citrix.com/en-us/citrix-daas-azure/network-connections.html). For production, start with two metered ExpressRoute circuits at different peering locations, sharing one zone-redundant gateway:

| Component | Recommendation | Price (Zone 1, US dollars) |
|---|---|---|
| **Primary circuit** | 10 Gbps, Standard, metered data, at peering location A | $3,400 a month |
| **Secondary circuit** | 5 Gbps, Standard, metered data, at peering location B | $2,180 a month |
| **ExpressRoute gateway** | ErGw3AZ, [rated for 10 Gbps](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-about-virtual-network-gateways) | $2.151 an hour, about $1,570 a month in East US 2 |
| **Fixed total** | | **About $7,150 a month** |
| **Outbound data** | On whichever circuit carries it | $0.025 per GB |
| **Inbound data** | | Free |

These are list prices from the [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices) on November 5, 2026. Your agreement may differ, gateway prices vary by region, and carrier and cross-connect fees are extra. Confirm them in the [Azure pricing calculator](https://azure.microsoft.com/en-us/pricing/calculator/) before you quote them.

| Monthly outbound data | Outbound cost | Total a month |
|---|---|---|
| 50 TB | $1,250 | About $8,400 |
| 200 TB | $5,000 | About $12,150 |
| 500 TB | $12,500 | About $19,650 |
| 1 PB | $25,000 | About $32,150 |

**Metered or unlimited:** a Standard unlimited plan costs $51,300 a month at 10 Gbps and $25,650 at 5 Gbps. Metered stays cheaper until a circuit sends about 1.9 PB a month at 10 Gbps, or about 940 TB at 5 Gbps.

#### Design for failure

Follow Microsoft's guidance on [high availability](https://learn.microsoft.com/en-us/azure/expressroute/designing-for-high-availability-with-expressroute) and [disaster recovery](https://learn.microsoft.com/en-us/azure/expressroute/designing-for-disaster-recovery-with-expressroute-privatepeering):

- **Peering locations:** two locations in one metro can fail together in a natural disaster, so prefer different metros. Keep them in the same geopolitical region, or both circuits need the Premium SKU, which costs more.
- **Providers and sites:** consider a different service provider for each circuit, and terminate the circuits at different locations on your network.
- **Inside each circuit:** run both links active-active, and don't terminate them on the same customer device. Microsoft recommends [high resiliency](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-locations-providers) as a minimum where it's available, at the same cost as standard.
- **Failure detection:** turn on BFD. Failover to the other site can still take up to 180 seconds.
- **Failover capacity:** if the primary fails, the secondary carries only 5 Gbps. Check that 5 Gbps covers your traffic, or size it up. You can raise a circuit's bandwidth later, but you can't reduce it.
- **Gateway capacity:** the gateway's 10 Gbps is a fixed limit, so traffic through it can't reach the circuits' combined 15 Gbps. It's also shared by both circuits, so it's worth planning for separately.
- **Testing:** if a circuit is on standby, test failover regularly.

#### Keep traffic on the primary

Set your preference in both directions, because traffic that goes out on one circuit and returns on the other can be blocked by a firewall or NAT in the path.

| Direction | How to prefer the primary |
|---|---|
| **Azure to your network** | In order of effectiveness: advertise more specific routes over the primary, set a higher connection weight on it, or prepend your AS number on routes over the secondary |
| **Your network to Azure** | Set a higher BGP local preference on routes learned from the primary |

Don't configure your routers to ignore longer AS paths. Microsoft uses AS path prepending to move traffic during maintenance, and [ignoring it can cause an outage](https://learn.microsoft.com/en-us/azure/expressroute/expressroute-faqs). Where you can, terminate BGP on stateless devices, and test failover if you can't.

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
