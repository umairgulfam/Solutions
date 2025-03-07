# Least-Privilege Permissions

The default project only needs inventory/list permissions. Start with provider
managed read-only roles in a sandbox account, then replace them with a custom
role limited to the APIs actually used.

## AWS

- `sts:GetCallerIdentity`
- `ec2:DescribeRegions`, `ec2:DescribeVolumes`, `ec2:DescribeAddresses`
- `ec2:DescribeSnapshots`

Use AWS SSO, an EC2/ECS role, or OIDC federation. The reference adapter does not
implement AWS deletion.

## Azure

Assign **Reader** at only the subscriptions to scan. The adapter queries Azure
Resource Graph using `DefaultAzureCredential`. The reference adapter does not
implement Azure deletion.

## GCP

Grant `roles/cloudasset.viewer` on only the projects or folder to scan. Use
Application Default Credentials or Workload Identity Federation. The reference
adapter does not implement GCP deletion.

## Deletion boundary

Only the mock provider demonstrates end-to-end deletion. Real-cloud adapters are
intentionally read-only reference collectors. Implement each cleanup operation
individually with provider-native dependency checks and a dedicated narrow role.

