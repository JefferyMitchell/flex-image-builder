---
layout: default
title: Lab Environment
nav_order: 9
---

# Lab environment
{: .no_toc }

Set up a disposable environment to test the full image pipeline: build, export, import, catalog update and network access. This page lists what to install, what to have ready, and which scripts create the lab.

**Use a lab only.** Testing restarts catalog machines and opens ports on a network connection, and both affect everything using that catalog or connection. Don't share either with real users.

<details open markdown="block">
  <summary>Contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## Domain join is required

Lab catalogs must be domain-joined, so a complete lab needs Active Directory, a Citrix Cloud Connector and a network connection. How far you can test depends on what you have:

| You have | You can test |
|---|---|
| Azure and Citrix Cloud access | Setup, build and export. The Citrix import may also work, but this hasn't been confirmed without a connection |
| A network connection and Active Directory too | The test catalog, catalog updates, network rules, access controls and catalog deletes |

## Install the tools

Install these on the machine that runs the scripts. For a private-network build, that machine must be able to reach the build subnet.

| Tool | Needed for | Windows | macOS / Linux |
|---|---|---|---|
| **PowerShell 7** | All scripts. `06`, `07`, `08` and `09` won't work in Windows PowerShell 5.1 | `winget install Microsoft.PowerShell` | [Install guide](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) |
| **Azure CLI** | Sign-in, setup, uploads and exports | `winget install Microsoft.AzureCLI` | `brew install azure-cli` |
| **Packer** | Builds | `winget install Hashicorp.Packer` | `brew install hashicorp/tap/packer` |
| **Git** | `02-build.ps1` clones `citrix-packer-tools` | `winget install Git.Git` | `brew install git` |
| **AzCopy v10** | Exports | `winget install Microsoft.Azure.AZCopy.10` | `brew install azcopy` |
| **Terraform 1.5 or later** | Creating the test catalog | `winget install HashiCorp.Terraform` | `brew install terraform` |

`02-build.ps1` installs the Packer plugins it needs: `hashicorp/azure` v2.6.5, and `rgl/windows-update` v0.18.5 unless you pass `-SkipWindowsUpdate`. `terraform init` installs the Citrix provider.

To install them all, and skip any you already have, run `lab-00-install-tools.ps1`. It works in Windows PowerShell 5.1 too. Add `-WhatIf` to see what it would install:

```powershell
.\packer\scripts\lab\lab-00-install-tools.ps1 -WhatIf
.\packer\scripts\lab\lab-00-install-tools.ps1
```

## Have these ready

### Azure

