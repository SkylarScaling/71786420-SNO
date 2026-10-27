# configure_mcg_backup_export

Validates configuration for exporting **application S3 data** (objects stored in
MCG/NooBaa via `configure_mcg`) off the node, as insurance against total node loss.
This is a fully disconnected single-node environment with hardware RAID5 providing
disk-level redundancy already — RAID5 protects against a single disk failure, it
does nothing for losing the whole node/chassis, which this covers.

A genuine internet-reachable external S3 target is the **least likely** of the
three export paths to actually be available on a deployment like this — don't
assume it exists by default. The realistic options are manual removable media, or
pushing to a backup system the customer already runs on the same disconnected
network as the bastion. See `backup_egress_mode` below.

## Why this role applies no CRs

An earlier version of this role created a NooBaa `BackingStore` pointed directly at
the external endpoint, intending continuous in-cluster replication. That doesn't
work: **the SNO node has no internet route at all** — it's fully air-gapped. A
BackingStore pointed at an external endpoint would never reach `Ready`; nothing in
this architecture reconciles that, so don't re-add it.

This role now only fails fast if `backup_egress_mode` requires the external S3 target
and `backup_external_s3_endpoint/bucket/access_key/secret_key` aren't all set, and
prints a pointer to the actual export mechanism below.

## The actual export path: `bastion/playbooks/export-backup.yaml`

Data always stages on the bastion first
(**`roles/common/export_backup_from_noobaa`**, runs directly on the bastion — same
private network/switch as the SNO node, so it can reach NooBaa's S3 Route without any
internet route — pulls the configured bucket(s) down to a local directory). From
there, `backup_egress_mode` picks one of three paths out:

- **`media`** (default): no further automation — a human manually copies
  `backup_export_workspace` from the bastion to removable media. See
  `roles/common/export_backup_from_noobaa`'s README. The safe default: it assumes
  nothing about what the customer's network allows.
- **`internal`**: **`roles/common/push_backup_to_internal_target`** (runs on the
  bastion) pushes the staged data straight to an S3-compatible backup system the
  customer already runs on the *same disconnected network* — no internet route
  needed at all. This is the realistic automated path on most deployments like this
  one; prefer it over `network` once the customer's on-prem backup target is
  confirmed.
- **`network`** / **`both`**: reuses the same bundle-and-transfer pattern the
  inbound mirroring pipeline uses (`stage_mirror_content` → `package_bastion_bundle`
  → `unpack_bastion_bundle` → `deploy_mirror_registry`), just reversed, since
  staging is the only side of this split with real internet access to move data all
  the way out:
  1. **`roles/common/package_staging_bundle`** (bastion) packages the staged data
     into a tar.gz, physically carried (or rsynced) to staging — the literal reverse
     of `package_bastion_bundle`.
  2. **`roles/common/unpack_staging_backup_bundle`** (staging) extracts it, then
     **`roles/common/push_backup_to_external_s3`** (also staging) pushes the data to
     the real external S3 target.

  Unlikely to apply on a genuinely disconnected production deployment — only use
  this if the customer has explicitly confirmed that outbound path exists. `both`
  also leaves the staged bastion copy in place for an additional manual media
  export.

Run `bastion/playbooks/export-backup.yaml` (and, for `network`/`both`,
`staging/playbooks/receive-backup.yaml` once the bundle arrives) periodically or
on-demand — there's no always-on replication path out of a disconnected cluster, so
this is a scheduled/manual job, not a continuously-running CR, the same way
`bastion/playbooks/mirror-refresh.yaml` is a separate
on-demand refresh rather than part of `provision-sno.yaml`.

## Per-environment target variables

- `backup_internal_target_endpoint`/`bucket`/`access_key`/`secret_key`
  (`roles/common/push_backup_to_internal_target`'s defaults) — the customer's
  on-prem backup system, for `backup_egress_mode: internal`.
- `backup_external_s3_endpoint`/`bucket`/`access_key`/`secret_key` (this role's
  defaults; only `backup_external_s3_region` gets a real default: `us-east-1`) — a
  genuine internet-reachable target, for `backup_egress_mode: network`/`both`.

Both sets are deliberately left empty in their respective `defaults/main.yaml`. Set
the real values in `staging/inventory/inventory.yaml`'s `vars:` block, **not** in
`staging/inventory/inventory.yaml` or back into either role's defaults — Ansible's
precedence puts playbook-adjacent `group_vars/all` above inline inventory-file
vars, so a default set there would silently win over a per-environment inventory
override.

## Scope: application S3 data only

Log/metrics export (Loki, cluster observability) is out of scope and not yet built —
don't assume `backup_egress_mode` covers log forwarding;
`roles/ocp/configure_log_forwarding` is unrelated to this export path.
