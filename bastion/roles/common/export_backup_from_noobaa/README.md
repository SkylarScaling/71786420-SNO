# export_backup_from_noobaa

## tl;dr

First step of the backup-export relay: runs on the **bastion** — the same private
network/switch as the SNO node — and pulls each bucket in `backup_export_buckets`
from NooBaa's S3 endpoint down to `{{ backup_export_workspace }}` for onward
export (removable media by default, or an automated push via `backup_egress_mode`).

### To use this correctly:

- `backup_export_buckets` defaults to just the OADP/Velero backup bucket
  (`backup_s3_bucket`) — add application-created buckets per-environment if those
  also need exporting.
- **Known gap**: the `rclone` `get_url` requires internet access, which the bastion
  doesn't have — see the comment in `tasks/main.yaml`; not yet part of the
  staging-produced bundle the way openshift-install/oc/oc-mirror are.
- Meant to be run periodically via `bastion/playbooks/export-backup.yaml`, on its own
  schedule, separate from initial cluster setup — see
  [`roles/ocp/configure_mcg_backup_export/README.md`](../../ocp/configure_mcg_backup_export/README.md)
  for the full picture and why this exists.

## Full Details:

Re-reads NooBaa's admin Secret and S3 Route itself on every run (doesn't depend on
`configure_mcg`'s in-memory facts from an earlier playbook invocation).

## `media`-mode environments (the default)

When `backup_egress_mode: media` (the default), this role still runs — staging data
on the bastion is the one step every mode needs — but `package_staging_bundle`/
`push_backup_to_external_target` are skipped by `bastion/playbooks/export-backup.yaml`
and `staging/playbooks/receive-backup.yaml`. From there, manually transfer
`{{ backup_export_workspace }}` on the bastion to removable media — there's no API
primitive for "replicate a bucket to a USB drive," so this step can't be automated
further. See `roles/ocp/configure_mcg_backup_export`'s README for the other two
modes (`internal`, `network`).

## Variables

- `backup_export_buckets`: list of NooBaa bucket names to export. Defaults to just
  `backup_s3_bucket` (the OADP/Velero backup bucket) — without it, OADP's own
  backups, including stateful-workload PV data, would never leave the node. Add
  application-created buckets per-environment if those also need exporting.
- `backup_export_workspace`: local staging directory on the bastion.
- `bin_dir`, `rclone_download_url`: same self-contained-binary-download convention
  used elsewhere in this repo (`stage_mirror_content`'s `oc-mirror` download).
