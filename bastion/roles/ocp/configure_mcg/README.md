# configure_mcg

## tl;dr

Installs the ODF operator and deploys Multicloud Object Gateway (MCG/NooBaa) in
**standalone mode** — S3-compatible object storage for this SNO deployment, without
Ceph.

### To use this correctly:

- Must run after `configure_lvms` (see "Hard dependency" below).
- Mirroring `odf-operator` alone is not enough — `staging/roles/common/
  stage_mirror_content`'s `oc_mirror_operator_packages` must also list every
  ODF 4.22 sub-operator package (`ocs-operator`, `mcg-operator`,
  `rook-ceph-operator`, `odf-csi-addons-operator`, `cephcsi-operator`,
  `odf-dependencies`, `odf-prometheus-operator`, `recipe`, `ocs-client-operator`,
  `ocs-tls-profiles`, `odf-external-snapshotter-operator`), or the Subscription
  fails with `constraints not satisfiable: ... requires an operator with package:
  ocs-tls-profiles` (confirmed live) — see "Why odf-operator needs so many
  sub-packages mirrored" below.

## Full Details:

## Why standalone MCG instead of full ODF/Ceph

The target hardware already has RAID5 providing disk redundancy. Full ODF/Ceph with
Ceph's own 3x replication on top of that is redundant operational and capacity
overhead for a true single-node cluster that already has disk-level protection, and
isn't implemented anywhere in this repo. This role deploys a `StorageCluster` CR with
`spec.multiCloudGateway.reconcileStrategy: standalone` — the supported "MCG-only"
mode, which deploys only NooBaa, never a `CephCluster` — backed by a plain PVC that
`configure_lvms` already provisions. See also
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md) for the
broader storage topology discussion.

## Hard dependency: `configure_lvms`

This role must run **after** `roles/ocp/configure_lvms`. `mcg_backing_storage_class`
defaults to `configure_lvms`'s Retain-policy StorageClass (`lvms_retain_storage_class_name`,
default `vg1-retain`) — standalone NooBaa's default backing store is a PV-pool, i.e.
it needs an existing StorageClass capable of satisfying a PVC request, and LVMS is
the only operator this repo installs that provides one for true SNO. Retain, not the
shared Delete-reclaim `vg1` default, since this PV-pool holds the actual bytes for
every S3 bucket in the cluster (including OADP's own backups) — same reasoning as
`configure_postgres`'s `postgres_storage_class`. Confirmed live: this previously fell
back to the shared Delete-policy `vg1` default instead.

## What it does

1. Installs the ODF operator and waits for `odf-operator-controller-manager` to be
   ready.
2. Labels the SNO node `cluster.ocs.openshift.io/openshift-storage=''` — required for
   NooBaa's pods to schedule, even in standalone mode (confirmed live; `ocs-operator`
   uses the same node-selection logic regardless of `reconcileStrategy`).
3. Applies a `StorageCluster` CR with `spec.multiCloudGateway.reconcileStrategy:
   standalone`, and waits for `StorageCluster.status.phase == Ready`.
4. Waits for the `NooBaa` CR `ocs-operator` creates from that `StorageCluster` to
   reach `status.phase == Ready`.
5. Reads the operator-generated `noobaa-admin` Secret and the NooBaa S3 `Route`, then
   exposes `mcg_s3_endpoint`, `mcg_s3_access_key`, `mcg_s3_secret_key` as facts on
   `localhost` (same `delegate_to: localhost` / `delegate_facts: true` pattern
   `deploy_mirror_registry` uses for `mirror_registry_ca_cert`), for downstream roles
   such as `configure_mcg_backup_export` and any application that needs S3 storage.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `mcg_channel` | `stable-4.22` | The `odf-operator` package's channel. **Must match** `stage_mirror_content`'s `oc_mirror_operator_packages` pin for every ODF sub-package (same `stable-X.Y`) — see "Why odf-operator needs so many sub-packages mirrored" below. |
