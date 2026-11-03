# collect_must_gather

Automates comprehensive diagnostic data collection for Single Node OpenShift (SNO)
in disconnected bare-metal and AWS test environments.

Addresses the gap documented in `docs/bare-metal-architecture.md`:
> *"Must-gather / support escalation: not yet automated as a role…
> currently a manual runbook step."*

## Collectors

Each collector is independently controlled by a boolean variable — set any to
`false` to skip it. All default to `true`.

| Collector | Toggle variable | What it collects |
|---|---|---|
| **General OCP must-gather** | `must_gather_collect_general` | Standard `oc adm must-gather` (ClusterOperators, nodes, pod logs, events) |
| **ODF must-gather** | `must_gather_collect_odf` | ODF/MCG diagnostics; auto-discovers the mirrored image from the running ODF CSV/pod (see below) |
| **Bastion host logs** | `must_gather_collect_bastion` | OS metrics, dnsmasq/httpd journal, podman container logs for the local mirror-registry Quay |
| **Dell iDRAC BMC logs** | `must_gather_collect_bmc` | System Event Log (SEL) and Lifecycle Controller Log (LCLog) via Redfish; skipped automatically when `infra_provider != 'baremetal'` or BMC vars are unset |

## ODF must-gather: disconnected-safe image discovery

In a disconnected cluster `oc adm must-gather --image=registry.redhat.io/...`
fails — the node has no internet route. This role discovers the ODF must-gather
image from within the cluster, in priority order:

1. `odf_must_gather_image` role var (explicit override, skips all discovery)
2. `spec.relatedImages` in the ODF `ClusterServiceVersion` (CSV) — the operator
   bundle embeds the must-gather image digest here
3. `MUST_GATHER_IMAGE` environment variable on the `odf-operator-controller-manager` Deployment
4. Container image of the running ODF operator pod (last resort fallback)

If none resolves, ODF must-gather is skipped with a clear warning (not a failure).

## Output

All collectors write into sub-directories of `must_gather_session_dir`:

```
/tmp/<cluster_name>/diagnostics/session-<YYYYMMDD-HHMMSS>/
  ocp-general/        ← standard oc adm must-gather output
  odf-must-gather/    ← ODF-specific must-gather output
  bastion/            ← OS metrics, journal, podman logs
  bmc/                ← idrac-sel.json, idrac-lclog.json, idrac-system-health.json
```

Then compressed into:
```
/tmp/<cluster_name>/diagnostics/must-gather-<cluster>-<timestamp>.tar.gz
/tmp/<cluster_name>/diagnostics/must-gather-<cluster>-<timestamp>.tar.gz.sha256
```

## Relay to mirror-staging host

When `must_gather_relay_enabled: true` AND `backup_egress_mode` is `network` or
`both`, the archive and checksum file are rsynced to the mirror-staging host at
`must_gather_staging_dest_dir` (default `/opt/diagnostics-relay`) — the only
host with a real internet route on either provider. From there it can be manually
uploaded to a Red Hat support ticket.

This uses the same egress gate as `playbooks/export-backup.yaml` for consistency.

## Variables

| Variable | Default | Description |
|---|---|---|
| `must_gather_base_dir` | `/tmp/{{ cluster_name }}/diagnostics` | Root directory for all diagnostic output |
| `must_gather_timeout` | `1800` | Per-must-gather run timeout in seconds (30 min) |
| `bin_dir` | `~/.local/bin` | Directory containing the `oc` binary |
| `must_gather_collect_general` | `true` | Run general `oc adm must-gather` |
| `must_gather_collect_odf` | `true` | Run ODF-specific must-gather |
| `must_gather_collect_bastion` | `true` | Collect bastion OS and mirror-registry logs |
| `must_gather_collect_bmc` | `true` | Collect Dell iDRAC SEL/LCLog via Redfish |
| `odf_must_gather_image` | `""` | Optional explicit ODF must-gather image (bypasses auto-discovery) |
| `bmc_manager_resource_id` | `iDRAC.Embedded.1` | Redfish Manager resource ID |
| `bmc_system_resource_id` | `System.Embedded.1` | Redfish System resource ID |
| `must_gather_relay_enabled` | `true` | Enable relay to mirror-staging host |
| `must_gather_staging_dest_dir` | `/opt/diagnostics-relay` | Destination on the mirror-staging host |
