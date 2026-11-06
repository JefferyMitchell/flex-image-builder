---
layout: home
title: Home
nav_order: 1
permalink: /
---

# Flex Image Builder
{: .no_toc }

A reference implementation for deploying Citrix Platform Flex catalogs via Terraform, with a custom image pipeline using Citrix Packer Tools.

---

## What This Does

- Deploys **SingleSession** (Knowledge Worker) and **MultiSession** (Task Worker) Platform Flex catalogs via Terraform
- Supports **domain join** to an on-premises Active Directory via VNet peering
- Provides a **custom image pipeline** — build golden images with Packer, register them in Platform Flex, and deploy catalogs using your own images
- Ships working examples for the most common customer scenarios

## Who This Is For

| Role | What you'll find here |
|---|---|
| Platform / Cloud Engineer | Terraform modules and examples ready to adapt |
| Citrix Administrator | Domain join configuration, persona selection, pre-flight checklists |
| DevOps / Automation Engineer | Packer pipeline, scripts, CI/CD workflow for image builds |

## Scenarios Covered

| Scenario | Example |
|---|---|
| SingleSession, Citrix image, domain-joined | [singlesession-domain-joined](https://github.com/JefferyMitchell/flex-image-builder/tree/main/infra/examples/singlesession-domain-joined) |
| MultiSession, Citrix image, VNet peering only | [multisession-no-domain-join](https://github.com/JefferyMitchell/flex-image-builder/tree/main/infra/examples/multisession-no-domain-join) |
| MultiSession, Citrix image, domain-joined | [multisession-domain-joined](https://github.com/JefferyMitchell/flex-image-builder/tree/main/infra/examples/multisession-domain-joined) |
| SingleSession, custom Packer image | Coming soon |

## Quick Start

```
1. Prerequisites   →  docs/prerequisites
2. Getting Started →  docs/getting-started
3. Pick an example →  infra/examples/
4. Set env vars and run terraform apply
```

## Disclaimer

This project is not affiliated with or endorsed by Citrix. It is a community reference implementation. Test in a non-production environment before deploying to production.
