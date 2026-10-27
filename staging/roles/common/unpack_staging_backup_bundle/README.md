# unpack_staging_backup_bundle

First task in `staging/playbooks/receive-backup.yaml` — the staging-side counterpart
of the bastion's `package_staging_bundle`. Extracts the backup bundle the bastion
produced into `backup_push_source_dir`, which `push_backup_to_external_s3` (run
immediately after, in the same playbook) relays on to the real external S3 target.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `staging_backup_bundle_path` | `~/sno-staging-backup-bundle.tar.gz` | Where the bastion-produced tar.gz landed on staging (physically copied or rsynced). |
| `backup_push_source_dir` | `/opt/backup-export-staged` | Must match `push_backup_to_external_s3`'s own default. |

## Known gap

No live two-host transfer/unpack has been tested yet (no real bastion/staging pair
available during this restructuring).
