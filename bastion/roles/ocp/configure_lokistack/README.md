# configure_lokistack

Installs the Loki Operator and a `LokiStack` custom resource for centralized
application/infrastructure/audit log storage and querying, backed by a NooBaa object
bucket for chunk storage. Sized for a single small SNO node
(`1x.demo`, the smallest documented LokiStack tier) rather than production log
volumes — see [`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md).

## Hard dependency

Requires `roles/ocp/configure_mcg` to have already provisioned the standalone NooBaa
instance (namespace `openshift-storage`, StorageClass `openshift-storage.noobaa.io`)
that this role's `ObjectBucketClaim` targets — this role provisions its own bucket via
OBC (same pattern as `configure_onprem_quay`'s registry storage) rather than consuming
the `mcg_s3_*` facts directly.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `loki_channel` | `stable-6.x` | **Verify** against the mirrored catalog — Loki Operator channels are dated/rolling and this is a placeholder. |
| `lokistack_size` | `1x.demo` | Smallest documented LokiStack size tier; bump per-environment once real log volume is known. |
| `loki_retention_days` | `30` | Maps to `spec.limits.global.retention.days` — **verify field path** against a live `LokiStack` CRD. |
| `loki_hot_retention_days` | `7` | See "Retention model" below — this is an approximation, not a second storage tier. |
| `loki_bucket_name` | `{{ cluster_name }}-loki` | Name of the `ObjectBucketClaim` and generated bucket. |
| `loki_namespace` | `openshift-logging` | Shared with `configure_log_forwarding` so both roles' resources (and the Services `configure_grafana` references) live in one namespace. |
| `loki_storage_class` | `{{ lvms_vg_name \| default('vg1') }}` | Block storage for LokiStack's own WAL/index PVCs — distinct from the NooBaa-backed object bucket. |
| `loki_lokistack_name` | `{{ cluster_name }}-loki` | **Must stay in sync** with `configure_grafana`'s Loki datasource and `configure_log_forwarding`'s `lokiStack` output — all three assume the same LokiStack-generated Service names. |

## Retention model: how the 7-day/30-day requirement is approximated

LokiStack's CRD does not expose a distinct "hot tier" vs "total retention" concept.
The only supported knobs are:
- `spec.limits.global.retention.days`: a single global total-retention figure.
- `spec.limits.global.retention.streams[]`: optional per-stream (label-selector)
  overrides, each with their own day count.

This role sets the global figure to `loki_retention_days` (30) and adds one stream
override for `{log_type="application"}` set to `loki_hot_retention_days` (7), as the
closest available approximation of "hot" vs "total" — it is **not** a storage-tiering
mechanism (there's no separate hot/cold backend here, just a shorter deletion window
for one log stream). If the real requirement is genuinely a two-tier storage
architecture, that would need a different backend design entirely; confirm which
interpretation the customer actually needs.

## Known gaps / needs live-cluster verification

- `loki_channel` placeholder — confirm exact channel string.
- `spec.limits.global.retention.days` field path — confirm against
  `oc explain lokistack.spec.limits` once the CRD is installed.
- `spec.storage.secret` field names (`access_key_id`, `access_key_secret`,
  `bucketnames`, `endpoint`, `region`) in `templates/loki-storage-secret.yaml.j2` —
  confirm against `oc explain lokistack.spec.storage.secret`.
- `spec.tenants.mode: openshift-logging` wires the gateway to OpenShift OAuth, which
  is what `configure_log_forwarding`'s `lokiStack` output type expects. However,
  `configure_grafana`'s Loki datasource in this scaffold points at the
  query-frontend Service directly (bypassing the gateway) for simplicity — verify
  that's actually reachable/authorized under this tenant mode on a live cluster, or
  switch the datasource to the gateway with a bearer token.
- LokiStack component (ingester/query-frontend/gateway) readiness isn't polled after
  creation — only the operator Deployment is waited on.
