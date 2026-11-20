# configure_oadp_backup

## tl;dr

Installs OADP (OpenShift API for Data Protection) and a `DataProtectionApplication`
targeting the in-cluster NooBaa S3 endpoint, backing up stateful data only by
default (see "Backup scope" below).

### To use this correctly:

- Requires `roles/ocp/configure_mcg` to already be installed, and a NooBaa bucket
  named `backup_s3_bucket` to exist (bucket creation isn't handled by this role).
- Default scope is `oadp_backup_scope: stateful` — only `oadp_backup_stateful_namespaces`
  (default `postgres`) get backed up. Full-platform backup
  (`oadp_backup_scope: platform`) is available but opt-in, not the recommended
  steady state — see "Backup scope" below.
- For data to actually leave the node, pair this with
  `roles/ocp/configure_mcg_backup_export`'s offsite-export relay — this role only
  writes backups into the in-cluster NooBaa bucket, it doesn't export them.
- DR restore rehearsal is not automated — see "Not yet included" below.

## Full Details:

`nodeAgent.uploaderType: kopia` enables the CSI data-mover path (application-consistent
volume snapshots shipped to the `backupLocations` target), useful for active
database/workload instances — not just etcd/API object backups.

## Backend: in-cluster NooBaa

Targets the in-cluster NooBaa S3 endpoint provided by `roles/ocp/configure_mcg` — no
external S3 account, credentials, or network route needed, which also means it works
unmodified on bare metal's fully disconnected network.
Credentials are read directly from the `noobaa-admin` Secret; nothing to supply
locally. Requires `roles/ocp/configure_mcg` to already be installed, and a NooBaa
bucket named `backup_s3_bucket` to exist (bucket creation isn't handled by this
role).

An external AWS S3 bucket was considered as an alternative backend early on, but
dropped: once `configure_mcg` was adopted on both providers (not just bare metal),
there was no longer a case where the in-cluster NooBaa endpoint wasn't already
available, and an external-S3 option only actually worked on the AWS test loop
anyway (reachable there via an S3 VPC Gateway Endpoint, not a real internet route —
bare metal has no equivalent and no internet route at all). Don't reintroduce an
`aws` backend option without re-solving that reachability problem.

## Default backup schedule

Once the `DataProtectionApplication` is applied and its `velero` Deployment is
ready, this role creates a Velero `Schedule` CR (`oadp_backup_schedule_name`,
default `{{ cluster_name }}-daily-backup`) once daily at `oadp_backup_schedule_cron`
(default `0 2 * * *`, 02:00), each backup retained for `oadp_backup_ttl` (default 30
days).

This is a general-purpose baseline, not a customer-confirmed SLA: it assumes no
stated RPO/RTO target tighter than "once a day, keep a month of restore points."
Override the `oadp_backup_*` defaults per environment once real RPO/RTO targets are
agreed, and add additional `Schedule` CRs (e.g. a tighter-cadence schedule scoped to
specific application namespaces) if a workload needs better than 24h RPO.

## Backup scope: stateful data only (default), full platform (opt-in)

This whole cluster is provisioned via IaC (this repo) — re-creating Operators,
Subscriptions, Deployments, etc. via a Velero restore is redundant; the only thing
IaC can't regenerate is actual stateful bytes. `oadp_backup_scope: stateful`
(default) backs up only `oadp_backup_stateful_namespaces`' PV data
(`includeClusterResources: false`) — defaults to just `postgres`
(`configure_postgres`'s namespace); add `rabbitmq`/`keycloak`/etc. per-environment if
their data turns out to matter beyond cache. `openshift-storage` (NooBaa's own
PV-pool PVC) is deliberately never included here — backing up the volume that backs
the backup bucket itself via Velero/kopia would be circular; NooBaa's object data is
handled by `roles/common/export_backup_from_noobaa`'s offsite-export relay instead.

`oadp_backup_scope: platform` restores the previous behavior — every namespace
(`excludedNamespaces: oadp_backup_excluded_namespaces`), cluster resources included.
Useful for a one-off full-state snapshot before a risky change, but not the
recommended steady-state default now that stateful-only scope exists.

## Not yet included

DR restore rehearsal — actually exercising `velero restore create` against a backup
taken by this schedule and confirming data/resources come back intact — is not
automated here. Validate manually (or via a dedicated drill role, similar in spirit
to `roles/ocp/simulate_node_failure`) before relying on this for a real recovery.
