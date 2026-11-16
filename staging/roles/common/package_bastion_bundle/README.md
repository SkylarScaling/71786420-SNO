# package_bastion_bundle

Second step of the disconnected mirroring pipeline, after `stage_mirror_content`.
Runs on staging (`hosts: localhost`) and assembles the single artifact the bastion
needs to run its own automation: the mirrored registry content, the minimal
oc-mirror cache handoff `stage_mirror_content` built for release-component images
(see that role's README for why this exists), the
`openshift-install`/`oc`/`oc-mirror`/`mirror-registry` binaries, the full `bastion/`
automation tree (playbooks + roles), a flattened resolved-vars file generated from
`staging/inventory/inventory.yaml`, and a copy of the operator's own SSH private key
(as `relay-key`) for the bastion's own return-trip pushes — see
`unpack_bastion_bundle`'s README for why that last one exists. One `tar.gz`,
physically carried to the bastion by default.

## Why bundle the `bastion/` tree itself, not just content

The bastion has no internet route and no other way to get this repo's code or its
own per-environment config. Bundling everything into one artifact means the
operator only ever needs to move one file to bring up a bastion from scratch — there
is no separate "first get the code onto the bastion" step.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `bastion_transfer_method` | `media` | `media` (default) just produces the tar.gz and prints manual-transfer instructions. `rsync` (opt-in) also pushes it directly to `bastion_transfer_host`. |
| `bastion_bundle_export_dir` | `/tmp/staging-export` | Where the tar.gz (and its staging-root scratch dir) is assembled. |
| `bastion_bundle_name` | `sno-bastion-bundle-{{ cluster_name }}.tar.gz` | |
| `bastion_tree_dir` | `{{ playbook_dir }}/../../bastion` | The sibling `bastion/` checkout to bundle. Override if staging/ and bastion/ aren't siblings. |
| `release_cache_handoff_dir` | `{{ oc_mirror_workspace }}/release-cache-handoff` | Same variable name (and default) as `stage_mirror_content`'s — must match since that's how this role's input reaches that role's output. |
| `bastion_transfer_host`/`bastion_transfer_user`/`bastion_transfer_ssh_key`/`bastion_transfer_dest_dir` | unset / `root` / `{{ ssh_private_key }}` / `/root` | Only used when `bastion_transfer_method: rsync`. |

## Why this is simpler than the old `sync_mirror_to_bastion` role

That role had to run a raw `rsync` command with `delegate_to: inventory_hostname`
tricks and async-polling against a *second* host, because a single Ansible
controller used to orchestrate both the mirror-staging host and the bastion in one
playbook run. Now staging only ever acts on itself and, optionally, pushes outward —
there's no cross-host delegation, no "which side is actually local" confusion, and
no polling loop needed, since this host is the only one doing anything.

## Disk usage: bundle-root is hardlinked, not copied

Every `copy` into `bundle-root` (bastion/ tree, mirror content, installer tarballs,
release-cache handoff) uses `cp -al` (falling back to a real `cp -a` if ever run
across a mount boundary), not the `copy` module — confirmed live: a real run's
mirrored content was ~100GiB, and a second *physical* copy of that into
`bundle-root` on top of `stage_mirror_content`'s own `oc_mirror_workspace` exhausted
a 250GB root volume before the final tar.gz was even written ("No space left on
device" mid-archive). Hardlinking costs ~0 extra disk for this read-only,
never-modified-in-place content, leaving the final tar.gz as the only genuinely new
data written during packaging. See `stage_mirror_content`'s
`oc_mirror_cleanup_cache_after_stage` for the other half of this fix (freeing the
oc-mirror cache, which this role never reads).

## Known gap

The `rsync` transfer path (`bastion_transfer_method: rsync`) is unverified against
a real run — the `media` path (confirmed live 2026-11-15/16) is the one exercised
so far.
