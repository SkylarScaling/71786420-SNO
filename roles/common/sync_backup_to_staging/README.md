# sync_backup_to_staging

Second step of the backup-export relay (see
[`roles/ocp/configure_mcg_backup_export/README.md`](../../ocp/configure_mcg_backup_export/README.md)) —
the literal reverse of `sync_mirror_to_bastion`. Runs with `hosts: bastion`,
delegating the transfer to whichever host is in the `mirror_staging_host` inventory
group (works identically for AWS's in-memory-added EC2 instance or bare metal's
static inventory host — no AWS/BMC-specific logic needed here).

Rsyncs `{{ backup_sync_source_dir }}` (the bastion's staged export from
`export_backup_from_noobaa`, default `/opt/backup-export`) to
`{{ backup_sync_dest_dir }}` (`/opt/backup-export-staged`) on the mirror-staging
host — the only host with real internet access on either provider — where
`push_backup_to_external_s3` picks it up.

Only runs when `backup_egress_mode` is `network` or `both` (gated in
`playbooks/export-backup.yaml`, not in this role itself).

## Why the rsync task is a raw `command`, not `ansible.posix.synchronize`

The actual transfer runs `rsync` directly via the `command` module rather than
`ansible.posix.synchronize`, specifically so it can be backgrounded with
`async`/`poll: 0` for progress reporting (see below) — `synchronize` is an action
plugin, not a real module, and errors with "This action does not support async" if
you try.

That still leaves the same direction problem `synchronize` would have had: rsync's
"local" side (the source, in push mode) is wherever the task actually executes — the
data here only exists on this role's own play host (the bastion), so the task
self-delegates (`delegate_to: "{{ inventory_hostname }}"`) to force rsync to actually
originate from the bastion, and addresses the destination explicitly at the
mirror-staging host. That direct hop needs SSH credentials usable from the bastion
itself; rather than introduce a new trust relationship, it stages a copy of the same
`ssh_private_key` both EC2 instances/hosts already trust (same `aws_key_pair`/
authorized key on bare metal) at `/tmp/.backup_sync_relay_key`, uses it for this one
rsync invocation, then removes it. See `sync_mirror_to_bastion`'s `tasks/main.yaml`
for the fuller explanation — this role hit (and fixes) the identical
`delegate_to`-direction bug.

On AWS, the mirror-staging host's inventory address is deliberately its **public**
IP (the controller needs that to reach it); the bastion has no internet route and can
only reach it via its private IP, exposed as the generic
`mirror_staging_relay_address` fact by `aws_provision_mirror_staging_host` for exactly
this purpose. Falls back to the `mirror_staging_host` group's own address when that
fact isn't set (bare metal, which has no public/private split).

## Progress reporting

Same pattern as `sync_mirror_to_bastion` (see that role's README for the full
rationale): the rsync task runs `async: 7200, poll: 0` instead of blocking
synchronously, and `tasks/_poll_rsync_progress.yml` is included recursively every 15
seconds to print the destination directory's growing size (checked on the
mirror-staging host) against the total size, until the job finishes. The
`async_status` check uses `failed_when: false` so a failed transfer is reported by
`tasks/main.yaml`'s own "Fail if..." task instead of aborting mid-poll.
