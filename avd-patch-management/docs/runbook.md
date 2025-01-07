# Runbook

## The monthly cycle

| When | What | Who |
| --- | --- | --- |
| Patch Tuesday, morning | Read the KB article, note the new UBR | Engineer |
| Patch Tuesday, before 20:00 UTC | Update `targetUbr` in `patch-config.json`, commit | Engineer |
| Patch Tuesday, 20:00 UTC | Script 1 runs automatically | Automation |
| Patch Tuesday, evening | Confirm the manifest published | Engineer |
| Patch Wednesday, 02:00 | Script 2 runs on every host | Scheduled task |
| Patch Wednesday, morning | Review the compliance report | Engineer |

### Finding `targetUbr`

Open the KB article for the month, for example `KB5065432`. Every cumulative
update article states the resulting build near the top, phrased like *"this
update ... increments the build number to 22631.4890"*. The number after the dot
is `targetUbr`.

If you cannot find it, set it to `0`. The installer falls back to a KB-presence
check — slower and it downloads the package before deciding, but correct.

### Confirming the manifest published

```bash
az storage blob download \
  --account-name stavdpatchprod01 --container-name patches \
  --name manifests/latest.json --file - --auth-mode login | jq '.'
```

Check `cycle` matches this month, `failureCount` is 0, and each entry's `kbId`
is the KB you expected.

---

## Verifying a run

### One host

```powershell
Get-Content C:\ProgramData\AvdPatch\logs\*.log -Tail 50

# Did the build actually move?
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
    Select-Object CurrentBuildNumber, UBR, DisplayVersion
```

### The fleet

```bash
az storage blob download-batch \
  --source patches --pattern "reports/2026-09-09/*" \
  --destination ./reports --auth-mode login

jq -r '[.computerName, .status, .action, .kbId] | @tsv' ./reports/*.json | sort
```

Expected statuses:

| Status / action | Meaning |
| --- | --- |
| `Success` / `SuccessRebootRequired` | Normal. Installed, awaiting reboot. |
| `Success` / `AlreadyCurrent` | Host was already patched. Normal on rebuilt hosts. |
| `Success` / `NoUpdateAvailable` | No manifest entry matches this host. Expected for Server or arm64 hosts; **investigate if a managed host reports this**. |
| `Skipped` / `PendingReboot` | Reboot the host, then re-run. |
| `Failed` / anything | See below. |

A host that never wrote a report at all is the case worth chasing — it usually
means the scheduled task did not fire, not that patching failed.

---

## Failure modes, in the order they actually happen

### Script 1 finds no results

```
No catalog results for '2026-09 Cumulative Update for Windows 11 Version 23H2 x64'
```

Usually one of:

- **Ran too early.** The catalog publishes through Tuesday; a 20:00 UTC run is
  normally safe, but re-run manually if it fires early.
- **The product moved.** Hosts upgraded 23H2 → 24H2 but the config still says
  23H2. Update `searchQueryTemplate`, `buildNumber` and `displayVersion`.
- **The catalog markup changed.** Check with `-SkipUpload -Verbose`; if the
  search returns HTTP 200 but zero parsed rows, the parser needs updating.

### Script 1 selects the wrong update

Diagnose by listing what the catalog actually returned:

```powershell
Import-Module ./src/AvdPatch/AvdPatch.psd1
Find-MsCatalogUpdate -Query '2026-09 Cumulative Update Windows 11 23H2 x64' |
    Format-Table KbId, Title, Classification, LastUpdated
```

Then tighten `titleMustMatch` or `titleMustNotMatch` in the config. The default
excludes Dynamic Update, Preview, .NET Framework and out-of-band releases.

### Hosts report NoUpdateAvailable unexpectedly

The manifest has no entry matching that host. Compare them directly:

```powershell
Import-Module ./src/AvdPatch/AvdPatch.psd1
Get-SessionHostOsIdentity   # buildNumber, displayVersion, architecture
```

