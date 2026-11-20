# configure_bastion_services

## tl;dr

Installs `dnsmasq`/`httpd`/etc. on the bastion from the synced local RPM repo, and
opens firewalld for HTTP/DNS.

### To use this correctly:

- `bastion_rpm_sync_method`/`bastion_packages`/`bastion_required_repos` are pinned
  once in `staging/inventory/inventory.yaml` (single source, shared with
  `sync_bastion_rpms` — no more keeping two copies in sync by hand).
- Set `debug_vars: true` (inventory.yaml) to print the RPM/ISO-serving vars in
  effect before this role's tasks run.

## Full Details:

Runs directly on the bastion (`hosts: localhost`) — the existing physical bastion.
Installs `dnsmasq` (DNS for the SNO cluster, only when `rendezvous_ip` is known),
`httpd` (serves the agent ISO for BMC virtual media boot — also opens firewalld for
HTTP, without which the BMC can't reach it at all), and whatever else
`bastion_packages` (`staging/inventory/inventory.yaml`, single source shared with
`sync_bastion_rpms`) names — driven by package name rather than this role just
installing whatever files happen to be found on disk.

## Why the packages come from synced local repos, not `dnf install`

The bastion has no internet route at all — a plain `package:`/`dnf install dnsmasq
httpd` here fails since there's no repo it can reach. `dnsmasq`/`httpd`/etc. aren't
container images, so they're outside `oc-mirror`'s content-mirroring pipeline
entirely — instead, `staging/roles/common/stage_mirror_content` mirrors each of
`bastion_required_repos` **wholesale** via `reposync` (every RPM in each repo, not
just `bastion_packages`' own dependency closure — a deliberate customer choice, see
that role's README for why a narrower `dnf download --resolve` approach proved
unreliable) on the internet-connected staging host, into one subdirectory per repoid
under `{{ mirror_installers_dir }}/bastion-rpms`, each already a real repo
(`reposync --download-metadata` carries over the actual upstream `repodata/`
directly — no `createrepo_c` step needed). `package_bastion_bundle` (staging) /
`unpack_bastion_bundle` (bastion) carry the whole directory tree over inside the
bundle, the same way they carry the `oc-mirror`/`mirror-registry` tarballs.

This role installs by package name against each synced repo's own metadata (one
`yum_repository` entry per repoid, named `bastion-local-<repoid>`, all enabled
together with `disablerepo: '*'` so dnf never attempts a network repo lookup at
all), not by handing dnf a raw list of RPM file paths — an earlier version of this
role did exactly that (`find` + `dnf: name: <file list>`), but that's unreliable:
confirmed against a real customer environment, dnf's solver only considers exactly
the files named on the command line, with none of the repo metadata it normally
uses to work out a correct transaction across a larger closure. Fails fast with
guidance if any `bastion-rpms/<repoid>/repodata` isn't present (e.g. an older bundle
built before `stage_mirror_content` switched to `reposync`), rather than a confusing
dnf resolution error later. `bastion_packages`/`bastion_required_repos` are both
pinned once in `staging/inventory/inventory.yaml` — this role loops over
`bastion_required_repos` by name to find each synced repo directory and build its
matching `enablerepo` list.

## `bastion_rpm_sync_method`: `reposync` (default) vs `resolve`

`stage_mirror_content` can populate `bastion-rpms/` one of two ways, and this role
has to know which, since the two produce different on-disk layouts:

- **`reposync`** (default): one subdirectory per repoid under `bastion-rpms/`, each
  already a real repo. This role enables one `yum_repository` per entry in
  `bastion_required_repos`, named `bastion-local-<repoid>`.
- **`resolve`** (opt-in): a single flat `bastion-rpms/` directory (the original,
  narrower `dnf download --resolve` approach — see `stage_mirror_content`'s README
  for why `reposync` became the default). This role enables exactly one
  `yum_repository`, `bastion-local-rpms`.

`bastion_rpm_sync_method` is pinned once in `staging/inventory/inventory.yaml` and
reaches both this role and `sync_bastion_rpms` via the same flattened
`bastion-resolved-vars.yaml` — the two can no longer drift apart. If the on-disk
layout still doesn't match what this role expects (e.g. an older bundle built before
`sync_bastion_rpms` switched to `reposync`), it fails with a `repodata not found`
guidance message rather than a confusing dnf resolution error.

`bastion_required_repos` must already be attached to the staging host's own
subscription (just not necessarily enabled by default) for `reposync` to sync against
them — e.g.
`rhel-10-for-x86_64-baseos-rpms`/`-appstream-rpms` for a RHEL 10 staging/bastion
pair.

Staging and the bastion must be provisioned from the same RHEL major.minor, so RPMs
synced on staging install cleanly on the bastion.