| `mcg_backing_pvc_size` | `500Gi` | Intended size for the default backing store's PV-pool volume — **not yet wired into `templates/storagecluster.yaml.j2`**, see "Known gaps" below. Must fit under the RAID5 array's usable capacity alongside other LVMS-backed PVs — override per-environment. |
| `mcg_backing_storage_class` | `"{{ lvms_retain_storage_class_name \| default('vg1-retain') }}"` | Defaults to `configure_lvms`'s Retain-policy StorageClass, not the shared `vg1` (Delete) default — see "Hard dependency" above. Passed as `spec.multiCloudGateway.dbStorageClassName` on the `StorageCluster` CR. |

## Why `odf-operator` needs so many sub-packages mirrored

ODF has shipped as a meta-operator since 4.19 — `odf-operator`'s own Subscription
installs these sub-operator packages via its own generated Subscriptions at
install time, not as static CSV dependencies `oc-mirror` can resolve and mirror
transitively ahead of time. Confirmed live: mirroring only `odf-operator` left the
`odf-dependencies` bundle's own requirement for `ocs-tls-profiles` unsatisfiable,
since that package was never in the mirrored catalog at all — OLM's resolver had
nothing to find. `odf-multicluster-orchestrator` (Metro-DR/Regional-DR) and
`local-storage-operator` (Ceph local-disk PV provisioning) are deliberately left
out of the mirrored set — neither applies to this role's standalone-MCG mode, which
never creates a `CephCluster` CR (the `StorageCluster` this role does create sets
`spec.multiCloudGateway.reconcileStrategy: standalone`, which tells `ocs-operator` to
skip Ceph entirely). This sub-package list is sourced
from community mirroring guides and a GitHub PR description, not a primary Red Hat
CSV dependency manifest (Red Hat's downstream ODF bundle isn't publicly browsable)
— re-verify against `oc-mirror list operators --v1 --catalog
registry.redhat.io/redhat/redhat-operator-index:v4.22 --package odf-operator` (and
actually completing an install) once a live mirror/cluster is available, and watch
for this list changing on an `openshift_version` bump.

**Don't trim this list for standalone-MCG mode, even though several entries
(`rook-ceph-operator`, `cephcsi-operator`, `ocs-client-operator`, `recipe`,
`odf-csi-addons-operator`, `odf-external-snapshotter-operator`,
`odf-prometheus-operator`) sound Ceph/StorageCluster-specific.** Confirmed from
`odf-operator`'s own source (`controllers/subscription_controller.go`,
`red-hat-storage/odf-operator`): it loads a fixed `pkgs-config` ConfigMap and
subscribes to every listed sub-operator package unconditionally — there's no
branching on `StorageSystem` kind or MCG-vs-Ceph mode. The package list is baked in
per-ODF-version at build time, not computed from which CRs actually get created
afterward. So even in standalone-MCG mode, `odf-operator` still requests a
Subscription for every one of these — their workload-level CRs (e.g. `CephCluster`)
just never get created, but the package-level Subscription is still required for
install to succeed at all. Removing any of them reproduces the exact
`ConstraintsNotSatisfiable` bug this list was added to fix.

## Known gaps / verify against a live cluster

- **Backing-store sizing**: `mcg_backing_pvc_size` isn't wired into
  `templates/storagecluster.yaml.j2` at all yet — `spec.multiCloudGateway` has no
  documented size field, and the NooBaa CR `ocs-operator` creates from it has
  historically defaulted its auto-created default backing store to a fixed per-volume
  size (around 50Gi). Wiring in a real size likely means creating an explicit
  `BackingStore` CR (type `pv-pool`) referencing `mcg_backing_pvc_size` after
  `StorageCluster`/`NooBaa` come up, rather than relying on either CR's implicit
  default — not yet implemented, confirm against a live cluster.
- **S3 Route name**: assumed to be `s3` in `openshift-storage` (NooBaa's standard
  generated route) — confirm once the operator is actually installed.
