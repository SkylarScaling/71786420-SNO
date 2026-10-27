# sync_mirror_to_bastion

Second step of the disconnected mirroring pattern (see
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md#2-disconnected-content-mirroring)):
moves the archive produced by `stage_mirror_content` onto the disconnected bastion.
Used identically by both providers.

Also syncs `{{ mirror_installers_dir }}` (the raw `oc-mirror`/`mirror-registry`
tarballs `stage_mirror_content` downloaded) to the same path on the bastion — it has
no internet route of its own, so `deploy_mirror_registry` depends on this sync to get
those tools at all, not just the content archive. Run synchronously (not
async/polled like the content archive) since it's a small, fast transfer by
comparison.

`stage_mirror_content` renders `imageset-config.yaml` directly inside
`mirror_sync_source_dir` (the archive directory), not a separate location — so it
rides along with this sync automatically. `oc-mirror --v2`'s "disk to mirror" push
(`deploy_mirror_registry`) needs that file again, unlike v1 where the archive alone
was self-describing; no separate sync path was needed to support that.

The rsync itself runs with `--delete --exclude=working-dir`: `--delete` keeps the
bastion's copy from accumulating old tar chunks across repeated runs (a plain rsync
push only adds/updates, never removes — harmless under v1's self-describing archive,
just wasted disk under v2's chunked tars); `--exclude=working-dir` skips
`stage_mirror_content`'s own "mirror to disk" scratch output, which
`deploy_mirror_registry`'s push regenerates fresh from the synced tar chunks and never
reads a pre-existing copy of anyway. Neither of these was the fix for a real "disk to
mirror" push failure (`manifest unknown` for `certified-operator-index:v4.22`) they
were initially suspected of causing — that turned out to be a genuine `oc-mirror --v2`
defect (a multi-catalog mirror-to-disk run left one catalog's tag pointing at a
manifest whose blob was never committed to the archive), fixed by re-running
`stage_mirror_content`, not by anything in this role. See
`roles/common/stage_mirror_content/README.md` for the full account.

## `mirror_sync_method`

- `rsync` (default): the staging host has *some* reachable network path to the
  bastion. On AWS this is the private VPC route between the public mirror-staging
  subnet and the private bastion subnet — no internet required for this hop. On bare
  metal it's whatever private network path connects the staging host to the bastion.
- `media`: no network path exists at all — this mode only produces a tarball under
  `/tmp` and prints the manual transfer step. Copying it to the bastion via USB/removable
  media is intentionally left manual; automating physical media handling is out of
  scope for Ansible.

## Why the rsync task is a raw `command`, not `ansible.posix.synchronize`

The actual transfer runs `rsync` directly via the `command` module rather than
`ansible.posix.synchronize`, specifically so it can be backgrounded with
`async`/`poll: 0` for progress reporting (see below) — `synchronize` is an action
plugin, not a real module, and errors with "This action does not support async" if
you try.

That still leaves the same direction problem `synchronize` would have had: rsync's
"local" side (the source, in push mode) is wherever the task actually executes —
the Ansible controller by default — but the mirror archive only exists on this role's
own play host (the mirror-staging host). The task self-delegates
(`delegate_to: "{{ inventory_hostname }}"`) to force rsync to actually originate
there, and addresses the destination explicitly at the bastion over SSH. That direct
hop needs SSH credentials usable from the mirror-staging host itself; rather than
introduce a new trust relationship, it stages a copy of the same `ssh_private_key`
both EC2 instances/hosts already trust (same `aws_key_pair`/authorized key on bare
metal) at `/tmp/.mirror_sync_relay_key`, uses it for this one rsync invocation, then
removes it.

(Getting the delegation wrong — e.g. pointed at the bastion instead — makes rsync try
to run from the bastion's filesystem back out to the mirror-staging host's public IP,
which the bastion has no route to at all; this produces an opaque
`ssh: connect to host <public IP> ... Connection timed out` rather than any
obviously-wrong-direction error.)

## Progress reporting

A plain, synchronous rsync invocation blocks until the whole subprocess finishes and
gives no intermediate output of its own, which makes a large archive transfer look
stalled. The rsync task instead runs `async: 7200, poll: 0` (fire-and-forget), and
`tasks/_poll_rsync_progress.yml` is then included recursively every 15 seconds to
print a `debug` message with the destination directory's growing size (checked on the
bastion) against the total archive size — until `async_status` reports the job
finished. The `async_status` check itself uses `failed_when: false`, since the
underlying `command` module would otherwise auto-fail (and abort the play) on a
non-zero `rc` before `tasks/main.yaml`'s own "Fail if..." task gets a chance to report
a clearer message. `_poll_rsync_progress.yml` isn't meant to run standalone; it
depends on vars (`_mirror_sync_job`, `_mirror_sync_total_size`, `_bastion_addr`) set
by `tasks/main.yaml`.
