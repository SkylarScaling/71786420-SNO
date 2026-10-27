# push_backup_to_internal_target

Alternative final step of the backup-export relay (see
[`roles/ocp/configure_mcg_backup_export/README.md`](../../ocp/configure_mcg_backup_export/README.md))
for the common case where a real internet-reachable external S3 target isn't
available, but the customer already runs some S3-compatible backup system
(appliance, object store, etc.) **on the same disconnected network** as the
bastion and SNO node.

Unlike `push_backup_to_external_s3`, this role runs directly on the **bastion** —
there's no relay hop through `mirror_staging_host` and no internet route needed at
all, since the target is already reachable on the private network the bastion
sits on. It pushes `{{ backup_export_workspace }}` (the data
`export_backup_from_noobaa` staged there) straight to
`backup_internal_target_endpoint`/`bucket` using `rclone` (downloaded here into
`{{ bin_dir }}`, same convention as the other backup-export roles).

Only runs when `backup_egress_mode` is `internal` (gated in
`playbooks/export-backup.yaml`, not in this role itself).

## Per-environment target variables

`backup_internal_target_endpoint`, `backup_internal_target_bucket`,
`backup_internal_target_access_key`, `backup_internal_target_secret_key` are
deliberately left empty in `defaults/main.yaml` — set the real values in
`inventory/baremetal/inventory.yaml`'s `vars:` block, **not** in
`playbooks/group_vars/all.yaml`. Ansible's precedence puts `group_vars/all` above
inline inventory-file vars, so a default set there would silently win over a
per-environment inventory override.
