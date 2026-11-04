# generate_install_config

Renders `install-config.yaml` for the Agent-Based Installer. Every install is treated
as disconnected (see
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
than a clear auth error (confirmed against a real run).

`platform: none`, consistent with the Agent-Based Installer — there's no cloud
platform integration on bare metal.

`additionalNTPSources` is set from `ntp_server` when defined (customer-provided NTP
server, per `staging/inventory/inventory.yaml`).

## AWS

When `infra_provider: aws`, this template also renders a `platform.aws` stanza
(`aws_sno_instance_type`, defaulted here; `aws_region`/`sno_vpc_id`/
`sno_private_subnet_id`/`sno_public_subnet_id`/`sno_public_subnet_cidr`, genuinely
per-environment — set in `staging/inventory/inventory.yaml` from
`aws-infra/playbooks/provision-hosts.yaml`'s output), `publish: External`, and
`credentialsMode: Manual`. See the template's own comments for why — in short,
cluster creation runs from `staging` (the internet-connected host in this split, not
a host inside the VPC), so the API/ingress load balancers must be externally
reachable, and Mint-mode credentials can't work from a node with no internet route to
IAM. `staging/roles/aws/aws_configure_manual_credentials`/`aws_configure_manual_dns`
do the rest of the Manual-mode/DNS work; this role only sets the two install-config
fields that require them.
