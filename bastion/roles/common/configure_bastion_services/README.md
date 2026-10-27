# configure_bastion_services

Runs directly on the bastion (`hosts: localhost`) — the existing physical bastion.
Installs `dnsmasq` (DNS for the SNO cluster, only when `sno_node_ip` is known) and
`httpd` (serves the agent ISO for BMC virtual media boot).

## Why the packages come from a synced local directory, not `dnf install`

The bastion has no internet route at all — a plain `package:`/`dnf install dnsmasq
httpd` here fails since there's no repo it can reach. `dnsmasq`/`httpd` aren't
container images, so they're outside `oc-mirror`'s content-mirroring pipeline
entirely — instead, `staging/roles/common/stage_mirror_content` downloads them (and
their full dependency closure, via `dnf install --downloadonly --downloaddir=...`,
not just the two named packages) on the internet-connected staging host into
`{{ mirror_installers_dir }}/bastion-rpms`, and `package_bastion_bundle` (staging) /
`unpack_bastion_bundle` (bastion) carry that whole directory over inside the bundle,
the same way they carry the `oc-mirror`/`mirror-registry` tarballs. This role then
installs from that local copy with `disablerepo: '*'`, so dnf never attempts a
network repo lookup at all.

`find` is what discovers the unpacked RPM files on this host's own filesystem —
both this role and `stage_mirror_content` now run directly on their own respective
hosts (no cross-host delegation involved).

Staging and the bastion must be provisioned from the same RHEL major.minor, so RPMs
resolved on staging install cleanly on the bastion.
