# configure_bastion_services

Runs against the `bastion` group — the existing physical bastion. Installs `dnsmasq`
(DNS for the SNO cluster, only when `sno_node_ip` is known) and `httpd` (serves the
agent ISO for BMC virtual media boot).

## Why the packages come from a synced local directory, not `dnf install`

The bastion has no internet route at all — a plain `package:`/`dnf install dnsmasq
httpd` here fails since there's no repo it can reach. `dnsmasq`/`httpd` aren't
container images, so they're outside `oc-mirror`'s content-mirroring pipeline
entirely — instead, `roles/common/stage_mirror_content` downloads them (and their
full dependency closure, via `dnf install --downloadonly --downloaddir=...`, not just
the two named packages) on the internet-connected mirror-staging host into
`{{ mirror_installers_dir }}/bastion-rpms`, and `sync_mirror_to_bastion` carries that
whole directory over the same way it carries the `oc-mirror`/`mirror-registry`
tarballs. This role then installs from that local copy with `disablerepo: '*'`, so
dnf never attempts a network repo lookup at all.

`find` (not `lookup('fileglob', ...)`) is what discovers the synced RPM files — a
fileglob lookup would run on the Ansible controller's own filesystem, not the bastion,
and silently find nothing there.

Both the mirror-staging host and the bastion are provisioned from the same RHEL
major.minor (see `rhel_ami_name_filter` in `aws_provision_mirror_staging_host`/
`aws_provision_bastion`'s defaults on AWS; whatever RHEL version both hosts are
provisioned with on bare metal), so RPMs resolved on one install cleanly on the other.
