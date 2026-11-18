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

**Does not include `sync_bastion_rpms`'s output** (the bastion's own OS-level RPM
sync) — that ships as its own, separate tar.gz via `package_bastion_rpms_bundle`
(called by this role too, so a combined run still produces both), so it can be
refreshed independently without re-sending this much larger bundle. See that role's
README.

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

## How vars reach `bastion-resolved-vars.yaml`

The intent is still that `templates/bastion-resolved-vars.yaml.j2`'s hand-listed vars
are kept up to date as the actual, complete, reviewable record of what reaches the
bastion — that's deliberate (simple and readable), not something this section
replaces. Confirmed live as a real gap in keeping that upkeep current: a customer's
`bastion_rpm_sync_method: resolve` override had no effect on the bastion at all,
because that var hadn't been added to the hand-listed names, so it never made it into
the file `unpack_bastion_bundle` writes to `bastion/group_vars/all.yaml`.

`tasks/main.yaml`'s "Determine which extra vars need to reach the bastion" task
exists for two narrower purposes, not as a general substitute for that upkeep —
unioned and resolved via `lookup('vars', ...)` (which honors normal Ansible
precedence — an inventory override still wins over a role default):

- **`_bastion_facing_role_vars`**: an explicit, permanent allowlist of
  `sync_bastion_rpms` vars that are a bastion-agreed *choice*
  (`bastion_rpm_sync_method`, `bastion_packages`, `bastion_required_repos` — these
  lived in `stage_mirror_content` before that role's RPM-sync tasks were split out
  into `sync_bastion_rpms`, see that role's README) — **not** that role's entire
  `defaults/main.yaml`. Most staging-side roles' defaults are staging-local storage
  paths/URLs (`oc_mirror_workspace`, `mirror_installers_dir`, `ocp_mirror_url`, etc.)
  that are deliberately independent per host (see the CAUTION comment at the top of
  `inventory.yaml`) — auto-including those would silently push staging's absolute
  paths onto the bastion. Treat this list the same as the template's own hand-listed
  vars: add a new var here deliberately when it becomes a permanent part of the
  bastion contract.
- **Inventory-only vars**: every key actually present in `inventory.yaml`'s own
  `vars:` block, so an operator can add a brand-new ad-hoc var there for
  one-off/iterative testing (no role default needed anywhere) and have it reach the
  bastion immediately, without a code change. This is a testing convenience, not a
  place to leave a var permanently — once it's no longer a one-off, move it into the
  template's hand-listed set (or `_bastion_facing_role_vars`) like any other
  permanent var.

Any name already on the explicit hand-list above is excluded from this
auto-inclusion, so nothing is emitted twice. If you need another role's var to reach
the bastion the same way, add its name to the allowlist in that task — don't widen
it to a whole-file scan.

## Disk usage: bundle-root is hardlinked, not copied

Every copy into `bundle-root` (`bastion/` tree, mirror content, installer tarballs,
release-cache handoff) uses `cp -al` (falling back to a real `cp -an` if ever run
across a mount boundary or against root-owned files — see the comment above the
`bastion/` tree copy task), not `ansible.posix.synchronize`/rsync. Confirmed live: a
real run's mirrored content was ~100GiB, and a second *physical* rsync copy of that
into `bundle-root`, on top of `stage_mirror_content`'s own `oc_mirror_workspace`,
exhausted a 250GB root volume before the final tar.gz was even written ("No space
left on device" mid-archive). Hardlinking costs ~0 extra disk for this read-only,
never-modified-in-place content, leaving the final tar.gz as the only genuinely new
data written during packaging — see `stage_mirror_content`'s
`oc_mirror_cleanup_cache_after_stage` (where it exists) for the other half of this
fix, freeing the oc-mirror cache this role never reads.

`bundle-root` is wiped and rebuilt on every run (`state: [absent, directory]`) rather
than reused incrementally the way the previous rsync-based copy had to be — an
earlier version of this role tried reusing it with `ansible.builtin.copy`, which had
no way to skip unchanged files without first wiping the destination, guaranteeing a
full multi-GB re-copy on every run. Rsync fixed that by diffing instead of wiping, but
once the copy is hardlinks instead of real data, wiping and relinking from scratch
every time is close to free regardless of content size, so there's no longer a reason
to carry rsync's incremental complexity (or its `--delete`/`--exclude` handling) just
to avoid a "full copy." `cp` has no `--exclude`, so the mirror-content copy removes
`working-dir` (`stage_mirror_content`'s own oc-mirror scratch output, never read by
`deploy_mirror_registry`'s "disk to mirror" push) as a separate task right after,
instead.

## Why this is simpler than the old `sync_mirror_to_bastion` role

That role had to run a raw `rsync` command with `delegate_to: inventory_hostname`
tricks and async-polling against a *second* host, because a single Ansible
controller used to orchestrate both the mirror-staging host and the bastion in one
playbook run. Now staging only ever acts on itself and, optionally, pushes outward —
there's no cross-host delegation, no "which side is actually local" confusion, and
no polling loop needed, since this host is the only one doing anything.

## Checksum verification

A `.sha256` file is written alongside the tar.gz (`sha256sum`, computed with `chdir`
so it records just the bare filename, not an absolute path) and carried to the
bastion the same way the tar.gz itself is — physically, for `media`, or pushed
alongside it for `rsync`. This exists because a tens-of-GB transfer over physical
media or an imperfect rsync link has no integrity check of its own: `tar -xzf` on a
truncated or corrupted archive can fail loudly, but can also partially succeed with
silently wrong content depending on where the damage lands.
`unpack_bastion_bundle` verifies the tar.gz against this checksum automatically,
before trusting anything extracted from it — see that role's README. For this to
work, don't delete the tar.gz (or its `.sha256`) until *after* the bastion's
`provision-sno.yaml` run completes — the report messages below already say this,
but it matters more now that the checksum needs to still be alongside the tar.gz
when that playbook starts, not just at copy time.

## Known gap

No live two-host transfer has been tested yet (no real bastion/staging pair
available during this restructuring) — the `rsync` path in particular is unverified
against a real run.
