# push_backup_to_external_s3

Final step of the backup-export relay (see
[`roles/ocp/configure_mcg_backup_export/README.md`](../../ocp/configure_mcg_backup_export/README.md)).
Runs on `mirror_staging_host` — the only host with real internet access on either
provider — pushing `{{ backup_push_source_dir }}` (the data
`sync_backup_to_staging` relayed there) up to the real external S3 target using
`rclone` (downloaded here into `{{ bin_dir }}`, same convention as
`stage_mirror_content`'s `oc-mirror` download, since this host is separate from
wherever that ran).

Uses `backup_external_s3_endpoint`/`backup_external_s3_bucket`/
`backup_external_s3_access_key`/`backup_external_s3_secret_key` — plain
per-environment inventory vars (see `roles/ocp/configure_mcg_backup_export`'s
README for where to set them), no cross-playbook fact dependency.

Only runs when `backup_egress_mode` is `network` or `both` (gated in
`playbooks/export-backup.yaml`, not in this role itself).
