# unpack_bastion_rpms_bundle

Bastion-side counterpart of staging's `package_bastion_rpms_bundle` — extracts the
separately-shipped `sno-bastion-rpms-{{ cluster_name }}.tar.gz` into
`mirror_installers_dir/bastion-rpms`, verifying it against its shipped `.sha256`
first (same pattern as `unpack_bastion_bundle`'s main-bundle verification).

## Why this is a separate role/playbook

Added 2026-11-17 alongside staging's `sync_bastion_rpms`/`package_bastion_rpms_bundle`
split: the bastion's RPM content can now be refreshed independently of the main
mirror bundle (which carries the much larger mirrored container content). This role
lets that refresh happen on the bastion side independently too, via
`bastion/playbooks/unpack-bastion-rpms.yaml`, without re-running
`provision-sno.yaml`/`unpack_bastion_bundle`.

**Prerequisite**: the main bundle must have been unpacked at least once already
(`unpack_bastion_bundle`) — this role only refreshes `bastion-rpms/`, it doesn't lay
down `bastion/group_vars/all.yaml` or anything else the rest of the automation needs.

## Removes stale content before extracting

Unlike `unarchive`'s default add/overwrite behavior, this role deletes any existing
`mirror_installers_dir/bastion-rpms` before extracting the refreshed bundle — so an
RPM dropped from `bastion_required_repos` since the last sync (which
`sync_bastion_rpms`'s `reposync --delete` already prunes on the staging side) doesn't
linger here too.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `bastion_rpms_bundle_name` | `sno-bastion-rpms-{{ cluster_name }}.tar.gz` | Same variable name (and default) as `package_bastion_rpms_bundle`'s own — must match so this role finds the right `.sha256` file. |
| `bastion_rpms_bundle_tarball_path` | `~/{{ bastion_rpms_bundle_name }}` | Where the operator copied the staging-produced tar.gz. Set to `''` to skip checksum verification. |
| `mirror_installers_dir` | `/opt/mirror-installers` | Must match `configure_bastion_services`/`deploy_mirror_registry`/`unpack_bastion_bundle`'s own default. |

## Known gap

No live two-host transfer has been tested yet, same as `unpack_bastion_bundle`'s own
known gap.
