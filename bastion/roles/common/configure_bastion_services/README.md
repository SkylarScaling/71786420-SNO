# configure_bastion_services

Runs directly on the bastion (`hosts: localhost`) — the existing physical bastion.
Installs `dnsmasq` (DNS for the SNO cluster, only when `rendezvous_ip` is known),
`httpd` (serves the agent ISO for BMC virtual media boot), and whatever else
`staging/roles/common/stage_mirror_content`'s `bastion_packages` list names (`tmux`,
an operator convenience, as of this writing) — this role itself doesn't hardcode
package names at all; see below.

## Why the packages come from a synced local directory, not `dnf install`

The bastion has no internet route at all — a plain `package:`/`dnf install dnsmasq
httpd` here fails since there's no repo it can reach. `dnsmasq`/`httpd`/etc. aren't
container images, so they're outside `oc-mirror`'s content-mirroring pipeline
entirely — instead, `staging/roles/common/stage_mirror_content` downloads them (and
their full dependency closure, via `dnf download --resolve --destdir=...`, not just
the named packages themselves — see that role's own comments for why `dnf install
--downloadonly` doesn't work for this) on the internet-connected staging host into
`{{ mirror_installers_dir }}/bastion-rpms`, and `package_bastion_bundle` (staging) /
`unpack_bastion_bundle` (bastion) carry that whole directory over inside the bundle,
the same way they carry the `oc-mirror`/`mirror-registry` tarballs. This role then
installs *everything found* under that local directory (`find` + `dnf: name: <file
list>`) with `disablerepo: '*'`, so dnf never attempts a network repo lookup at all —
adding a new entry to `bastion_packages` needs no change here.

`stage_mirror_content`'s `bastion_required_repos` must already be attached to the
staging host's own subscription (just not necessarily enabled by default) for `dnf
download` to resolve packages against them — e.g. `rhel-10-for-x86_64-baseos-rpms`/
`-appstream-rpms` for a RHEL 10 staging/bastion pair.

`find` is what discovers the unpacked RPM files on this host's own filesystem —
both this role and `stage_mirror_content` now run directly on their own respective
hosts (no cross-host delegation involved).

Staging and the bastion must be provisioned from the same RHEL major.minor, so RPMs
resolved on staging install cleanly on the bastion.
