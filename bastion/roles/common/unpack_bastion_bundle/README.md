# unpack_bastion_bundle

First task in `bastion/playbooks/provision-sno.yaml` — the bastion-side counterpart
of staging's `package_bastion_bundle`. Lays down what the bundle carried: mirrored
registry content into `mirror_archive_dir`, the installer tarballs/RPMs into
`mirror_installers_dir`, the release-content oc-mirror cache handoff into
`oc_mirror_cache_dir` (see below), `openshift-install`/`oc` into `bin_dir`, the
flattened per-environment vars into `bastion/playbooks/group_vars/all.yaml` (read by
every other playbook in this tree via Ansible's normal `group_vars` auto-load), and
the relay key into the path that same vars file's `ssh_private_key` points at (see
below).

`oc-mirror`/`mirror-registry` are **not** extracted here — `deploy_mirror_registry`
already extracts those itself directly from `mirror_installers_dir` (unchanged
behavior from before the split).

### Why the release-content cache handoff exists

oc-mirror v2's exported archive doesn't carry the actual manifest/config/layer blob
content for the `openshift/release` repo's per-component synthetic tags (e.g.
`openshift/release:4.22.17-x86_64-cluster-kube-apiserver-operator`) — only the
lightweight tag/revision pointer files. Confirmed live: without this content already
present in `deploy_mirror_registry`'s `--cache-dir`, its disk-to-mirror step fails
immediately with `manifest unknown` on the first release-component image, since a
fresh cache-dir (all a separate bastion machine can ever have) can't reconstruct that
content from the archive alone. `stage_mirror_content`'s "Build the release-content
cache handoff" task computes the minimal blob subset needed (confirmed ~20GiB vs the
full ~60GiB cache in a real run) and `package_bastion_bundle` carries it here as
`release-cache/`, laid out identically to oc-mirror's own
`.oc-mirror/.cache/docker/registry/v2/...` cache structure so it drops straight into
`oc_mirror_cache_dir` with no path translation.

### Why the relay key exists

The bastion needs its own copy of the operator's private key for the one
return-trip rsync push it can originate — `package_staging_bundle`'s backup-export
relay. Unlike the `bastion_transfer_*` push, which runs **from** staging (where this
key already lives on disk), that one runs the other direction.
`package_bastion_bundle` ships the actual key file into the bundle root as
`relay-key`; this role copies it to the fixed path `bastion-resolved-vars.yaml`'s
`ssh_private_key` points at (`~/.ssh/relay_key`) so `package_staging_bundle`'s own
`staging_transfer_ssh_key: "{{ ssh_private_key }}"` default resolves to a real file
without that role needing to know this handoff exists. Not stat-gated/cleaned up
like mirror-content/mirror-installers/release-cache below — it's a single small
file, no disk-usage concern.

The mirror content/installer copies use `ansible.posix.synchronize` (rsync), not
`copy` — the mirror content archive alone is tens of GB, and `copy`'s per-file
checksum comparison means every re-run re-hashes the entire tree just to find nothing
changed. rsync only transfers what's missing or different, so retrying after a
partial/interrupted copy (e.g. the disk-full failure mode below) resumes cheaply
instead of re-verifying everything from scratch.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `bastion_bundle_dir` | `~/sno-deploy` | Where the staging-produced tar.gz was extracted on this host. Must contain `bastion-resolved-vars.yaml`, `mirror-content/`, and `mirror-installers/` at its root. `release-cache/`/`relay-key` are also expected but not fatal if missing. |
| `bin_dir` | `~/.local/bin` | Same convention used by every other role in this repo that manages its own binaries. |
| `mirror_archive_dir` | `/opt/mirror-content/archive` | Same variable name (and default) as `deploy_mirror_registry`'s — must match since that's how this role's output reaches that role's input. |
| `mirror_installers_dir` | `/opt/mirror-installers` | Must match `deploy_mirror_registry`/`configure_bastion_services`'s own default. |
| `mirror_registry_install_dir` | `/opt/mirror-registry` | Same variable name (and default) as `deploy_mirror_registry`'s — only exists here to derive `oc_mirror_cache_dir` below the same way that role does. Override this (not `oc_mirror_cache_dir` directly) if you need to move the install off `/opt`, e.g. onto a bigger volume. |
| `oc_mirror_cache_dir` | `{{ mirror_registry_install_dir }}/oc-mirror-cache` | Must match `deploy_mirror_registry`'s own resolved value — this is where the release-content cache handoff lands, and `deploy_mirror_registry`'s disk-to-mirror push reads `--cache-dir` from the same path. Derived from `mirror_registry_install_dir` specifically so a single override of that var keeps both roles pointed at the same directory — confirmed live as a real failure mode when this used to be an independent literal: overriding only `mirror_registry_install_dir` left this role writing the handoff to the old path while the push read from the new one, reproducing the "manifest unknown" failure the handoff exists to prevent (see `deploy_mirror_registry`/`stage_mirror_content` READMEs). |

**If you're changing `mirror_registry_install_dir`/`oc_mirror_cache_dir` on a bastion
that's already run this role once**, do it *before* that first run, or be aware the
fix alone isn't enough afterward: this role unconditionally deletes
`bastion_bundle_dir/release-cache` (and `mirror-content`/`mirror-installers`) once
it's copied into place (see "Remove the now-redundant..." in `tasks/main.yaml`), on
the assumption the copy landed somewhere this role will keep reading from. If an
earlier run already merged the handoff into a now-stale path and deleted the source,
simply re-running with the corrected var does nothing — the stat guarding the copy
finds no source left in `bastion_bundle_dir` and skips it, leaving the new path
empty. Confirmed live exactly this way during the `mirror_registry_install_dir`
move to a bigger volume: the content wasn't lost, just stranded at the old resolved
`oc_mirror_cache_dir` path from the first run — `rsync -a <old
oc_mirror_cache_dir>/ <new oc_mirror_cache_dir>/` recovers it without re-extracting
the bundle from scratch.

## Prerequisite

Extract the tar.gz `package_bastion_bundle` produced on staging into
`bastion_bundle_dir` *before* running this role — this role only lays out what's
already there, it doesn't itself handle the physical-media or rsync transfer step
(that's staging's job).

## Known gap

No live two-host transfer/unpack has been tested yet (no real bastion/staging pair
available during this restructuring).
