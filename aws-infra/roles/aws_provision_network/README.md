# aws_provision_network

Builds the VPC that makes the AWS test path genuinely disconnected, mirroring the
bare-metal bastion/isolated-network pattern rather than approximating it (see
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md#2-disconnected-content-mirroring)).

- **Public subnet**: internet gateway route, used by the mirror-staging host
  (`aws_provision_mirror_staging_host`) and — since `generate_install_config` sets
  `publish: External` — by the installer for placing the cluster's external
  API/ingress load balancers. Both this subnet and the private one are listed in
  `install-config.yaml`'s `platform.aws.vpc.subnets`; `openshift-install` classifies
  each by its own route table (IGW route present → public), so nothing here needs to
  be explicitly tagged as the cluster's public subnet.
- **Private subnet**: deliberately has no default route at all — no internet gateway,
  no NAT gateway. The bastion and the SNO node both live here and have no path to the
  public internet. `machine_network_cidr` is reused as this subnet's CIDR so
  `generate_install_config` and this role always agree on the network.
- **VPC endpoints**: `s3` (gateway) and `ec2`/`elasticloadbalancing`/`sts` (interface)
  are attached to the private route table so the installer and the AWS cloud provider
  running on the nodes can still reach the AWS control plane APIs they need, without
  needing general internet egress.

## Why the installer itself still needs internet access

"Disconnected" here means the **cluster nodes** can't reach the internet — not that
`openshift-install`/Ansible have to run air-gapped too. The installer process runs
from wherever this automation executes (normal AWS API access over the internet, same
as any AWS automation); only the EC2 instances it creates land in the route-less
private subnet. The same applies after install: `publish: External` (see
`generate_install_config`) keeps the controller able to reach the cluster's API and
ingress directly, without giving the SNO node itself any outbound route — it's purely
about the controller being outside the VPC, not about relaxing node egress.

## Reaching the private bastion

Since the private subnet has no internet route, a public IP on the bastion wouldn't
even be reachable. The operator reaches it by proxying SSH through the mirror-staging
host (same VPC, private-IP-to-private-IP routing needs no internet) — see
`aws_provision_bastion`'s README for the exact command; `aws-infra/` only provisions
the hosts, it doesn't configure any automated cross-host access itself.
