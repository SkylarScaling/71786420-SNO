# aws_provision_bastion

Provisions the EC2 stand-in for the target single bastion, in the private
(route-less) subnet created by `aws_provision_network` — it has no public IP and no
path to the internet, matching the disconnected bare-metal bastion (see
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md#2-disconnected-content-mirroring)).

Unlike `main`'s original version of this role, it does **not** add the instance to
any in-memory Ansible inventory or configure anything to run against it in this same
play — this tree (`aws-infra/`) only provisions hosts, it doesn't orchestrate them.
Once this role finishes, the operator reaches the bastion over SSH themselves,
proxied through the mirror-staging host's public IP (the bastion has no public IP of
its own — this requires the same SSH key pair, `aws_key_pair`, to be usable from the
mirror-staging host too, not just wherever `aws-infra/` itself was run from):

```
ssh -i <ssh_private_key> \
  -o ProxyCommand="ssh -i <ssh_private_key> -W %h:%p -q <bastion_ssh_user>@<mirror_staging_public_ip>" \
  <bastion_ssh_user>@<bastion_private_ip>
```

`aws-infra/playbooks/provision-hosts.yaml` prints both addresses (and this exact
command) at the end of its run.

This role's security group opens `mirror_registry_quay_port` (8443, from the
repo-root `shared-defaults.yaml` — see that file's header comment) to the whole VPC
CIDR (`sno_vpc_cidr`, from `aws_provision_network`) — the SNO master and the IPI
bootstrap instance both need to pull release/operator images from the bastion's
mirror registry, and without this rule bootstrapping hangs until its 45-minute
timeout with no route to the registry at all (confirmed against a real run). It's
scoped to the whole VPC, not just the private subnet, because `openshift-install`
places the bootstrap instance in the public subnet (see
`bastion/roles/common/generate_install_config`'s `publish: External` comment) even
though the master itself stays in the private subnet alongside this bastion.

## DNS

Also creates a private Route53 hosted zone for `base_domain`, associated with the
VPC, with an `A` record pointing `mirror.{{ base_domain }}` at the bastion's private
IP — the hostname `deploy_mirror_registry`/`generate_install_config` always use for
the mirror registry, on both providers. See the in-task comment for why this
coexists with `openshift-install`'s own separate `{{ cluster_name }}.{{ base_domain }}`
zone without conflict.
