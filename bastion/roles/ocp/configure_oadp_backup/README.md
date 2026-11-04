# configure_oadp_backup

Installs OADP (OpenShift API for Data Protection) and a `DataProtectionApplication`
targeting S3-compatible object storage for local PV and Kubernetes-resource backups
(see
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md#2-data-protection--storage-isolation)).

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
default `{{ cluster_name }}-daily-backup`) that runs a full backup — all
namespaces except `openshift-adp` itself, cluster resources included, PV data via
`kopia`/fs-backup — once daily at `oadp_backup_schedule_cron` (default `0 2 * * *`,
02:00), each backup retained for `oadp_backup_ttl` (default 30 days).

This is a general-purpose baseline, not a customer-confirmed SLA: it assumes no
stated RPO/RTO target tighter than "once a day, keep a month of restore points."
Override the `oadp_backup_*` defaults per environment once real RPO/RTO targets are
agreed, and add additional `Schedule` CRs (e.g. a tighter-cadence schedule scoped to
specific application namespaces) if a workload needs better than 24h RPO.

## Not yet included

DR restore rehearsal — actually exercising `velero restore create` against a backup
taken by this schedule and confirming data/resources come back intact — is not
automated here. Validate manually (or via a dedicated drill role, similar in spirit
to `roles/ocp/simulate_node_failure`) before relying on this for a real recovery.
