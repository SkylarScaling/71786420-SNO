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
2. Applies a `NooBaa` CR in standalone mode, with `manualDefaultBackingStore: true`
   (see "Why manualDefaultBackingStore" below).
3. Waits for `NooBaa.status.phase == Ready`.
4. Explicitly creates the default `BackingStore` (type `pv-pool`, sized from
   `mcg_backing_pvc_size`) and default `BucketClass`, then waits for each to report
   `Ready` — the operator won't create these itself once
   `manualDefaultBackingStore: true` is set.
5. Reads the operator-generated `noobaa-admin` Secret and the NooBaa S3 `Route`, then
   exposes `mcg_s3_endpoint`, `mcg_s3_access_key`, `mcg_s3_secret_key` as facts on
   `localhost` (same `delegate_to: localhost` / `delegate_facts: true` pattern
   `deploy_mirror_registry` uses for `mirror_registry_ca_cert`), for downstream roles
   such as `configure_mcg_backup_export` and any application that needs S3 storage.

## Why `manualDefaultBackingStore`

Confirmed live on AWS: NooBaa auto-detects the underlying cloud platform and, by
default, tries to provision its default backing store as a cloud-native one (AWS S3
here) via a `CredentialsRequest`. On a cluster using `credentialsMode: Manual`
(required in this repo — no internet route to IAM), CCO marks that
`CredentialsRequest` `provisioned: true` without ever writing the secret NooBaa is
waiting on, so the system sits in `Configuring` forever. Setting
`manualDefaultBackingStore: true` on the `NooBaa` CR stops the operator from
attempting that reconciliation at all — but per `oc explain
noobaa.spec.manualDefaultBackingStore`, this also means the operator will not create
*any* default backing store, cloud or otherwise, so this role creates the
`BackingStore`/`BucketClass` pair itself (`templates/noobaa-backingstore.yaml.j2`/
`noobaa-bucketclass.yaml.j2`) instead of relying on the CR's implicit default.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `mcg_channel` | `stable-4.22` | The `odf-operator` package's channel. |
| `mcg_backing_pvc_size` | `500Gi` | Size of the explicit `BackingStore`'s pv-pool volume (`spec.pvPool.resources.requests.storage`) — confirmed live this is honored, unlike the NooBaa CR's own implicit default backing store (which is fixed at 50Gi regardless of this var). Must fit under the RAID5 array's usable capacity alongside other LVMS-backed PVs — override per-environment. |
| `mcg_backing_storage_class` | `"lvms-{{ lvms_vg_name \| default('vg1') }}"` | Cross-role default, same pattern as `configure_onprem_quay`'s `quay_storage_class`. "lvms-" prefix required — LVMS's own auto-created default-deviceClass StorageClass is named `lvms-<vg name>`, not the bare VG name. |

## Confirmed live

All of the following were previously flagged here as unverified; confirmed live
2026-11-13 against a real mirrored 4.22 cluster:

- `dbStorageClass` on the `NooBaa` CR is the correct field and is honored.
  `pvPoolDefaultStorageClass` is no longer set here — it only controls the operator's
  own implicit default backing store, which `manualDefaultBackingStore: true` disables
  entirely.
- The S3 `Route` name is `s3` in `openshift-storage`, as assumed.
- `odf-operator` is a thin "operator of operators" as of ODF 4.19+ — it dynamically
  subscribes to ~11 further packages at runtime. See
  `staging/roles/common/stage_mirror_content/defaults/main.yaml`'s
  `oc_mirror_operator_packages` for the full pinned list; none of this role's
  Subscriptions resolve without them mirrored.
