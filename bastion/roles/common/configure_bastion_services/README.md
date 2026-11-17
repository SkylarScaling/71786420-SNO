# configure_bastion_services

Runs directly on the bastion (`hosts: localhost`) — the existing physical bastion.
Installs `dnsmasq` (DNS for the SNO cluster, only when `rendezvous_ip` is known),
`httpd` (serves the agent ISO for BMC virtual media boot), and whatever else this
role's own `bastion_packages` default names (`tmux`, an operator convenience, as of
this writing) — kept in sync with `staging/roles/common/stage_mirror_content`'s own
copy of the same list (role defaults aren't shared across roles), since both now
drive this by package name rather than this role just installing whatever files
happen to be found on disk.

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
dnf resolution error later. Adding a new entry to `bastion_packages` needs updating
*both* copies of that list (here and in `stage_mirror_content`) — see that role's
own README comment for the two-file-edit reasoning, same pattern as its
operator-channel pins. `bastion_required_repos` is duplicated the same way, and
needs to stay in sync for the same reason: this role loops over it by name to find
each synced repo directory and build its matching `enablerepo` list.

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

**This var must be set to the same value on both sides** — it comes from the same
flattened `bastion-resolved-vars.yaml` as every other per-environment var, so a
single override in `staging/inventory/inventory.yaml` normally keeps both roles in
sync automatically, but each role still carries its own default (role defaults
aren't shared across roles) in case it's never overridden at all. A mismatch doesn't
fail loudly on its own — this role just looks for repo metadata in the layout the
*other* method would have produced, and fails with a `repodata not found` guidance
message pointing at whichever check doesn't match what's actually on disk.

`stage_mirror_content`'s `bastion_required_repos` must already be attached to the
staging host's own subscription (just not necessarily enabled by default) for
`reposync` to sync against them — e.g.
`rhel-10-for-x86_64-baseos-rpms`/`-appstream-rpms` for a RHEL 10 staging/bastion
pair.

Staging and the bastion must be provisioned from the same RHEL major.minor, so RPMs
synced on staging install cleanly on the bastion.
