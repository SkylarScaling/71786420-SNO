# configure_bastion_services

Runs directly on the bastion (`hosts: localhost`) — the existing physical bastion.
Installs `dnsmasq` (DNS for the SNO cluster, only when `rendezvous_ip` is known),
`httpd` (serves the agent ISO for BMC virtual media boot), and whatever else this
role's own `bastion_packages` default names (`tmux`, an operator convenience, as of
this writing) — kept in sync with `staging/roles/common/stage_mirror_content`'s own
copy of the same list (role defaults aren't shared across roles), since both now
drive this by package name rather than this role just installing whatever files
happen to be found on disk.

## Why the packages come from a synced local repo, not `dnf install`

The bastion has no internet route at all — a plain `package:`/`dnf install dnsmasq
httpd` here fails since there's no repo it can reach. `dnsmasq`/`httpd`/etc. aren't
container images, so they're outside `oc-mirror`'s content-mirroring pipeline
entirely — instead, `staging/roles/common/stage_mirror_content` downloads them (and
their full dependency closure, via `dnf download --resolve --destdir=...`, not just
the named packages themselves — see that role's own comments for why `dnf install
--downloadonly` doesn't work for this) on the internet-connected staging host into
`{{ mirror_installers_dir }}/bastion-rpms`, then runs `createrepo_c` against that
directory so it's a real (local-only) dnf repo, not just a pile of RPM files.
`package_bastion_bundle` (staging) / `unpack_bastion_bundle` (bastion) carry the
whole directory — RPMs and `repodata/` together — over inside the bundle, the same
way they carry the `oc-mirror`/`mirror-registry` tarballs.

This role installs by package name against that local repo's own metadata
(`enablerepo: bastion-local-rpms` + `disablerepo: '*'`, so dnf never attempts a
network repo lookup at all), not by handing dnf a raw list of RPM file paths — an
earlier version of this role did exactly that (`find` + `dnf: name: <file list>`),
but that's unreliable: confirmed against a real customer environment, dnf's solver
only considers exactly the files named on the command line, with none of the repo
metadata it normally uses to work out a correct transaction across a larger closure.
Fails fast with guidance if `bastion-rpms/repodata` isn't present (e.g. an older
bundle built before `stage_mirror_content` started running `createrepo_c`), rather
than a confusing dnf resolution error later. Adding a new entry to `bastion_packages`
needs updating *both* copies of the list (here and in `stage_mirror_content`) — see
that role's own README comment for the two-file-edit reasoning, same pattern as its
operator-channel pins.

`stage_mirror_content`'s `bastion_required_repos` must already be attached to the
staging host's own subscription (just not necessarily enabled by default) for `dnf
download`/`createrepo_c`'s own install to resolve packages against them — e.g.
`rhel-10-for-x86_64-baseos-rpms`/`-appstream-rpms` for a RHEL 10 staging/bastion
pair.

Staging and the bastion must be provisioned from the same RHEL major.minor, so RPMs
resolved on staging install cleanly on the bastion.
