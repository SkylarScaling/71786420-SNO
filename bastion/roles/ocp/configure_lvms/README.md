# configure_lvms

Installs the LVM Storage (LVMS) operator and creates an `LVMCluster` — the storage
backend most SNO deployments run.

## Why not ODF here

OpenShift Data Foundation in compact mode requires 3 nodes for Ceph quorum — it isn't
applicable to a true single-node cluster. A storage architecture review that weighs
ODF vs. LVMS (node-local storage, snapshot handling, portability, disk/node failure
recovery) is a desk analysis, not something this repo automates; LVMS is the only
operator actually installed and tested here.

## Variables

- `lvms_device_paths`: list of block devices to use (e.g. `['/dev/nvme1n1']`). Leave
  empty to let LVMS auto-discover unused disks — fine for AWS testing with an extra
  EBS volume attached, but set explicitly for a real bare-metal server.
- `lvms_vg_name`, `lvms_thin_pool_name`: naming only.
- `lvms_retain_storage_class_enabled` (default `true`), `lvms_retain_storage_class_name`
  (default `{{ lvms_vg_name }}-retain`): see "Retain-policy StorageClass" below.

## Retain-policy StorageClass

LVMS/topolvm's own per-deviceClass StorageClass (`vg1`) has an immutable
`reclaimPolicy: Delete` — it can't be edited in place once created. Rather than add a
second `LVMCluster` deviceClass (which would carve out a second, separate physical
thin pool for no real benefit), this role also creates a plain `StorageClass` object
(`templates/retain-storageclass.yaml.j2`) with `reclaimPolicy: Retain` that points at
the **same** underlying device class via topolvm's own `parameters.topolvm.io/
device-class` field — so it shares `vg1`'s actual storage, just with different
reclaim semantics. `roles/ocp/configure_postgres` defaults to this class instead of
`vg1`, since Postgres is the one workload in this repo whose data has no separate
durable copy elsewhere. Every other block-storage consumer (RabbitMQ, Redis,
LokiStack, TempoStack) keeps using plain `vg1` — their data is ephemeral/
re-creatable or itself object-storage-backed, so Delete reclaim is appropriate and
avoids leaking orphaned volumes.
