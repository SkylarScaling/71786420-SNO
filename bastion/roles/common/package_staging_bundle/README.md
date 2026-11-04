# package_staging_bundle

Reverse direction of `package_bastion_bundle`/`unpack_bastion_bundle`, used by the
backup-export relay. Runs on the bastion (`hosts: localhost`) after
`export_backup_from_noobaa` (and, if `backup_egress_mode: internal`,
`push_backup_to_internal_target`), and archives the staged export data
(`backup_export_workspace`) into one `tar.gz` for the trip back to staging — the only
side of this split with real internet access to relay it on to an external S3
target via `push_backup_to_external_s3`.

Only runs when `backup_egress_mode` is `network` or `both` (gated in
`bastion/playbooks/export-backup.yaml`, not in this role itself).

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `staging_transfer_method` | `media` | `media` (default) just produces the tar.gz and prints manual-transfer instructions. `rsync` (opt-in) also pushes it directly to `staging_transfer_host`. |
| `staging_bundle_export_dir` | `/tmp/bastion-export` | |
| `staging_bundle_name` | `sno-staging-backup-bundle-{{ cluster_name }}.tar.gz` | |
| `staging_transfer_host`/`staging_transfer_user`/`staging_transfer_ssh_key`/`staging_transfer_dest_dir` | unset / `root` / `{{ ssh_private_key }}` / `/root` | Only used when `staging_transfer_method: rsync`. |

## Why this replaces `sync_backup_to_staging`

That role ran a raw `rsync` with `delegate_to`/polling tricks against a second host,
because a single controller used to orchestrate both the bastion and the
mirror-staging host in one playbook run. The bastion now only ever acts on itself
and, optionally, pushes outward — no cross-host delegation needed.

## Known gap

No live two-host transfer has been tested yet (no real bastion/staging pair
available during this restructuring).
