# Operations Runbook

## Scale out

Increase `session_hosts` for a pool or add another map entry. Open a pull
request, review quota and cost impact, apply, run `validate-avd.ps1`, then place
new hosts into service.

## Scale in

Set the target host to drain mode, wait for users to sign out, confirm no active
sessions, and preserve any required logs before lowering `session_hosts`. Index
based resources remove the highest numbered VM first.

## Health validation

```powershell
./scripts/health-check.ps1 -ResourceGroupName rg-demo-prod-avd -HostPoolName vdpool-demo-prod-prod-us
./scripts/validate-avd.ps1 -ResourceGroupName rg-demo-prod-avd
```

## Cost governance

- Use AVD scaling plans for pooled desktops.
- Use shutdown schedules mainly for non-production or personal test hosts.
- Review actual concurrency before changing profile sizes.
- Set owner and cost-center tags and configure an Azure budget.

## Recovery

Terraform reconstructs infrastructure, not user profiles. Protect FSLogix data
with the storage service's backup and recovery features. Maintain tested image,
profile, identity, DNS, and application recovery procedures.

