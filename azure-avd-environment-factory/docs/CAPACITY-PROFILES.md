# Capacity Profiles

| Profile | Host pools | Hosts per pool | Default VM size |
| --- | ---: | ---: | --- |
| Small | 4 | 1 | D2s v5, with D4s v5 for production |
| Medium | 4 | 3 | D4s v5 |
| Large | 6 | 5 | D8s v5 |
| Custom | Any | Per-pool | Per-pool |

Profiles are deployment examples, not Microsoft sizing recommendations. Validate
with workload testing, user concurrency, application behavior, FSLogix latency,
and Azure limits.

`off_peak_minimum_hosts` is expressed as a host count in configuration. The
module converts it to the percentage required by Azure's scaling-plan API.

To switch to full control:

```hcl
capacity_profile = "custom"
host_pools = {
  developers = { session_hosts = 2, vm_size = "Standard_D4s_v5" }
  qa         = { session_hosts = 2, vm_size = "Standard_D4s_v5" }
}
```
