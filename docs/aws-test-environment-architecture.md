# AWS Test Environment Architecture

**Status: living document — maintain alongside the automation.** Whenever a role,
playbook, or variable referenced here changes, update this doc in the same change.

This document describes the **AWS test loop** (`infra_provider: aws`) — an
internal proving ground that validates most of the feature set described in
[`bare-metal-architecture.md`](bare-metal-architecture.md) before it's run against
real customer hardware. **It is not the customer deliverable.** Everything about the
day-2 feature set (storage, logging, backup/DR design, Day 2 middleware, networking
intent, requirements traceability) lives in `bare-metal-architecture.md` and isn't
repeated here — this document covers only what's different about running the same
roles against AWS infrastructure instead of bare metal, so it references that
document throughout rather than duplicating it. `bare-metal-architecture.md` has no
dependency in the other direction — it can be read and used entirely on its own.

See [`architectural-decisions.md`](architectural-decisions.md) for the rationale
behind testing everything in a fully-disconnected mode on AWS too, rather than taking
a connected shortcut.

## 1. Why AWS, and what it does and doesn't prove

Bare-metal hardware isn't always available up front, so this repo keeps all
infrastructure *provisioning* behind a swappable `infra_provider: aws | baremetal`
layer. Everything from "cluster is up" onward — storage, backup/DR, logging,
tracing, Day 2 middleware, upgrades, node-failure drills — is written once in
`roles/common/*` and `roles/ocp/*` and run unmodified against whichever provider is
active. Validating a feature here means it's already proven against the shared code
path the bare-metal rollout will also use; only the provisioning layer itself
(`roles/aws/*` vs `roles/baremetal/*`) differs.

What AWS does **not** prove: anything bare-metal-specific — BMC/Redfish provisioning
or real single-switch cabling constraints. See `bare-metal-architecture.md` §10 for
those.

## 2. AWS mapping of the two-host topology

`bare-metal-architecture.md` §2 describes the topology this repo always builds:
mirror-staging host → bastion → SNO node, with the bastion and SNO node having no
internet route at all. On AWS, that topology maps onto real AWS infrastructure
rather than being simulated:

| Topology role | AWS implementation (`roles/aws/*`) |
|---|---|
| Mirror-staging host | Ephemeral EC2 instance, public subnet, real internet route |
| Bastion | EC2 instance, private subnet, **no NAT/IGW at all** |
| SNO node | The IPI control-plane instance (zero workers), same private subnet as the bastion |

`roles/aws/aws_provision_network` builds a VPC with a public subnet used *only* by
the mirror-staging host, and a private subnet (reused as the cluster's machine
network) with no internet gateway or NAT route at all for the bastion or the SNO
node. VPC endpoints (`s3`, `ec2`, `elasticloadbalancing`, `sts`) give the installer
and the in-cluster AWS cloud provider the AWS API access they need without any
internet route. The automation controller itself (wherever `openshift-install`/
Ansible run) still has normal internet access — only the EC2 instances it creates
are isolated. See `architectural-decisions.md` §2 for the full disconnected-mirroring
rationale this environment is built to exercise.

