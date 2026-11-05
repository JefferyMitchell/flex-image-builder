---
layout: default
title: Managing Images
nav_order: 7
---

# Managing images day to day
{: .no_toc }

Building the first image is a one-off. This page is about everything after it: monthly patches, app changes, VDA and Optimizer upgrades, keeping builds repeatable, and rolling back. The commands are the ones in [Custom Images](custom-images.md); this page says when and why to run them.

<details open markdown="block">
  <summary>Contents</summary>
  {: .text-delta }
- TOC
{:toc}
</details>

---

## The rhythm

| When | What | Why |
|---|---|---|
| **Monthly**, after Patch Tuesday | Rebuild every image | Windows updates, Defender platform and the newest marketplace base |
| When a **VDA** you've validated ships | Upload it, rebuild, update catalogs | VDA fixes and features |
| When an **app** changes | Edit its list, rebuild | Apps are baked in; machines don't update them in place |
| **Quarterly** | Review the pinned inputs | Keep pins current on purpose rather than by accident |

Every rebuild is the same three steps:
1. Bump `gallery_image_version` in the vars file.
2. Run `02-build.ps1`.
3. Check the build record, then export and update the catalog.

A gallery version can't be overwritten, so every build is a new version, and the previous one stays available for rollback.

---

## The monthly patch rebuild

1. **Bump the version** in your vars file, for example `1.1.0` → `1.2.0`. Keep `image_version` at `latest`: the build resolves it to the newest marketplace version and records which one it used.
2. **Build** with the same command as last time. Windows Update runs first and loops until no updates are left (typically 5–15 minutes, in a few install-and-restart rounds).
3. **Check the build record** (`build-records/<image>-<version>.json`, and the copy in the `build-records` container):
   - `base_image.version`: newer than last month's?
   - `windows_update.installed`: the KBs you expected?
   - `build_vm.secure_boot`: `True`?
