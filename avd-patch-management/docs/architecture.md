# Architecture

## The shape of the problem

Patching an AVD pool has three constraints that ordinary server patching does not:

1. **Session hosts are shared.** A reboot disconnects everyone signed in, not one user.
2. **They are client SKUs.** Azure Update Manager will not touch them.
3. **Windows Update rolls out in phases.** Microsoft chooses which machines get an update and when, so a fleet lands on a patch over days.

The design follows from those. Constraint 2 rules out the obvious tool. Constraint 3 rules out leaving it to Windows Update if the requirement is a fixed night. Constraint 1 dictates everything about reboot handling.

## Two scripts, one contract

```
┌──────────────────────────────┐
│  Invoke-PatchDownload.ps1    │   runs ONCE, in ONE trusted place
│                              │
│  catalog search → select →   │
│  download → SHA256 → upload  │
└──────────────┬───────────────┘
               │ writes
               ▼
      ┌──────────────────┐
      │ manifests/       │  ◀── the contract
      │   latest.json    │
      └──────────────────┘
               │ read by
   ┌───────────┼───────────┬───────────┐
   ▼           ▼           ▼           ▼
 host-1     host-2      host-3  ...  host-N       all at once,
 (SYSTEM)   (SYSTEM)    (SYSTEM)     (SYSTEM)     no coordination
```

The manifest is the only coupling. Script 2 never talks to the Microsoft Update Catalog, never resolves a KB, never decides *what* to install — only whether the entry it was handed applies to itself.

That split is what makes the parallelism trivial. Hosts share no state, take no locks and have no ordering requirement, so N hosts scale as well as one. It also means the fragile part of the system — HTML scraping — runs once a month in a controlled place, not on five hundred machines.

## Key decisions

### Why a manifest rather than hosts searching the catalog

If every host resolved its own KB, you would get five hundred concurrent scrapes of a site with no API, five hundred chances to parse differently, and no single record of what the fleet was told to install. Staging once gives one point of failure to monitor and one artifact to audit.

### Why the manifest is written last

Uploads happen first, then `manifests/manifest-<cycle>.json`, then `manifests/latest.json`. A host that reads `latest.json` is guaranteed the blobs it references already exist. If a download fails midway, the previous cycle's manifest is still in place and hosts do something predictable rather than reading a half-written file.

### Why `targetUbr` drives applicability

UBR only increases within a build, so `currentUbr >= targetUbr` is a complete answer to "am I already patched?" — computed from a registry read, with no download and no DISM call. On a large pool that is the difference between a fast no-op and five hundred hosts each pulling 700 MB to discover they did not need it.

The fallback (checking whether the KB is installed) works but is slower and needs the package on disk first.

### Why the blob REST API instead of Az.Storage

Script 2 runs on every session host in an image rebuilt monthly. Requiring `Az.Storage` there means installing and version-managing a large module fleet-wide, and module version drift across a pool is its own class of incident. The REST API works with what ships in Windows PowerShell 5.1.

The downloader has no such constraint, but shares the module for consistency.

### Why managed identity rather than SAS

A SAS token in a config file is a credential sitting on every session host. Rotating it means touching every machine, so in practice it gets a long expiry — which is the actual risk. Managed identity has no secret to leak and no rotation to forget. SAS remains supported for non-Azure machines.

### Why session hosts are read-only

A session host is a shared, user-facing machine and the most likely thing in this system to be compromised. Read-only means an attacker on one host cannot replace next month's `.msu` and have every other host install it as SYSTEM.

The cost is that hosts cannot write compliance reports with that role alone. Grant `Storage Blob Data Contributor` scoped to `reports/` if you want host-written reports, or collect via Log Analytics.

### Why `/NoRestart`, always

An unexpected restart on a multi-session host disconnects every signed-in user. Reboot timing is an orchestration decision — the installer's job is to install and report whether a reboot is needed.

### Why jitter

A thousand hosts hitting one storage account at 02:00:00 is a self-inflicted throttling incident. Spreading over five minutes costs nothing.

### Why Wednesday

Microsoft publishes through Tuesday. Script 1 stages Tuesday evening; hosts install Wednesday night. Installing Tuesday evening races the publish, and a cycle where half the fleet reads a manifest that does not exist yet is worse than a day's delay.

## Two rollout models

**Scheduled task (default).** Every host patches itself simultaneously. Nothing to maintain, no Azure permissions at run time, unlimited scale. Best when the pool is idle overnight.

**Orchestrator.** Batches of 25%: drain → warn → log off → patch → reboot → wait healthy → re-enable. The pool stays partly available. It stops if a batch does not come back healthy, rather than draining the next one on top of an existing outage.

Most teams should start with the scheduled task and adopt the orchestrator only when the pool genuinely cannot be fully down.

## Failure behaviour

| Failure | Result |
| --- | --- |
| Catalog unreachable | Script 1 retries with backoff, then fails. Previous manifest untouched; hosts no-op. |
| One target fails, others succeed | Manifest publishes with the successes; exit code 2 flags it. Hosts for the failed target report `NoUpdateAvailable`. |
| Manifest missing | Hosts report `NoUpdateAvailable` and exit 0. **This is the emergency stop** — delete `latest.json` to halt a cycle. |
| Hash mismatch | Install aborts, file deleted, host reports `Failed`. Never installs unverified. |
| DISM returns 3010 | Success. Reboot required. |
| Host already patched | Success, `AlreadyCurrent`. No download. |
| Reboot already pending | Skipped with exit 3, before installing. |

Note the bias: every ambiguous case fails toward *not installing*. A host that skips a patch is visible in the compliance report and fixable the next night. A host that installs something unverified is not recoverable.

## What is deliberately not here

- **Rollback.** Uninstalling a cumulative update is unreliable. The real rollback is image redeploy.
- **Update discovery.** Targets are declared, not detected. Explicit configuration means a new Windows release cannot silently change what gets installed.
- **Scheduling logic in code.** Patch Tuesday is expressed in the Azure Automation schedule and the task XML, both natively capable of "second Tuesday". `Get-PatchTuesday` exists for cycle *labelling*, not triggering.
- **Third-party patching.** Windows cumulative updates only.