`install-config.yaml`'s `platform.aws.vpc.subnets` lists **both** subnets —
`openshift-install` validates that every subnet in an existing, multi-subnet VPC is
either listed there or tagged `kubernetes.io/cluster/unmanaged` (confirmed against a
real run: "additional subnets [...] without tag prefix kubernetes.io/cluster/ are
found"), and classifies each listed subnet as public/private from its own route table
(IGW route present → public). The private subnet gets the control-plane instance; the
public subnet gets the external API/ingress load balancers (see `publish: External`
below) — `aws_provision_network` doesn't need to tag the public subnet at all, since
it's explicitly provided rather than left out. Every subnet listed under
`platform.aws.vpc.subnets` must also fall inside `networking.machineNetwork`
(confirmed against a real run: "subnet's CIDR range start ... is outside of the
specified machine networks"), so `install-config.yaml.j2` adds a second
`machineNetwork` entry for the public subnet's own CIDR (`sno_public_subnet_cidr`,
exposed by `aws_provision_network`) alongside the shared `machine_network_cidr` —
`machine_network_cidr` itself stays untouched so its "identical across providers"
meaning for bare metal's single-subnet LAN isn't disturbed. This requirement is
specific to installing into an existing VPC and doesn't apply on bare metal
(`platform: none`), so none of this is in `bare-metal-architecture.md`.

**`publish: External`, not `Internal`**: this repo's Ansible controller runs outside
AWS entirely, so it can't resolve or reach a VPC-private Route53 zone to run `create
cluster` or any later `oc`/`kubernetes.core` call against the cluster (confirmed
against a real run — `publish: Internal` produced a private-only hosted zone, and the
controller got `dial tcp: lookup api.<cluster>.<base_domain> ... no such host`).
`External` makes the API/ingress load balancers internet-reachable (still TLS/auth
gated) so the controller can reach them directly — it does **not** give the SNO node
itself any outbound internet route (the private subnet's route table is unchanged), so
the node-egress half of the "always fully disconnected" guarantee in `CLAUDE.md` holds
exactly as before, and operator/cluster-update image pulls still go through
`imageContentSources` to the bastion's mirror registry either way. This is purely an
AWS-test-loop concession (to keep this install-and-manage-from-your-laptop test loop
simple, closer to how the bare-metal path is driven) — bare metal's `platform: none`
has no publish/Route53 concept and is unaffected.

The mirror-staging host and bastion share one VPC, so they have direct private-IP
reachability to each other without needing any proxy — the only host that needs a
proxy hop is the Ansible controller itself when it connects to the bastion (no
internet route), tunneled through the mirror-staging host's public IP
(`roles/aws/aws_provision_bastion`'s `add_host` task). `sync_mirror_to_bastion` and
`sync_backup_to_staging` (see `bare-metal-architecture.md` §3/§8) instead rsync
directly between the two hosts' private IPs over the VPC, not through that proxy or
the controller — `roles/aws/aws_provision_mirror_staging_host` exposes
`mirror_staging_relay_address` (the private IP) specifically so those
provider-agnostic common roles can reach this host correctly without any AWS-specific
logic of their own; bare metal has no public/private split, so that fact is simply
unset there and those roles fall back to the host's normal inventory address.

## 3. What the AWS loop exercises vs. skips

`playbooks/full-sno-test-setup.yaml` (AWS) deliberately runs a smaller slice than
`playbooks/full-baremetal-production-setup.yaml`:

| Exercised on AWS | Bare-metal-only (not exercised here) |
|---|---|
| Provisioning (`provision-sno-aws.yaml`) | MetalLB (`configure-metallb.yaml`) — AWS test loop has no non-HTTP TCP middleware exposure requirement |
| Storage: LVMS + MCG (`configure-storage.yaml`) | Tracing (`configure-tracing.yaml`) |
| Logging: LokiStack + Grafana (`configure-logging.yaml`) | Alerting (`configure-alerting.yaml`) |
| Backup/DR validation (`configure-backup-dr.yaml`) | Day 2 middleware platform (`configure-middleware.yaml`) |

The skipped items aren't AWS-incompatible — they're simply not yet wired into the
AWS loop.

`configure-backup-dr.yaml` validates `roles/ocp/configure_oadp_backup`, which targets
the in-cluster NooBaa provided by `configure_mcg` — the same backend used on bare
metal, run here unmodified. An earlier `aws` backend option pointed OADP directly at
a real external S3 bucket; that only ever worked here because `aws_provision_network`
creates an S3 VPC Gateway Endpoint, routing that traffic over AWS's private network
without an internet route — it was removed once `configure_mcg` ran on both
providers, since it had no remaining use case and was never portable to bare metal
anyway (no equivalent endpoint, no internet route at all there). See
`bare-metal-architecture.md` §8 and `roles/ocp/configure_oadp_backup/README.md`.

## 4. DNS

`mirror.{{ base_domain }}` has no public DNS path on AWS (unlike bare metal, where
the customer's own DNS admin creates this record directly — see
`bare-metal-architecture.md` §9): `roles/aws/aws_provision_bastion` creates a
**private Route53 hosted zone** for `base_domain`, associated with the VPC, with an
A record pointing `mirror.{{ base_domain }}` at the bastion's private IP. This
resolves purely through the VPC's internal Route53 resolver — no internet route
needed, consistent with the bastion having none. It coexists with
`openshift-install`'s own separate private zone for `{{ cluster_name }}.{{
base_domain }}` (api/api-int/apps) since Route53 matches the most specific zone per
query. `roles/aws/aws_destroy_sno` cleans up both the record and the zone on
teardown so repeated test runs don't accumulate orphaned zones in the account.

`amazon.aws.route53` overloads its own `region` module parameter to mean a
latency-based-routing-policy region (requiring `identifier` alongside it) — unrelated
to the AWS SDK connection region this repo's `module_defaults: group/aws:` block
sets for every other `amazon.aws.*` task. Both the create (`aws_provision_bastion`)
and delete (`aws_destroy_sno`) `amazon.aws.route53` tasks explicitly override
`region: "{{ omit }}"` to avoid tripping that validation — `amazon.aws.route53_zone`
is unaffected and uses the module_defaults region normally.

## 5. Cloud credentials and ingress DNS: IAM and Route53 have no VPC endpoint

`roles/aws/aws_provision_network`'s VPC endpoints cover `s3`, `ec2`,
`elasticloadbalancing`, and `sts` — but **IAM and Route53 are AWS global
control-plane APIs with no PrivateLink/VPC endpoint support at all**. Confirmed
against a real run, this breaks two independent things inside the cluster
simultaneously, neither of which is a credentials-validity problem — both are pure
network-reachability problems from a node with no internet route:

- **cloud-credential-operator**, in the default Mint mode, calls
  `iam.amazonaws.com` directly from inside the cluster to mint per-component IAM
  users at runtime. Every `CredentialsRequest` failed identically with a `dial tcp
  ...:443: i/o timeout`.
- **ingress-operator** calls `route53.amazonaws.com` directly from inside the
  cluster to write the `*.apps` wildcard DNS record. The `IngressController`'s
  `DNSRecord` reported `DNSReady=False (NoZones: The record isn't present in any
  zones.)`, which cascaded into `authentication`/`console` never reporting
  Available (both resolve `*.apps...` hostnames).

Both are worked around the same way the `api`/`api-int` records already are handled —
by doing the AWS-API-calling step from the Ansible controller (which has real
internet) instead of from inside the cluster:

- **`install-config.yaml`** sets `credentialsMode: Manual` (`roles/common/
  generate_install_config`, AWS-only — bare metal's `platform: none` has no CCO
  concept). `roles/aws/aws_configure_manual_credentials` (run from
  `aws_provision_sno_ipi`, after `generate_install_config`, before `create cluster`)
  extracts the release image's `CredentialsRequest` manifests, runs `ccoctl aws
  create-all` to provision an OIDC identity provider (a public S3 bucket, fetched by
  AWS STS's own backend — not by the node) plus per-request IAM roles trusting it,
  and copies the resulting Secret manifests + signing key into the install
  directory. In-cluster components then authenticate via `AssumeRoleWithWebIdentity`
  against STS, which **does** have a VPC endpoint. `ccoctl_name` is a deterministic
  hash of `cluster_name`/`base_domain` (not random) so repeated retries reuse the
  same OIDC bucket/IAM roles instead of leaking new ones each time `ccoctl aws
  create-all` is run against a partially-failed prior attempt.
- **The apps wildcard DNS record** is set to `dnsManagementPolicy: Unmanaged` on the
  default `IngressController` (`roles/aws/aws_configure_manual_dns/tasks/main.yaml`,
  an extra manifest rendered before `create cluster`), so the ingress-operator never
  attempts the impossible Route53 call. `aws_provision_sno_ipi` wraps `create
  cluster` in a `block`/`rescue`: the first attempt is expected to time out waiting
  for operators (nothing has created the apps record yet), and the `rescue:` runs
  `aws_configure_manual_dns`'s `create_apps_record.yml` — which reads the
  `router-default` Service's ELB hostname and publishes a `*.apps.<cluster>.<
  base_domain>` CNAME to it from the controller, to **both** the account's public
  hosted zone and the cluster's own private hosted zone (the same two-zone pattern
  `api`/`api-int` already use) — then resumes with `openshift-install wait-for
  install-complete`, the exact recovery path the installer's own timeout error
  output suggests.

See `roles/aws/aws_configure_manual_credentials/README.md` and `roles/aws/
aws_configure_manual_dns/README.md` for the full mechanism.

Neither the ccoctl-created OIDC bucket/IAM roles nor the public-zone apps CNAME are
tracked by `openshift-install destroy cluster`'s own bookkeeping — `roles/aws/
aws_destroy_sno` cleans up both explicitly (§6).

## 6. Teardown

`roles/aws/aws_destroy_sno` tears down, in dependency order: the ccoctl-created OIDC
S3 bucket and IAM roles (`ccoctl aws delete`, recomputing the same deterministic
`ccoctl_name` as §5) and the public-zone apps wildcard CNAME (§5) — both
`ignore_errors: true`, since a prior attempt may never have reached either step —
then `openshift-install destroy cluster`, then the bastion and mirror-staging EC2
instances, the `mirror.{{ base_domain }}` Route53 record and private hosted zone
(§4), VPC endpoints, the internet gateway, non-main route tables, subnets, security
groups, and finally the VPC itself — each step retried where AWS's own
eventual-consistency can otherwise cause a premature `DependencyViolation`. There is
no equivalent teardown automation for bare metal (decommissioning physical hardware
is an out-of-band, non-Ansible activity).

## 7. Known AWS-test-loop-specific gaps

- `full-sno-test-setup.yaml` doesn't exercise MetalLB, tracing, alerting, or the Day
  2 middleware platform (§3) — those paths are currently only validated against
  bare-metal inventory via `--syntax-check`/`ansible-playbook --check`, not against a
  live AWS cluster.
- `oc_mirror_operator_packages` catalog/channel values recorded in
  `bare-metal-architecture.md` §13 were confirmed by directly querying
  `registry.redhat.io`'s operator indexes from a real AWS mirror-staging host — this
  is the actual verification mechanism for that doc's "verify against a live
  cluster" caveats, even though the content itself is provider-agnostic.