All three must match a manifest entry. The usual cause is a feature update that
moved hosts to a build the config does not cover.

### Integrity check failed

```
Integrity check failed for windows11.0-kb5065432-x64.msu. The package was NOT installed.
```

The tool did the right thing — it refused to hand an unverified file to DISM.
Almost always a truncated download from a dropped connection; the cached copy is
deleted automatically, so re-running fixes it. If it fails repeatedly on
multiple hosts, re-run script 1 with `-Force` to re-stage the package, and treat
persistent failure as a security event rather than a transient one.

### DISM returns an unmapped exit code

```powershell
Get-Content $env:WINDIR\Logs\DISM\dism.log -Tail 100
Get-Content $env:WINDIR\Logs\CBS\CBS.log -Tail 100
```

Common causes: corrupt component store (`DISM /Online /Cleanup-Image
/RestoreHealth`), insufficient disk space, or a pending servicing operation.

### Installer busy

```
Another installation is already in progress. Retry later.
```

Windows Update is running concurrently. Either disable the Windows Update
scheduled scan on session hosts, or let the task's retry policy handle it — it
retries three times at 30-minute intervals.

### Hosts left in drain mode

If the orchestrator dies mid-run, hosts can be left refusing new sessions. This
shows up as unexplained capacity loss the next morning:

```powershell
Get-AzWvdSessionHost -HostPoolName hp-avd-prod-01 -ResourceGroupName rg-avd-prod |
    Where-Object { -not $_.AllowNewSession } |
    ForEach-Object {
        Update-AzWvdSessionHost -HostPoolName hp-avd-prod-01 -ResourceGroupName rg-avd-prod `
            -Name ($_.Name -split '/')[-1] -AllowNewSession:$true
    }
```

---

## Manual operations

```powershell
# Re-stage a previous month
.\scripts\Invoke-PatchDownload.ps1 -Cycle 2026-08 -Force

# Patch one host immediately, ignoring applicability
.\scripts\Install-AvdPatch.ps1 -StorageAccount stavdpatchprod01 `
    -Container patches -MaxJitterSeconds 0 -Force -Reboot

# Fire the scheduled task now
Start-ScheduledTask -TaskName 'AVD Monthly Security Patching' -TaskPath '\Microsoft\AvdPatch\'

# Emergency: stop all patching this cycle
Disable-ScheduledTask -TaskName 'AVD Monthly Security Patching' -TaskPath '\Microsoft\AvdPatch\'
```

To halt a cycle fleet-wide before hosts run, delete `manifests/latest.json`.
Every host will report `NoUpdateAvailable` and do nothing, which is a safe
failure rather than a partial rollout.

---

## Rolling back a bad update

There is no clean automated rollback, and that is a real limitation.

1. **Stop the spread.** Delete `manifests/latest.json` so unpatched hosts stay
   unpatched.
2. **Remove it on affected hosts,** accepting this is not always clean:
   ```powershell
   $pkg = (Get-WindowsPackage -Online | Where-Object PackageName -match '5065432').PackageName
   Remove-WindowsPackage -Online -PackageName $pkg -NoRestart
   ```
3. **Prefer rebuilding.** For pooled hosts, redeploying from the previous image
   is faster and more reliable than uninstalling. Have that path tested before
   you need it.

---

## Pre-flight checklist for a new deployment

- [ ] Bicep deployed; automation identity has Storage Blob Data Contributor
- [ ] Session host identities have Storage Blob Data Reader — read-only
- [ ] `targetUbr` set for every enabled target
- [ ] Script 1 tested with `-SkipUpload -Verbose` against the live catalog
- [ ] Script 2 tested with `-WhatIf` on one host
- [ ] Canary pool patched a cycle ahead of production
- [ ] Alerting on script 1 failure — a silent failure means an unpatched month
- [ ] Rollback path (image redeploy) tested
- [ ] `Invoke-OfflineChecks.ps1` passes
