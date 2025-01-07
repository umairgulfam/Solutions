# Contributing

## Setup

```bash
git clone https://github.com/your-org/avd-patch-management.git
cd avd-patch-management

pwsh ./tests/Invoke-OfflineChecks.ps1     # no dependencies
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Invoke-Pester ./tests                      # full suite
```

Everything runs offline, on Linux or Windows. You never need an Azure
subscription or a session host to develop against this.

## The most valuable contribution

**Keeping the catalog parser working.** The Microsoft Update Catalog has no
public API, so `ConvertFrom-MsCatalogHtml` parses HTML. When Microsoft changes
that markup, this project breaks for everyone.

If you hit that:

1. Save the live response to `tests/fixtures/catalog-search-results.html`
2. Fix `ConvertFrom-MsCatalogHtml`
3. Make sure the existing assertions still pass — the fixture deliberately
   contains rows the selector must *reject* (arm64, Dynamic Update, .NET, an
   older month). If those start being selected, the fix has broken something.

## Standards

- **Windows PowerShell 5.1 compatible** for anything under `src/AvdPatch` and
  `Install-AvdPatch.ps1`. These run on session hosts with only what ships in the
  box. No `??`, no ternaries, no `ForEach-Object -Parallel`. The orchestrator is
  exempt and requires 7.0.
- **No Az module dependency in script 2.** Blob access goes through the REST
  API. Requiring Az on every session host means version-managing a large module
  fleet-wide in a monthly-rebuilt image.
- **Never weaken the integrity check.** SHA256 verification before DISM is not
  optional. The installer runs as SYSTEM.
- **Never grant session hosts write access** to the patch container.
- **Always pass `/NoRestart`.** Reboot timing belongs to the orchestration
  layer, never the installer.
- **Explain the surprising parts.** Comment why 3010 is a success, why jitter
  exists, why the manifest is written last — not what the code plainly does.

## Tests

Behaviour, not coverage. The assertions worth writing are the ones that would
catch a real outage: 3010 treated as failure would page someone every month;
selecting the arm64 build would ship a package no host can install; a broken UBR
comparison would leave hosts unpatched while reporting success. All three are
covered — keep them that way.

## Reporting bugs

Include the version, the command, and redacted log output. Storage account
names, subscription IDs, host names and tenant IDs all appear in this tool's
logs.

Reproduce against `tests/fixtures/` where you can — that output is safe to
share.

## Security

Do not open a public issue for a security problem. See [SECURITY.md](SECURITY.md).
