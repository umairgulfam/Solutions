# AVD Patch Management

Custom Patch Tuesday automation for **Azure Virtual Desktop session hosts**, built because Azure Update Manager cannot patch them.

Two scripts, one contract between them:

```
   Patch Tuesday                          Patch Wednesday
        │                                       │
        ▼                                       ▼
┌───────────────────┐                 ┌──────────────────────┐
│ Invoke-Patch      │   manifest +    │ Install-AvdPatch.ps1 │
│ Download.ps1      │──── .msu ──────▶│  (every session host │
│                   │   Azure Blob    │   in parallel)       │
│ 1 trusted runner  │    Storage      │  N hosts, no ordering│
└───────────────────┘                 └──────────────────────┘
   pulls from                              installs via DISM,
   Microsoft Update Catalog                verifies SHA256 first
```

[![CI](https://github.com/your-org/avd-patch-management/actions/workflows/ci.yml/badge.svg)](https://github.com/your-org/avd-patch-management/actions/workflows/ci.yml)
[![PowerShell 5.1+](https://img.shields.io/badge/powershell-5.1%2B-blue.svg)](https://learn.microsoft.com/powershell/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

---

## Why this exists

Azure Update Manager does not support Windows client operating systems. Microsoft's own documentation lists *Windows client* under [unsupported workloads](https://learn.microsoft.com/en-us/azure/update-manager/unsupported-workloads) and points to Intune instead. Windows 10 and 11 Enterprise **multi-session** are client SKUs, so AVD session hosts fall outside it.

That leaves teams with three options, and a gap between them:

| Option | Why it may not fit |
| --- | --- |
| Microsoft Intune | The supported path. Needs Intune enrolment and licensing, and update timing is policy-driven rather than exact. |
| Configuration Manager | [Supported for multi-session](https://learn.microsoft.com/en-us/azure/virtual-desktop/configure-automatic-updates), but only if you already run ConfigMgr. |
| Windows Update for Business | Phased rollout. Microsoft decides which machines get an update and when, so hosts patch on different days. |

The last row is the actual problem this solves. Microsoft rolls updates out gradually, so a fleet on Windows Update lands on a patch over days or weeks. If your requirement is *"every session host installs this month's security update on a night we choose"*, that is not something Windows Update will do.

This project inverts the model: pull the update straight from the [Microsoft Update Catalog](https://www.catalog.update.microsoft.com/) the moment it publishes, stage it once, and install it on every host on a schedule you control.

**Read [the limitations](#limitations-read-before-deploying) before deploying.** This deliberately bypasses Windows Update's safety rails, and that has consequences worth understanding.

---

## How it works

### Script 1 — `Invoke-PatchDownload.ps1`

Runs **once per cycle** from one trusted place (an Azure Automation runbook on a second-Tuesday schedule).

1. Works out the current patch cycle (`2026-09`) from the date
2. Searches the catalog for each configured target
3. Selects the single correct result — right product, right architecture, right classification, *not* a Dynamic Update or .NET rollup
4. Downloads the `.msu` and records its **SHA256**
5. Uploads it to blob storage
6. Publishes `manifests/latest.json`

The manifest is written **last**, and the cycle-specific copy before the `latest` pointer. If any download fails, the previous manifest stays in place and session hosts keep behaving predictably rather than reading a half-written file.

### Script 2 — `Install-AvdPatch.ps1`

Runs on **every session host simultaneously**, as SYSTEM, from a scheduled task. Hosts are fully independent: no coordination, no shared lock, no ordering. A thousand hosts can run it at once.

1. Sleeps a random 0–300s (jitter — see below)
2. Identifies the OS precisely: build, UBR, release, architecture
3. Reads the manifest from blob storage via **managed identity**
4. Picks the entry matching this host
5. Decides applicability — already-patched hosts exit immediately
6. Downloads the `.msu` and **verifies SHA256 before use**
7. Installs with DISM, `/NoRestart`
8. Writes a result report back to storage
9. Optionally reboots, warning signed-in users first

The jitter is not cosmetic. A thousand hosts hitting one storage account at exactly 02:00:00 is a self-inflicted throttling incident; spreading them over five minutes costs nothing.

---

## Quick start

### 1. Deploy the infrastructure

```bash
az deployment group create \
  --resource-group rg-avd-patching \
  --template-file deploy/main.bicep \
  --parameters namePrefix=avdpatch
```

This creates the storage account, the container, an Automation Account with a managed identity, the RBAC assignments, and — the reason it is Bicep rather than a portal click — a schedule that fires on the **second Tuesday of every month**:

```bicep
advancedSchedule: {
  monthlyOccurrences: [ { occurrence: 2, day: 'Tuesday' } ]
}
```

Patch Tuesday expressed declaratively, with no date arithmetic to drift.

### 2. Configure your targets

Edit [`config/patch-config.json`](config/patch-config.json). The field that matters most is `targetUbr`:

```json
{
  "name": "win11-23h2-multisession",
  "searchQueryTemplate": "{cycle} Cumulative Update for Windows 11 Version 23H2 x64",
  "buildNumber": 22631,
  "displayVersion": "23H2",
  "targetUbr": 4890
}
```

`targetUbr` is the build revision a host reports **after** the update installs — the `4890` in `22631.4890`. Every KB article states it. With it, a host decides in milliseconds whether it needs patching, with no download and no DISM call. Without it the installer falls back to a slower KB-presence check.

Update it each month as part of approving the cycle. [`docs/runbook.md`](docs/runbook.md) explains where to find it.

### 3. Grant session hosts read access

```bash
az role assignment create \
  --assignee <session-host-managed-identity-principal-id> \
  --role "Storage Blob Data Reader" \
  --scope <storage-account-resource-id>
```

**Read-only, deliberately.** A session host is a shared, user-facing machine. If one is compromised, read-only access means the attacker cannot replace next month's `.msu` and have the entire fleet install it as SYSTEM.

### 4. Enrol the session hosts

```powershell
.\deploy\Register-PatchScheduledTask.ps1 `
    -StorageAccount stavdpatchprod01 `
    -Container patches `
    -Reboot
```

Bake this into your golden image so new hosts arrive enrolled, or push it via Run Command.

The task runs on the **second Wednesday**, not Tuesday. Microsoft publishes Tuesday, script 1 stages overnight, hosts install the following night. Installing Tuesday evening races the catalog publish.

### 5. Test before you trust it

```powershell
# Stage without uploading — verifies catalog parsing only
.\scripts\Invoke-PatchDownload.ps1 -SkipUpload -Verbose

# Dry run on one host
.\scripts\Install-AvdPatch.ps1 -StorageAccount stavdpatchprod01 `
    -Container patches -MaxJitterSeconds 0 -WhatIf -Verbose

# Logic checks, no Pester needed
.\tests\Invoke-OfflineChecks.ps1
```

---

## Two ways to run script 2

**A. Scheduled task on every host** (default, `deploy/Register-PatchScheduledTask.ps1`)

Every host patches itself at the same time. Simple, nothing to maintain, no Azure permissions at run time, scales without limit. Best when the pool is genuinely idle overnight.

**B. Orchestrated in batches** (`scripts/Invoke-AvdPatchOrchestrator.ps1`)

Walks the pool 25% at a time: drain → warn users → log off → patch → reboot → wait for healthy → re-enable. The pool stays partly available throughout. Uses `Invoke-AzVMRunCommand`, so no inbound connectivity or WinRM.

Use B when the pool serves users across time zones and can never be fully down. It stops if a batch fails to come back healthy, rather than draining the next one on top of an existing outage.

```powershell
.\scripts\Invoke-AvdPatchOrchestrator.ps1 -DryRun
```

---

## Security model

| Control | Why |
| --- | --- |
| **SHA256 verified before install** | The installer runs as SYSTEM and hands the file to DISM. An unverified package is remote code execution on every session host. The hash is recorded at download and checked before a byte reaches DISM. |
| **Session hosts get read-only** | A compromised host cannot poison the patch every other host installs. |
| **Managed identity, no SAS** | A SAS token in a config file is a credential on every session host, and rotating it means touching every machine. |
| **Shared keys disabled** on the storage account | Removes the credential most likely to leak. |
| **Restrictive ACL** on the install directory | SYSTEM/Administrators full, Users read-only. Anything a standard user can write there is code they get executed as SYSTEM — on a multi-session host, that is every signed-in user. |
| **`/NoRestart` always** | Reboot timing is an orchestration decision. An unexpected restart on a multi-session host disconnects every user on it. |

---

## Limitations — read before deploying

**The catalog has no public API.** Scripts 1's parsing is built on the same HTML endpoints the website uses. Microsoft can change that markup without notice and the parser will break. Two mitigations exist — the parser anchors on stable `id` attributes rather than layout, and the fixture-based tests will fail loudly — but this remains the most fragile part of the solution. Run script 1 well before you need it, and alert on its failure.

**You are bypassing Windows Update's safety rails.** Phased rollout exists because Microsoft uses telemetry from early recipients to pull bad updates before they reach everyone. Installing on day one means volunteering to be in that early group across your whole fleet at once. Mitigate it: run a canary pool first, and keep `patchRetentionDays` long enough to hold at least two cycles.

**`targetUbr` is manual.** It comes from the KB article each month. If you forget to update it, hosts fall back to a slower check that still works, but the fast path is lost. Automating this would mean parsing KB article prose, which is more fragile than the thirty-second manual step it replaces.

**Console-created and out-of-band updates are out of scope.** This handles the monthly cumulative update. An emergency out-of-band patch needs a manual run with `-Cycle` set explicitly.

**No rollback.** Uninstalling a cumulative update is `DISM /Remove-Package` and is not always clean. The real rollback for a bad month is your VM image and pool recreation. Have that path tested before you need it.

**Verified against fixtures, not a live catalog.** The parsing logic is tested against a saved catalog response. Before your first production cycle, run script 1 with `-SkipUpload -Verbose` against the live catalog and confirm it selects the KB you expect.

---

## Project layout

```
src/AvdPatch/            PowerShell module (5.1 compatible)
  Public/Catalog.ps1       catalog search, parsing, selection, download
  Public/Storage.ps1       blob REST + managed identity, no Az dependency
  Public/Patching.ps1      OS identity, applicability, DISM, exit codes
  Private/Logging.ps1      file + event log
scripts/
  Invoke-PatchDownload.ps1        script 1
  Install-AvdPatch.ps1            script 2
  Invoke-AvdPatchOrchestrator.ps1 optional batched orchestration
deploy/
  main.bicep                      storage, automation, RBAC, schedule
  Register-PatchScheduledTask.ps1 session host enrolment
config/patch-config.json
tests/                   Pester suite + dependency-free harness
docs/                    architecture, runbook, security
```

The module targets **Windows PowerShell 5.1** and uses the blob REST API rather than `Az.Storage`. Requiring Az modules on every session host would mean installing and version-managing a large module fleet-wide in an image rebuilt monthly. Everything in script 2 works with what ships in the box.

---

## Operations

Where to look when something goes wrong:

```powershell
# On a session host
Get-Content C:\ProgramData\AvdPatch\logs\*.log -Tail 50
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='AvdPatchManagement'} -MaxEvents 20

# Fleet compliance for a night
az storage blob download-batch --source patches --pattern "reports/2026-09-09/*" -d ./reports
```

[`docs/runbook.md`](docs/runbook.md) covers the failure modes in order of how often they actually happen.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The most valuable contribution is keeping the catalog parser working — if Microsoft changes the markup, an updated fixture plus parser fix helps everyone.

## License

MIT — see [LICENSE](LICENSE).
