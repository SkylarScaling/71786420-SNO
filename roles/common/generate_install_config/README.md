# generate_install_config

Renders `install-config.yaml` for whichever `infra_provider` is active. Every install
is treated as disconnected (see
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md#2-disconnected-content-mirroring))
— there's no connected/non-mirrored code path. `imageContentSources` and
`additionalTrustBundle` always point at the mirror registry deployed on the bastion by
`deploy_mirror_registry`, which must run before this role (it sets the
`mirror_registry_ca_cert` and `mirror_registry_auth_b64` facts this role requires).

`pullSecret` is **not** the raw `pull_secret` var — this role merges in an `auths`
entry for the mirror registry (keyed `mirror_registry_quay_hostname:
mirror_registry_quay_port`, value `mirror_registry_auth_b64`) before rendering.
Without it, `openshift-install`'s own "Mirror registry ... is not found in
pullSecret" warning is fatal in practice: nothing on the node (kubelet, crio,
machine-config-daemon-pull) can authenticate to pull release/operator images from
there, and it manifests as bootstrapping silently timing out after 45 minutes rather
than a clear auth error (confirmed against a real run). This applies identically on
both providers — same mirror registry either way.

## Provider differences

Only the `platform:`/`controlPlane.platform:` blocks differ:

- `aws`: `platform.aws.vpc.subnets` lists both pre-created subnets from
  `aws_provision_network` (private = control plane/machine network, no NAT; public =
  external API/ingress load balancer placement); `publish: External` lets this repo's
  Ansible controller, which runs outside AWS entirely, actually reach the resulting
  cluster — `Internal` would create a VPC-private-only Route53 zone the controller
  can never resolve. See `docs/aws-test-environment-architecture.md` §2 for why this
  doesn't compromise the SNO node's own "no internet route" guarantee.
- `baremetal`: `platform.none: {}`, consistent with the Agent-Based Installer.

AWS also sets `credentialsMode: Manual` (no equivalent on bare metal — `platform:
none` has no cloud-credential-operator concept at all). The default "Mint" mode has
cloud-credential-operator call `iam.amazonaws.com` directly from inside the cluster to
create IAM users at runtime — confirmed against a real run, this fails identically for
every CredentialsRequest with an i/o timeout, since the node has no internet route and
IAM has no VPC endpoint (unlike EC2/S3/ELB/STS). `roles/aws/
aws_configure_manual_credentials` (run from `aws_provision_sno_ipi`, after this role)
provisions ccoctl-issued STS/OIDC roles instead as extra manifests before `create
cluster` runs — see that role's README for the full mechanism, including why it alone
doesn't fix the ingress-operator's separate Route53 DNS failure (`roles/aws/
aws_configure_manual_dns` handles that).

Everything else — networking CIDRs, pull secret, SSH key, mirror directives — is
identical.
