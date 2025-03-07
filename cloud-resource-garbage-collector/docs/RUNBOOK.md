# Operations Runbook

## Daily operation

1. Run the read-only scan.
2. Export findings and validate the estimated cost against the billing portal.
3. Resolve `unassigned` ownership using tags, CMDB, or deployment history.
4. Ask the owner to approve, reject, or ignore each candidate.
5. Validate backups, dependencies, retention, and legal hold.
6. Use a change ticket and maintenance window for approved cleanup.
7. Confirm deletion and monthly savings; retain the audit log.

## Rollback

Deletion can be irreversible. Prefer stop/deallocate, quarantine, snapshot, or
tag-and-wait workflows before deletion. Record the recovery method in the change
ticket. The project never represents an approval as a backup.

## Failure handling

- Authentication failure: validate workload identity and role scope.
- Partial scan: retain successful findings and rerun only the failed provider.
- Cost uncertainty: mark the estimate advisory and verify with native billing.
- Failed deletion: the finding changes to `failed`; investigate before retrying.

