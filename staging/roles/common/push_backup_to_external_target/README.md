# push_backup_to_external_target

## tl;dr

Final step of the backup-export relay. Runs on staging (`hosts: localhost`) — the
only side of this split with real internet access — pushing the data
`unpack_staging_backup_bundle` just extracted up to the real external target.

### To use this correctly:

- Only runs when `backup_egress_mode` is `network` or `both` (gated in
  `staging/playbooks/receive-backup.yaml`, not in this role itself).
- The target doesn't have to be S3-compatible — set `backup_external_target_type` to
  `s3` (default) | `smb` | `sftp` | `local`, see "Target type" below for the vars each
  needs.
- All per-type vars are deliberately left empty (or default-only) in
  `defaults/main.yaml` — set the real values in `staging/inventory/inventory.yaml`'s
  `vars:` block.
- See
  [`roles/ocp/configure_mcg_backup_export/README.md`](../../ocp/configure_mcg_backup_export/README.md)
  for the full relay picture.

## Full Details:

Pushes `{{ backup_push_source_dir }}` (the data `unpack_staging_backup_bundle` just
extracted from the bastion-produced backup bundle) using `rclone` (downloaded here
into `{{ bin_dir }}`, same convention as `stage_mirror_content`'s `oc-mirror`
download).

## Target type: `backup_external_target_type`

The external target doesn't have to be S3-compatible — this hop is this repo's own
`rclone` invocation, not an OADP/Velero component. Set `backup_external_target_type`
to one of:

- `s3` (default): `backup_external_s3_endpoint`, `backup_external_s3_bucket`,
  `backup_external_s3_access_key`, `backup_external_s3_secret_key` — plain
  per-environment inventory vars (see `roles/ocp/configure_mcg_backup_export`'s
  README for where to set them).
- `smb`: `backup_external_target_host`, `backup_external_target_share`,
  `backup_external_target_user`, `backup_external_target_password` (obscured via
  `rclone obscure` before use), optional `backup_external_target_domain`.
- `sftp`: `backup_external_target_host`, `backup_external_target_user`,
  `backup_external_target_port` (default `22`), and either
  `backup_external_target_ssh_key_file` (preferred) or
  `backup_external_target_password` (obscured like SMB).
- `local`: `backup_external_target_path` — an already-mounted local filesystem path on
  staging; this role does not manage the mount itself.

All per-type vars are deliberately left empty (or default-only) in
`defaults/main.yaml` — set the real values in `staging/inventory/inventory.yaml`'s
`vars:` block, no cross-playbook fact dependency.
