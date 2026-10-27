# package_bastion_bundle

Second step of the disconnected mirroring pipeline, after `stage_mirror_content`.
Runs on staging (`hosts: localhost`) and assembles the single artifact the bastion
needs to run its own automation: the mirrored registry content, the
`openshift-install`/`oc`/`oc-mirror`/`mirror-registry` binaries, the full `bastion/`
automation tree (playbooks + roles), and a flattened resolved-vars file generated
from `staging/inventory/inventory.yaml`. One `tar.gz`, physically carried to the
bastion by default.

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
| `bastion_transfer_host`/`bastion_transfer_user`/`bastion_transfer_ssh_key`/`bastion_transfer_dest_dir` | unset / `root` / `{{ ssh_private_key }}` / `/root` | Only used when `bastion_transfer_method: rsync`. |

## Why this is simpler than the old `sync_mirror_to_bastion` role

That role had to run a raw `rsync` command with `delegate_to: inventory_hostname`
tricks and async-polling against a *second* host, because a single Ansible
controller used to orchestrate both the mirror-staging host and the bastion in one
playbook run. Now staging only ever acts on itself and, optionally, pushes outward —
there's no cross-host delegation, no "which side is actually local" confusion, and
no polling loop needed, since this host is the only one doing anything.

## Known gap

No live two-host transfer has been tested yet (no real bastion/staging pair
available during this restructuring) — the `rsync` path in particular is unverified
against a real run.
