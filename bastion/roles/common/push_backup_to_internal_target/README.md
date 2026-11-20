# push_backup_to_internal_target

## tl;dr

Alternative final step of the backup-export relay for the common case where a real
internet-reachable external target isn't available, but the customer already runs
some backup system **on the same disconnected network** as the bastion and SNO node.
Runs directly on the **bastion** — no relay hop through staging, no internet route
needed at all.

### To use this correctly:

- Only runs when `backup_egress_mode` is `internal` (gated in
  `bastion/playbooks/export-backup.yaml`, not in this role itself).
- The target doesn't have to be S3-compatible — set `backup_internal_target_type` to
  `s3` (default) | `smb` | `sftp` | `local`, see "Target type" below for the vars each
  needs.
- All target vars are deliberately left empty in `defaults/main.yaml` — set the real
  values in `staging/inventory/inventory.yaml`'s `vars:` block, not by hand-editing
  `bastion/group_vars/all.yaml` directly.
- See
  [`roles/ocp/configure_mcg_backup_export/README.md`](../../ocp/configure_mcg_backup_export/README.md)
  for the full relay picture.

## Full Details:

It pushes `{{ backup_export_workspace }}` (the data `export_backup_from_noobaa`
staged there) to the target using `rclone` (downloaded here into `{{ bin_dir }}`,
same convention as the other backup-export roles).

## Target type: `backup_internal_target_type`

The customer's on-prem backup target doesn't have to be S3-compatible — this hop is
this repo's own `rclone` invocation, not an OADP/Velero component. Set
`backup_internal_target_type` to one of:

- `s3` (default): `backup_internal_target_endpoint`, `backup_internal_target_bucket`,
  `backup_internal_target_access_key`, `backup_internal_target_secret_key`.
- `smb`: `backup_internal_target_host`, `backup_internal_target_share`,
  `backup_internal_target_user`, `backup_internal_target_password` (obscured via
  `rclone obscure` before use), optional `backup_internal_target_domain`.
- `sftp`: `backup_internal_target_host`, `backup_internal_target_user`,
  `backup_internal_target_port` (default `22`), and either
  `backup_internal_target_ssh_key_file` (preferred) or
  `backup_internal_target_password` (obscured like SMB).
- `local`: `backup_internal_target_path` — an already-mounted local filesystem path
  (NFS/CIFS mount, USB, etc.); this role does not manage the mount itself.

## Per-environment target variables

All of the vars above are deliberately left empty (or default-only, e.g.
`backup_internal_target_type: s3`) in `defaults/main.yaml` — set the real values in
`staging/inventory/inventory.yaml`'s `vars:` block (the one source of
per-environment config, packaged into `bastion/group_vars/all.yaml` by
`unpack_bastion_bundle`), not by hand-editing `bastion/group_vars/all.yaml` directly.