- [ ] A **non-production subscription**, with permission to use it for testing.
- [ ] **Owner, or Contributor and User Access Administrator**, on that subscription to run setup, because it creates role assignments.
- [ ] A region that matches the one your catalogs will deploy to.
- [ ] Quota in that region for the build VM size.
- [ ] An **Entra account from the subscription's own tenant** that owns the subscription, to create the VNet peering. [Citrix doesn't support guest or live.com accounts](https://docs.citrix.com/en-us/citrix-daas-azure/network-connections.html) for this.
- [ ] To find out whether policy blocks public IP addresses. If it does, you need a [private-network build](custom-images.md#private-network-builds-no-public-ip): a build subnet, a machine that can reach it on TCP 5986, and permission to join the subnet.

### Citrix Cloud

- [ ] A tenant with **Platform Flex entitlement**.
- [ ] An **API client** from Identity and Access Management → API Access, allowed to manage images and catalogs.
- [ ] A **network connection** that no production catalog uses. If you don't have one, [create one](prerequisites.md#create-the-network-connection). A lab can use plain VNet peering, without [ExpressRoute](prerequisites.md#recommended-connectivity-dual-expressroute).
- [ ] Permission to **create and delete a test catalog**.
- [ ] Your **customer ID**, plus the **API host** if you're outside the US.

### Installers

Download the latest versions from [Citrix Downloads](https://www.citrix.com/downloads/), which needs a Citrix account with download rights:

- [ ] The **VDA installer** for your OS: `VDAServerSetup` for Windows Server, or `VDAWorkstationSetup` for Windows 11.
- [ ] **Citrix Optimizer**, as a zip.

**Using a VDA newer than the tooling supports:**

| Requirement | Why |
|---|---|
| Pass `-VdaVersion v2507` to `02-build.ps1` | It selects a folder of scripts in `citrix-packer-tools`, not your installer, and that repo currently stops at v2507. Your installer comes from `vda_blob_url` |
| Keep the version in the file name, such as `VDAServerSetup_<version>.exe` | It's how you can tell which VDA a build used |
| Record the VDA version in your test results | This combination isn't validated until a build proves it |
| Check `vda_signer` if the signature check fails | The build stops unless the installer's signer matches. The default is `Citrix Systems, Inc.` |
| Use the Optimizer template names that `01-upload-installers.ps1` prints | The names can change between Optimizer releases, and the build stops on a name that isn't in the zip |

### Active Directory

See [Prerequisites](prerequisites.md#active-directory-domain-joined-catalogs-only) and [Domain Join](domain-join.md) for details.

- [ ] A **domain** that catalog machines can reach through the network connection.
- [ ] A **Citrix Cloud Connector** registered on that domain.
- [ ] A **target OU** for the catalog's machines.
- [ ] A **dedicated service account** that can create and delete computer objects in that OU.

### Network access

| From | To | Why |
|---|---|---|
| The machine running the scripts | Azure management, `api.cloud.com` (or your regional host), storage accounts | Setup, uploads, exports and Citrix calls |
| The machine running the scripts | GitHub and the Packer plugin sources | `citrix-packer-tools` and plugins |
| The machine running the scripts | The build VM on TCP 5986 | WinRM over HTTPS. For a public-network build, it's limited to the address you set with `-AllowedInboundIp` |
| The build VM | Your storage account | Installers |
| The build VM | Windows Update, GitHub and your Chocolatey source | Updates, the pinned Chocolatey MSI and app packages |

When it's ready, check everything with `lab-01-check-prereqs.ps1`. It changes nothing, and its output leaves out IDs and secrets:

```powershell
.\packer\scripts\lab\lab-01-check-prereqs.ps1 -SubscriptionId <subscription-id> -Location <region> -Connection <connection name>
```

## Secrets

Never commit these or paste them into tickets or chat.

| Secret | Where it goes |
|---|---|
| Citrix API client secret | `$env:CITRIX_CLIENT_SECRET`, and `$env:TF_VAR_citrix_client_secret` for Terraform |
| Domain join password | `$env:TF_VAR_domain_service_account_password` |
| Export SAS URIs | Treat them as secrets. They grant read access for up to 7 days, so revoke them when testing ends |

Also keep your subscription IDs, tenant ID and customer ID out of anything you publish, including test results.

Build logs are saved in `build-records/`, which is git-ignored. To share results, run `lab-05-collect-results.ps1`. It removes secrets and identifiers, and flags any secret it finds so you can rotate it. It uses pattern matching and can miss things, so read its output before you share it.

## Scripts

### Already in this repo

| Order | Script | What it does | What it changes |
|---|---|---|---|
| 1 | `00-setup-azure.ps1` | Creates the resource group, storage, managed identity, gallery and roles | Azure resources and role assignments |
| 2 | `01-upload-installers.ps1` | Uploads the installers and prints their hashes | Blobs in storage |
| 3 | `02-build.ps1` | Builds an image and publishes a gallery version. Use `-AppsFile` to test the app stage | A temporary build VM and a gallery version |
| 4 | `04-export-from-gallery.ps1` | Exports the OS disk and guest state, then prints the SAS URIs | A temporary disk and blobs |
| 5 | `06-import-to-citrix.ps1` | Imports the image and checks its flags | A Citrix image |
| 6 | `07-update-catalog-image.ps1` | **Test script.** Moves a catalog to the new image. Run it with `-CheckOnly` first | **Restarts catalog machines**, according to `-VdaUpdateDelay` |
| 7 | `09-network-rule.ps1` | **Test script.** Lists, opens and closes a port on a connection | **Opens a port for every machine on the connection** |
| 8 | `08-delete-catalog.ps1` | Deletes a catalog and its machines. Use `-WhatIf` first | **Deletes the catalog** |

Scripts labelled **test script** aren't yet validated for production. Use them only on test catalogs and connections.

### Create the test catalog

This needs a network connection and Active Directory. Use [`infra/examples/multisession-domain-joined`](https://github.com/JefferyMitchell/flex-image-builder/tree/main/infra/examples/multisession-domain-joined) for a Windows Server image, which [only works in multi-session catalogs](custom-images.md#os-requirements-per-catalog-type). For Windows 11, use `singlesession-domain-joined`.

1. Build, export and import your image with `02`, `04` and `06`, and note its image ID.
2. Copy `terraform.tfvars.example` to `terraform.tfvars`. Set `template_image_id`, `onprem_network_connection_id` and the `domain_*` values, and keep `number_of_users` low to limit cost.
3. Set `$env:TF_VAR_citrix_client_secret` and `$env:TF_VAR_domain_service_account_password`, then run `terraform init` and `terraform apply`.

Updating the catalog needs a second image with the same generation and Trusted Launch flags, because `07-update-catalog-image.ps1` refuses a catalog's current image. To avoid a second build, run `06-import-to-citrix.ps1` again with a new `-Name`, using the same SAS URIs before they expire.

To test the portal-based export, use [citrix-flex-image-export](https://github.com/JefferyMitchell/citrix-flex-image-export). It needs a gallery image version, a destination storage account and a new resource group to deploy into.

### Lab scripts

These are in `packer/scripts/lab/`.

| Script | What it does | What it changes |
|---|---|---|
| `lab-00-install-tools.ps1` | Installs the tools above with `winget`, skipping any already present, and reports their versions. On macOS and Linux, it lists what's missing | The local machine |
| `lab-01-check-prereqs.ps1` | Checks tools, the subscription, your roles, vCPU quota, public IP policy, Citrix variables and API access, and the network connection | Nothing |
| `lab-05-collect-results.ps1` | Copies build records and logs to `lab-results/`, with secrets and identifiers removed | A local results folder |
| `lab-99-teardown.ps1` | Closes the ports you name, then deletes resource groups marked as part of the lab | **Deletes lab resources** |

## Using a shared subscription

If the subscription holds anything else, keep the lab in its own resource groups. `lab-99-teardown.ps1` deletes only groups tagged as part of the lab, so mark each one after you create it:

```powershell
.\packer\scripts\lab\lab-99-teardown.ps1 -SubscriptionId <subscription-id> -LabName image-lab -MarkResourceGroup rg-flex-packer-build
```

Mark only groups that belong entirely to the lab, because teardown deletes everything in them.

A vCPU quota covers everything in the region. The default build VM needs 2 vCPUs, and `lab-01-check-prereqs.ps1` shows what's free. If it's short, deallocate a VM that isn't in use, and start it again when the build finishes. Catalog machines on Citrix-managed capacity don't use your quota.

## Best practices for production

These come from this repo's design and from Citrix and Microsoft guidance. They haven't all been run in a lab, so test them before you rely on them.

### Network

- Start with [dual ExpressRoute](prerequisites.md#recommended-connectivity-dual-expressroute), and [create the network connection](prerequisites.md#create-the-network-connection) before any catalog that uses it.
- Keep management access on a jump host in its own subnet, with an NSG that limits inbound access to known addresses.
- Use an address range that doesn't overlap anything in Azure or on-premises.
- Keep production catalogs on their own connection, because a Security rule reaches every machine on it.

### Access to machines

- Avoid inbound access where you can, using build-time checks and named admin sessions.
- If you need a port, [put the access controls around it first](managing-images.md#put-these-controls-around-an-open-port): Windows Firewall, your own NSG, a dedicated admin group with time-limited membership, JEA, and audit logs.
- Open the port only for the task, and confirm afterwards that it's closed.

### Active Directory

- [Citrix recommends](https://docs.citrix.com/en-us/citrix-daas-azure/network-connections.html) running directory services in the peered VNet.
- Give each catalog type its own OU, so Group Policy can target it.
- Use a [dedicated join account](domain-join.md#service-account-requirements), limited to the target OU.
- Register a Citrix Cloud Connector on the domain.
- Make sure catalog machines can reach your DNS and NTP servers.

## Clean up

When you've finished testing, list what teardown would remove, then run it. It lists everything, and asks before each delete:

```powershell
.\packer\scripts\lab\lab-99-teardown.ps1 -SubscriptionId <subscription-id> -LabName image-lab -WhatIf
.\packer\scripts\lab\lab-99-teardown.ps1 -SubscriptionId <subscription-id> -LabName image-lab -Connection <connection name> -ClosePort 5985
```

Then check that these are gone. Teardown doesn't remove the Citrix items or role assignments outside the marked groups:

- [ ] Security rules on the network connection, listed with `09-network-rule.ps1 -Connection <name>`
- [ ] The test catalog and its machines
- [ ] Imported test images in Citrix
- [ ] Exported blobs and any SAS URIs you shared
- [ ] Build VMs left behind by `-KeepOnError`
- [ ] Temporary disks, the gallery version and the lab resource groups
- [ ] Role assignments and the export identity from [citrix-flex-image-export](https://github.com/JefferyMitchell/citrix-flex-image-export#cleaning-up)
- [ ] Citrix API clients created for the lab
