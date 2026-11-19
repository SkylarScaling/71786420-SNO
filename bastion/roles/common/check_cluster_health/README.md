# check_cluster_health

## tl;dr

Checks ClusterOperators/Nodes/MachineConfigPools/Pods right after provisioning,
prints a pass/fail summary, and prints the equivalent `oc` commands for the
customer to re-check manually at any time.

### To use this correctly:

- No vars to set. This role never fails the playbook on its own — it's a
  point-in-time report, not a gate. If `overall` comes back `ISSUES FOUND`,
  investigate using the printed manual commands (or `oc describe`/`oc logs`) before
  moving on, rather than re-running provisioning.

## Full Details:

Runs once, at the end of `provision-sno.yaml`, after `configure_mirror_catalog_sources`
(so every other provisioning step, including the catalog-source fixup every
day-2 Subscription depends on, has already had a chance to settle).

Checks, each via `kubernetes.core.k8s_info` against `sno_kubeconfig`:

- **ClusterOperators**: unhealthy if missing an `Available: True` condition, or
  carrying a `Degraded: True` condition.
- **Nodes**: unhealthy if missing a `Ready: True` condition.
- **MachineConfigPools**: unhealthy if `updatedMachineCount` hasn't caught up to
  `machineCount`, or `degradedMachineCount` is nonzero.
- **Pods**: any pod cluster-wide not in `Running`/`Succeeded` phase (fetched directly
  via a `field_selectors` filter, not post-processed).

Each check loops over its resources individually with `default(...)`-guarded
condition lookups, rather than one combined filter expression — a resource whose
`status` isn't fully populated yet just counts as unhealthy instead of raising a
template error (the same failure class fixed in `wait_for_sno_install` and
`baremetal_boot_node_via_bmc`).

Results print as one summary `debug` (each unhealthy list, plus an overall
`HEALTHY`/`ISSUES FOUND` verdict), followed by a second `debug` listing the
equivalent manual `oc` commands — intended for the customer to re-run later, not
just at provisioning time.
