# unpack_bastion_bundle

First task in `bastion/playbooks/provision-sno.yaml` — the bastion-side counterpart
of staging's `package_bastion_bundle`. Lays down what the bundle carried: mirrored
registry content into `mirror_archive_dir`, the installer tarballs/RPMs into
`mirror_installers_dir`, `openshift-install`/`oc` into `bin_dir`, and the flattened
per-environment vars into `bastion/playbooks/group_vars/all.yaml` (read by every
other playbook in this tree via Ansible's normal `group_vars` auto-load).

`oc-mirror`/`mirror-registry` are **not** extracted here — `deploy_mirror_registry`
already extracts those itself directly from `mirror_installers_dir` (unchanged
behavior from before the split).

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `bastion_bundle_dir` | `~/sno-deploy` | Where the staging-produced tar.gz was extracted on this host. Must contain `bastion-resolved-vars.yaml`, `mirror-content/`, and `mirror-installers/` at its root. |
| `bin_dir` | `~/.local/bin` | Same convention used by every other role in this repo that manages its own binaries. |
| `mirror_archive_dir` | `/opt/mirror-content/archive` | Same variable name (and default) as `deploy_mirror_registry`'s — must match since that's how this role's output reaches that role's input. |
| `mirror_installers_dir` | `/opt/mirror-installers` | Must match `deploy_mirror_registry`/`configure_bastion_services`'s own default. |

## Prerequisite

Extract the tar.gz `package_bastion_bundle` produced on staging into
`bastion_bundle_dir` *before* running this role — this role only lays out what's
already there, it doesn't itself handle the physical-media or rsync transfer step
(that's staging's job).

## Known gap

No live two-host transfer/unpack has been tested yet (no real bastion/staging pair
available during this restructuring).
