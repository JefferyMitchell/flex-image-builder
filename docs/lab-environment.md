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

## Choose a lab profile

| Profile | Tests | Also needs |
|---|---|---|
| **Basic** | Setup, build, export, import, catalog update and the network rule script | Nothing beyond this page's requirements |
| **Domain-joined** | Everything above, plus Group Policy by OU and domain-joined catalog deletes | Active Directory and a Citrix Cloud Connector (see [Prerequisites](prerequisites.md#active-directory-domain-joined-catalogs-only)) |

Start with Basic unless you need to test Group Policy or domain join.

## Install the tools

Install these on the machine that runs the scripts. For a private-network build, that machine must be able to reach the build subnet.

| Tool | Needed for | Windows | macOS / Linux |
|---|---|---|---|
| **PowerShell 7** | All scripts. `06`, `07`, `08` and `09` won't work in Windows PowerShell 5.1 | `winget install Microsoft.PowerShell` | [Install guide](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) |
| **Azure CLI** | Sign-in, setup, uploads and exports | `winget install Microsoft.AzureCLI` | `brew install azure-cli` |
| **Packer** | Builds | `winget install Hashicorp.Packer` | `brew install hashicorp/tap/packer` |
| **Git** | `02-build.ps1` clones `citrix-packer-tools` | `winget install Git.Git` | `brew install git` |
| **AzCopy v10** | Exports | `winget install Microsoft.Azure.AzCopy.10` | `brew install azcopy` |
| **Terraform 1.5 or later** | Creating the test catalog | `winget install HashiCorp.Terraform` | `brew install terraform` |

`02-build.ps1` installs the Packer plugins it needs: `hashicorp/azure` v2.6.5, and `rgl/windows-update` v0.18.5 unless you pass `-SkipWindowsUpdate`. `terraform init` installs the Citrix provider.

Open a new terminal after installing, then check that each tool is found:

```powershell
pwsh --version; az version; packer version; git --version; azcopy --version; terraform version
```

## Have these ready

### Azure

- [ ] A **non-production subscription**, with permission to use it for testing.
- [ ] **Owner, or Contributor and User Access Administrator**, on that subscription to run setup, because it creates role assignments.
- [ ] A region that matches the one your catalogs will deploy to.
- [ ] Quota in that region for the build VM size.
- [ ] To find out whether policy blocks public IP addresses. If it does, you need a [private-network build](custom-images.md#private-network-builds-no-public-ip): a build subnet, a machine that can reach it on TCP 5986, and permission to join the subnet.

### Citrix Cloud

- [ ] A tenant with **Platform Flex entitlement**.
- [ ] An **API client** from Identity and Access Management → API Access, allowed to manage images and catalogs.
- [ ] A **network connection** that no production catalog uses.
- [ ] A **test catalog** you can restart and delete, or permission to create one.
- [ ] Your **customer ID**, plus the **API host** if you're outside the US.

### Installers

Download these from [Citrix Downloads](https://www.citrix.com/downloads/):

- [ ] The **VDA installer** for your OS. `02-build.ps1` accepts versions 2407, 2411, 2503 and 2507.
- [ ] **Citrix Optimizer**, as a zip.

### Network access

| From | To | Why |
|---|---|---|
| The machine running the scripts | Azure management, `api.cloud.com` (or your regional host), storage accounts | Setup, uploads, exports and Citrix calls |
| The machine running the scripts | GitHub and the Packer plugin sources | `citrix-packer-tools` and plugins |
| The machine running the scripts | The build VM on TCP 5986 | WinRM over HTTPS. For a public-network build, it's limited to the address you set with `-AllowedInboundIp` |
| The build VM | Your storage account | Installers |
| The build VM | Windows Update, GitHub and your Chocolatey source | Updates, the pinned Chocolatey MSI and app packages |

## Secrets

Never commit these or paste them into tickets or chat.

| Secret | Where it goes |
|---|---|
| Citrix API client secret | `$env:CITRIX_CLIENT_SECRET`, and `$env:TF_VAR_citrix_client_secret` for Terraform |
| Domain join password (domain-joined profile) | `$env:TF_VAR_domain_service_account_password` |
| Export SAS URIs | Treat them as secrets. They grant read access for up to 7 days, so revoke them when testing ends |

Also keep your subscription IDs, tenant ID and customer ID out of anything you publish, including test results.

Build logs are saved in `build-records/`, which is git-ignored. Check them before you share them.

## Scripts

### Already in this repo

| Order | Script | What it does | What it changes |
|---|---|---|---|
| 1 | `00-setup-azure.ps1` | Creates the resource group, storage, managed identity, gallery and roles | Azure resources and role assignments |
| 2 | `01-upload-installers.ps1` | Uploads the installers and prints their hashes | Blobs in storage |
| 3 | `02-build.ps1` | Builds an image and publishes a gallery version. Use `-AppsFile` to test the app stage | A temporary build VM and a gallery version |
| 4 | `04-export-from-gallery.ps1` | Exports the OS disk and guest state, then prints the SAS URIs | A temporary disk and blobs |
| 5 | `06-import-to-citrix.ps1` | Imports the image and checks its flags | A Citrix image |
| 6 | `07-update-catalog-image.ps1` | Moves a catalog to the new image. Run it with `-CheckOnly` first | **Restarts catalog machines**, according to `-VdaUpdateDelay` |
| 7 | `09-network-rule.ps1` | Lists, opens and closes a port on a connection | **Opens a port for every machine on the connection** |
| 8 | `08-delete-catalog.ps1` | Deletes a catalog and its machines. Use `-WhatIf` first | **Deletes the catalog** |

To create the test catalog, use an example in [`infra/examples/`](https://github.com/JefferyMitchell/flex-image-builder/tree/main/infra/examples): `multisession-no-domain-join` for the Basic profile.

To test the portal-based export, use [citrix-flex-image-export](https://github.com/JefferyMitchell/citrix-flex-image-export). It needs a gallery image version, a destination storage account and a new resource group to deploy into.

### Still to be written

These don't exist yet. They'd go in `packer/scripts/lab/`.

| Script | What it should do | What it would change | Profile |
|---|---|---|---|
| `lab-00-install-tools.ps1` | Install the tools above with `winget`, skipping any already present, and report their versions | The local machine | Both |
| `lab-01-check-prereqs.ps1` | Check tools, Azure sign-in and roles, public IP policy, Citrix environment variables and API access, then list what's missing | Nothing | Both |
| `lab-02-network.ps1` | Create the lab network, an NSG and a jump host, with inbound access limited to one address | Azure resources | Both |
| `lab-03-access-controls.ps1` | Apply the [network access controls](managing-images.md#put-these-controls-around-an-open-port) to test machines: the Windows Firewall rule, an admin group, JEA and logging | Test catalog machines | Both |
| `lab-04-domain.ps1` | Create a domain controller, OU, join account, Group Policy and Cloud Connector host | Azure and Active Directory | Domain-joined |
| `lab-05-collect-results.ps1` | Gather build records and script results, flag secrets in logs, and remove IDs and SAS tokens from the output | A local results file | Both |
| `lab-99-teardown.ps1` | List everything the lab created, ask for confirmation, then close ports and delete it. It must refuse anything it did not create | **Deletes lab resources** | Both |

Each should follow the same rules as the other scripts: read secrets only from environment variables, never print them, stop on the first error, and support `-WhatIf` wherever they change something.

## Clean up

When you've finished testing, check that these are gone:

- [ ] Security rules on the network connection, listed with `09-network-rule.ps1 -Connection <name>`
- [ ] The test catalog and its machines
- [ ] Imported test images in Citrix
- [ ] Exported blobs and any SAS URIs you shared
- [ ] Build VMs left behind by `-KeepOnError`
- [ ] Temporary disks, the gallery version and the lab resource groups
- [ ] Role assignments and the export identity from [citrix-flex-image-export](https://github.com/JefferyMitchell/citrix-flex-image-export#cleaning-up)
- [ ] Citrix API clients created for the lab