4. **Export, import and update the catalog:**
   - export with `04-export-from-gallery.ps1`;
   - import with `06-import-to-citrix.ps1`, which reads the flags back;
   - update the catalog with `07-update-catalog-image.ps1`. Run it with `-CheckOnly` first, then choose when machines restart with `-VdaUpdateDelay`.

   See [Lifecycle with the API](custom-images.md#lifecycle-with-the-api). The update script refuses an image whose generation, Secure Boot or vTPM settings differ from the catalog's, because the service would accept it and then silently revert. It also refuses static catalogs unless you pass `-Force`, because their machines are re-provisioned.
5. **Keep the previous version** until the catalog has run on the new one for a while. Then delete old versions from the gallery to stop paying for them.

---

## Apps

Apps come from a list file passed with `-AppsFile`: Chocolatey package IDs, one per line. Start from [`packer/apps/example.apps.txt`](../packer/apps/example.apps.txt).

**Change an app:** edit the list and rebuild. Machines don't pick up app changes on their own; the next image carries them.

**One list per image or persona.** A task-worker image and a knowledge-worker image usually need different apps. Keep one list per image, named for it, next to its vars file.

**Pin versions when it matters.** Without a version, each build installs the newest package. Write `id version` to hold an app at a version you've tested:

```
notepadplusplus
7zip 26.5.0          # pinned: validated with the line-of-business plug-in
adobereader
```

**See what's in an image:** the build record's `apps` lists every installed package with its version, and so does the build log (`installed-app:` lines). Expect a few you didn't list:
- `chocolatey` itself;
- dependencies, such as `*.install` packages and `chocolatey-*.extension`;
- on some images, `KB2919355`/`KB2919442`, empty legacy stubs that do nothing on current Windows.

**Find package IDs** with `choco search <name>` or at [community.chocolatey.org/packages](https://community.chocolatey.org/packages).

**Use your own feed for production.** `-ChocoSource <url>` installs from an internal feed (Azure Artifacts, Nexus, ProGet, …) and turns the community source off. Then:
- you approve each package version before any image gets it;
- builds don't depend on the public repository being up;
- you control the supply chain.

**Apps that aren't Chocolatey packages:** package them for your internal feed (Chocolatey can wrap an MSI or EXE), or install them after deployment with your usual tooling. Don't add ad hoc download-and-run steps to the template.

**A failing app stops the build.** The error names the package; see [Troubleshooting](troubleshooting.md#a-build-fails-in-the-app-stage).

---

## Windows Update

Every build installs all available updates **except**:
- **Preview** updates;
- **KB5007651**, the Defender "Windows Security platform" update. It's offered again after every install, so without the exclusion the update stage never finishes. Expect to see `Skipped (filter) … KB5007651` in every round of the log; that's the exclusion working.

**An update that loops or breaks the build:** add it with `-WindowsUpdateExclude KB…`. It takes a KB number or any text from the update's title. Keep a note of why, and remove the exclusion when the problem is fixed: an excluded update is a missing patch.

**`-SkipWindowsUpdate`** is for quick test builds only. Never use it for an image users will run.

**What went in:** the build record's `windows_update.installed` lists the KBs. A recent marketplace base may need only a handful (Defender platform and intelligence, the Malicious Software Removal Tool); an older one also gets the monthly cumulative update.

---

## VDA upgrades

1. Download the new VDA from Citrix (`VDAServerSetup_<version>.exe` or `VDAWorkstationSetup_<version>.exe`).
2. Run `01-upload-installers.ps1`. Versioned names sit side by side in the `installers` container, so the old version stays available for rollback.
3. Paste the new `vda_blob_url` and `vda_sha256` into the vars file and rebuild.

The build VM refuses an installer whose SHA-256 doesn't match, or whose signature isn't a valid one from Citrix (`vda_signer`). **Never loosen `vda_signer` to get a build through:** re-download the installer instead.

---

## Optimizer updates

A new Citrix Optimizer release can rename its templates (the suffix, such as `_2009`, changes). After uploading a new zip, pick `optimizer_template` from the list `01-upload-installers.ps1` prints. A name that isn't in the zip stops the build right after the download, before anything is installed.

---

## Pinned inputs

Builds are repeatable because their inputs are pinned:

| Input | Where it's pinned | Move it by |
|---|---|---|
| citrix-packer-tools (VDA, Optimizer, cleanup scripts) | `-PackerToolsRef` default in `02-build.ps1` | passing a newer commit or tag, after a test build |
| Packer plugins (azure, windows-update) | `02-build.ps1` | editing the versions, after a test build |
| Chocolatey | `02-build.ps1` | editing the version, after a test build |
| Marketplace image | resolved per build from `latest` | setting `image_version` to hold one |
| Apps | your app list | `id version` lines |

**Review them quarterly:** test-build with newer versions, compare the build records, then move the pins. Don't let them drift because something was "latest" on the day.

---

## Rollback and audit

- **Rollback:** point the catalog back at the previous gallery version's image (`07-update-catalog-image.ps1` with the earlier image ID). The version is still there, unchanged.
- **What's in a version:**
  - its **gallery tags** (`vda`, `vdaSha256`, `baseImage`, `packerTools`, `buildRecord`) answer the common questions straight from the portal or `az sig image-version show`;
  - the **build record** they point to has the rest.
- **Keep build records** for as long as any catalog might run that version. They're small.

---

## Reaching catalog machines from your network

Machines on Citrix-managed capacity accept **nothing inbound** from your network by default, not even from the network peered with them. To check an image from inside (Secure Boot, TPM, installed apps), run an agent, or troubleshoot, open a port on the network connection in Web Studio, and close it when you're done: **Quick Deploy → Microsoft Azure → Network connections → your connection → Security rules**.

Know the limits before you open anything:

- **A rule can't be limited to one address.** Its source is always the `VirtualNetwork` service tag: the Citrix-managed network and every network peered with it.
- **It applies to every machine on the connection**, in every catalog that uses it.
- **Allow only, ports 1–49151.** 20–21, 22, 23 and 3389 can't be opened.
- **About 3 minutes to take effect**, and about as long to go away.

With TCP 5985 open, a domain admin can check a machine from a domain controller or a management server in the peered network:

```powershell
Invoke-Command -ComputerName <machine> -ScriptBlock {
    Confirm-SecureBootUEFI; Get-Tpm | Select-Object TpmPresent, TpmReady
    Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\* | Where-Object DisplayName | Select-Object DisplayName, DisplayVersion
}
```

**Check that the machine is on first.** Autoscale powers catalog machines off outside peak hours, and a machine that's off looks exactly like a closed port.

## Several images

- Run each image from its own vars file (its own `gallery_image_name`, versions and installers) and its own app list.
- Images can share the gallery, storage account and identity.
- Rebuild them all in the same monthly window, so patch levels don't drift apart between personas.
