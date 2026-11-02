# Flex Image Builder

A reference implementation for deploying [Citrix Platform Flex](https://docs.citrix.com/en-us/citrix-daas-flex) catalogs via Terraform — with optional custom image pipelines using [Citrix Packer Tools](https://github.com/citrix/citrix-packer-tools).

Covers SingleSession and MultiSession personas, domain join, VNet peering, and the path from Citrix-provided base images to fully custom golden images with applications pre-installed.

## Repository Structure

```
flex-image-builder/
├── docs/               # Full documentation site (GitHub Pages)
├── infra/
│   ├── modules/        # Reusable Terraform modules for each catalog type
│   └── examples/       # Ready-to-use examples for common scenarios
└── scripts/
    ├── powershell/     # Setup and deployment helpers for Windows
    └── bash/           # Setup and deployment helpers for macOS/Linux
```

## Getting Started

See the [documentation site](https://jefferymitchell.github.io/flex-image-builder) for full prerequisites, configuration, and deployment guides.

Quick path:

1. Review [Prerequisites](https://jefferymitchell.github.io/flex-image-builder/prerequisites)
2. Follow [Getting Started](https://jefferymitchell.github.io/flex-image-builder/getting-started)
3. Pick an [example](infra/examples/) that matches your scenario

**macOS / Linux:** run the PowerShell scripts under [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) (`pwsh`). The bash scripts in `packer/scripts/bash/` are deprecated and do not include the Trusted Launch, gallery or managed-identity changes.

## Requirements

- Citrix Cloud account with Platform Flex entitlement
- Citrix Cloud API key (client ID + secret)
- Terraform >= 1.5
- Citrix Terraform provider >= 1.0.36

## Disclaimer

This project is not affiliated with or endorsed by Citrix. It is a community reference implementation. Test in a non-production environment before deploying to production.
