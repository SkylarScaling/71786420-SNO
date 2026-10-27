# aws_provision_bastion

Provisions the EC2 stand-in for the target single bastion, in the private
(route-less) subnet created by `aws_provision_network` — it has no public IP and no
path to the internet, matching the disconnected bare-metal bastion (see
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md#2-disconnected-content-mirroring)).

Since it's unreachable directly, Ansible connects to it by proxying SSH through the
mirror-staging host's public IP (`aws_provision_mirror_staging_host` must run first —
`mirror_staging_public_ip` and `mirror_staging_security_group_id` are consumed here).
This requires:

- The bastion's security group allows SSH from the mirror-staging host's security
  group, not from the internet — auto-created here (unless `bastion_security_groups`
  is set explicitly) with an ingress rule scoped to
  `mirror_staging_security_group_id`, not a CIDR.
- The same SSH key pair (`aws_key_pair`) is usable from the staging host — i.e. the
  automation controller's key is what's loaded, not a key only present on the
  controller and nowhere else in the chain.

That same security group also opens `mirror_registry_quay_port` (8443) to the whole
VPC CIDR (`sno_vpc_cidr`, from `aws_provision_network`) — the SNO master and the IPI
bootstrap instance both need to pull release/operator images from the bastion's
mirror registry, and without this rule bootstrapping hangs until its 45-minute
timeout with no route to the registry at all (confirmed against a real run). It's
scoped to the whole VPC, not just the private subnet, because `openshift-install`
places the bootstrap instance in the public subnet (see
`generate_install_config`'s `publish: External` comment) even though the master
itself stays in the private subnet alongside this bastion.
