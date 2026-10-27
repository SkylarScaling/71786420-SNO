# configure_mcg

Installs the ODF operator and deploys Multicloud Object Gateway (MCG/NooBaa) in
**standalone mode** — S3-compatible object storage for this SNO deployment, without
Ceph.

## Why standalone MCG instead of full ODF/Ceph

The target hardware already has RAID5 providing disk redundancy. Full ODF/Ceph's
`StorageCluster` mode runs Ceph with its own 3x replication on top of that — redundant
operational and capacity overhead for a true single-node cluster that already has
disk-level protection, and isn't implemented anywhere in this repo. This role deploys
only the `NooBaa` CR (no `StorageCluster`/`CephCluster` anywhere in this role), backed
by a plain PVC that `configure_lvms` already provisions. See also
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md) for the
broader storage topology discussion.

## Hard dependency: `configure_lvms`

This role must run **after** `roles/ocp/configure_lvms`. `mcg_backing_storage_class`
defaults to `lvms_vg_name`'s storage class — standalone NooBaa's default backing store
is a PV-pool, i.e. it needs an existing StorageClass capable of satisfying a PVC
request, and LVMS is the only operator this repo installs that provides one for true
SNO.

## What it does

1. Installs the ODF operator (the `odf-operator` package also provides full
   ODF/Ceph's `StorageCluster` mode, not used by this role — MCG is just one mode it
   supports) and waits for `odf-operator-controller-manager` to be ready.
2. Applies a `NooBaa` CR in standalone mode.
3. Waits for `NooBaa.status.phase == Ready`.
4. Reads the operator-generated `noobaa-admin` Secret and the NooBaa S3 `Route`, then
   exposes `mcg_s3_endpoint`, `mcg_s3_access_key`, `mcg_s3_secret_key` as facts on
   `localhost` (same `delegate_to: localhost` / `delegate_facts: true` pattern
   `deploy_mirror_registry` uses for `mirror_registry_ca_cert`), for downstream roles
   such as `configure_mcg_backup_export` and any application that needs S3 storage.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `mcg_channel` | `stable` | The `odf-operator` package's channel. |
| `mcg_backing_pvc_size` | `500Gi` | Size the default backing store's PV-pool volume. Must fit under the RAID5 array's usable capacity alongside other LVMS-backed PVs — override per-environment. |
| `mcg_backing_storage_class` | `"{{ lvms_vg_name \| default('vg1') }}"` | Cross-role default, same pattern as `configure_onprem_quay`'s `quay_storage_class`. |

## Known gaps / verify against a live cluster

No live cluster exists yet to test this role against, so the following need
confirmation once hardware/a real ODF install is available:

- **NooBaa CR field names** (`templates/noobaa.yaml.j2`): `dbStorageClass` and
  `pvPoolDefaultStorageClass` are the standard NooBaa CRD fields for pointing the
  default PV-pool backing store at a StorageClass, but these have shifted across ODF
  releases — confirm with `oc explain noobaa.spec` against the actual installed
  operator version.
- **Backing-store sizing**: the NooBaa CR's auto-created default backing store has
  historically defaulted to a fixed per-volume size (around 50Gi) rather than reading
  an arbitrary size field. `mcg_backing_pvc_size` is defined here as the intended size,
  but wiring it in may require creating an explicit `BackingStore` CR (type
  `pv-pool`) instead of relying on the NooBaa CR's implicit default — see the inline
  comment in `templates/noobaa.yaml.j2`.
- **S3 Route name**: assumed to be `s3` in `openshift-storage` (NooBaa's standard
  generated route) — confirm once the operator is actually installed.
