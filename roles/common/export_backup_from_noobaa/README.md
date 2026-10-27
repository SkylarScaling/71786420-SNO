# export_backup_from_noobaa

First step of the backup-export relay (see
[`roles/ocp/configure_mcg_backup_export/README.md`](../../ocp/configure_mcg_backup_export/README.md)
for the full picture and why this exists): runs on the **bastion** — the same
private network/switch as the SNO node on both providers — and pulls each bucket in
`backup_export_buckets` from NooBaa's S3 endpoint down to
`{{ backup_export_workspace }}` (`/opt/backup-export`) using `rclone` (downloaded
here into `{{ bin_dir }}`, since this host is separate from wherever
`install_ocp_prerequisites` ran).

Re-reads NooBaa's admin Secret and S3 Route itself on every run (doesn't depend on
`configure_mcg`'s in-memory `localhost` facts from an earlier playbook invocation) —
this is meant to be run periodically via `playbooks/export-backup.yaml`, on its own
schedule, separate from initial cluster setup.

## `media`-mode environments (the default)

When `backup_egress_mode: media` (the default), this role still runs — staging data
on the bastion is the one step every mode needs — but
`sync_backup_to_staging`/`push_backup_to_external_s3` are skipped by
`playbooks/export-backup.yaml`. From there, manually transfer
`{{ backup_export_workspace }}` on the bastion to removable media — there's no API
primitive for "replicate a bucket to a USB drive," so this step can't be automated
further. See `roles/ocp/configure_mcg_backup_export`'s README for the other two
modes (`internal`, `network`).

## Variables

- `backup_export_buckets`: list of NooBaa bucket names to export. Empty by default —
  application-specific, set per-environment.
- `backup_export_workspace`: local staging directory on the bastion.
- `bin_dir`, `rclone_download_url`: same self-contained-binary-download convention
  used elsewhere in this repo (`stage_mirror_content`'s `oc-mirror` download).
