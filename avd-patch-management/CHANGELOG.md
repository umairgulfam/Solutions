# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-09-04

### Added
- `Invoke-PatchDownload.ps1` — stages the monthly cumulative update from the
  Microsoft Update Catalog into Azure Blob Storage and publishes a manifest.
- `Install-AvdPatch.ps1` — runs independently on every session host, verifies
  the package hash, installs via DISM and reports the outcome.
- `Invoke-AvdPatchOrchestrator.ps1` — optional batched rollout with AVD drain
  mode, user notification and health gating between batches.
- `AvdPatch` module targeting Windows PowerShell 5.1, using the blob REST API
  and managed identity so session hosts need no Az modules installed.
- Bicep deployment: storage, lifecycle policy, Automation Account, RBAC, and a
  native second-Tuesday-of-the-month schedule.
- `Register-PatchScheduledTask.ps1` — session host enrolment with a
  ScheduleByMonthDayOfWeek trigger and a restrictive ACL on the install path.
- Pester suite plus `Invoke-OfflineChecks.ps1`, a dependency-free harness for
  environments that cannot reach the PowerShell Gallery.

### Security
- SHA256 recorded at download and verified before any package reaches DISM.
- Session hosts are granted Storage Blob Data Reader only, so a compromised
  host cannot alter the packages other hosts install.
- Shared key access disabled on the storage account.
- `/NoRestart` is always passed to DISM; reboot timing is never the installer's
  decision.

[Unreleased]: https://github.com/your-org/avd-patch-management/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/your-org/avd-patch-management/releases/tag/v1.0.0
