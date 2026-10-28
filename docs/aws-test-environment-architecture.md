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
`bastion/roles/ocp/*`/`bastion/roles/common/*` roles against AWS infrastructure
instead of bare metal, so it references that document throughout rather than
duplicating it. `bare-metal-architecture.md` has no dependency in the other
direction — it can be read and used entirely on its own.

See [`architectural-decisions.md`](architectural-decisions.md) for the rationale
behind testing everything in a fully-disconnected mode on AWS too, rather than taking
a connected shortcut.

## 1. Why AWS, and what it does and doesn't prove

Bare-metal hardware isn't always available up front, so this repo keeps all
infrastructure *provisioning* behind a swappable `infra_provider: aws | baremetal`
layer. Everything from "cluster is up" onward — storage, backup/DR, logging,
tracing, Day 2 middleware, upgrades, node-failure drills — is written once in
`bastion/roles/common/*` and `bastion/roles/ocp/*` and run unmodified against
whichever provider is active. Validating a feature here means it's already proven
against the shared code path the bare-metal rollout will also use; only the
provisioning layer (`aws-infra/`/`staging/roles/aws/*` vs. `bastion/roles/baremetal/*`)
and the install-config/cluster-creation split described below differ.

What AWS does **not** prove: anything bare-metal-specific — BMC/Redfish provisioning
or real single-switch cabling constraints. See `bare-metal-architecture.md` §10 for
those.

## 2. Three top-level trees instead of two

Unlike bare metal (`staging/` + `bastion/` only), the AWS loop needs a third,
AWS-only tree:

- **`aws-infra/`** — provisions the two EC2 hosts themselves (the VPC, subnets, VPC
  endpoints, and the staging/bastion instances) and nothing else. It has no
  bare-metal equivalent — there is no automation that racks a physical server. Run
  once per environment, from wherever has AWS credentials and real internet (not
  necessarily either EC2 host).
- **`staging/`** — same tree/role as on bare metal (stages mirror content, packages
  the bastion bundle), but on AWS it *also* gains `staging/roles/aws/*`: the roles
  that actually run `openshift-install create cluster` for an AWS install. This is
  the one structural difference from bare metal's division of labor — see §3.
- **`bastion/`** — identical across both providers. No AWS-specific day-2 role
  exists anywhere under `bastion/roles/ocp/*` or `bastion/roles/common/*`; that's the
  whole point of proving features here before bare metal.

### AWS mapping of the two EC2 hosts

| Topology role | AWS implementation |
|---|---|
| Mirror-staging / staging host | EC2 instance, public subnet, real internet route. The operator SSHes in directly, `git clone`s this repo, and runs the entire `staging/` tree locally there (same way an engineer would run `staging/` on a real staging laptop/server for bare metal). |
| Bastion | EC2 instance, private subnet, **no NAT/IGW at all**. Receives the repo + bundle via the existing `package_bastion_bundle`/`unpack_bastion_bundle` mechanism (`bastion_transfer_method: rsync` works here, since staging and bastion share a VPC with private-IP reachability) — not via `git clone`, since it has no internet route to reach a Git remote either. |
| SNO node | The IPI control-plane instance (zero workers), same private subnet as the bastion. |

`aws-infra/roles/aws_provision_network` builds a VPC with a public subnet used only
by the staging host, and a private subnet (reused as the cluster's machine network)
with no internet gateway or NAT route at all for the bastion or the SNO node. VPC
endpoints (`s3`, `ec2`, `elasticloadbalancing`, `sts`) give the installer and the
in-cluster AWS cloud provider the AWS API access they need without any internet
route. See `architectural-decisions.md` §2 for the full disconnected-mirroring
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
specified machine networks"), so `generate_install_config`'s `install-config.yaml.j2`
adds a second `machineNetwork` entry for the public subnet's own CIDR
(`sno_public_subnet_cidr`) alongside the shared `machine_network_cidr` —
`machine_network_cidr` itself stays untouched so its "identical across providers"
meaning for bare metal's single-subnet LAN isn't disturbed. This requirement is
specific to installing into an existing VPC and doesn't apply on bare metal
(`platform: none`), so none of this is in `bare-metal-architecture.md`.

**`publish: External`, not `Internal`**: `create cluster` runs from the staging
host, which sits in the VPC's *public* subnet with a real route out — but the
cluster's own Route53 hosted zone is still VPC-private by default under `publish:
Internal`, and resolving/reaching it from outside AWS's own DNS resolver (e.g. a
later `oc`/`kubernetes.core` call made from a human's laptop, or any step this
automation runs from outside the VPC) would fail. `External` makes the API/ingress
load balancers internet-reachable (still TLS/auth gated) — it does **not** give the
SNO node itself any outbound internet route (the private subnet's route table is
unchanged), so the node-egress half of the "always fully disconnected" guarantee in
`CLAUDE.md` holds exactly as before, and operator/cluster-update image pulls still go
through `imageContentSources` to the bastion's mirror registry either way. This is
purely an AWS-test-loop concession — bare metal's `platform: none` has no
publish/Route53 concept and is unaffected.

## 3. Why cluster creation runs on staging, not the bastion

Bare metal's bastion runs the entire install end-to-end, including generating
`install-config.yaml`. On AWS, that can't work: `openshift-install create cluster`
needs direct network access to two AWS global control-plane APIs that have **no
VPC PrivateLink/endpoint support at all** — Route53 (to publish api/api-int DNS,
managed by the installer itself) and IAM (via `ccoctl`, for Manual-mode credentials,
§5). The bastion's private subnet has zero internet route and only the VPC endpoints
listed in §2 — none of which cover Route53 or IAM. Giving the bastion a NAT gateway
to work around this would defeat the entire purpose of the AWS test loop, which
exists to validate against a genuinely disconnected bastion, matching real bare
metal. This is a deliberate, locked-in design choice, not a gap to "fix" later.

So the install is split into a 3-hop round trip instead of running wholly on one
host:

```
bastion: generate_install_config → package_install_config_bundle
            │
            ▼ (bastion_transfer_method, same media/rsync pattern as the main bundle)
staging: unpack_install_config_bundle → aws_provision_sno_ipi (create cluster) → package_kubeconfig_bundle
            │
            ▼
bastion: unpack_kubeconfig_bundle → (now day-2 roles run normally)
```

1. **`bastion/playbooks/provision-sno-aws.yaml`** unpacks the staging bundle, deploys
   the mirror registry, runs `configure_bastion_services`, then
   `generate_install_config` (same role as bare metal — the `infra_provider == 'aws'`
   branch in its template, §2 above) — and finally `package_install_config_bundle`,
   which archives just `install-config.yaml` (`force_archive: true`, since
   `community.general.archive` on a single file without that flag produces a plain
   gzip, not an extractable tar) and transfers it back to staging using the same
   media/rsync pattern as `package_bastion_bundle`.
2. **`staging/playbooks/provision-sno-aws.yaml`** unpacks that bundle
   (`unpack_install_config_bundle`), then runs `staging/roles/aws/
   aws_provision_sno_ipi` — a trimmed version of the installer role: no
   `generate_install_config` include (the install-config already arrived from
   bastion), self-heals stale state from a previous attempt by clearing
   `install_dir` except `install-config.yaml`, then `openshift-install create
   cluster`, with `aws_configure_manual_credentials`/`aws_configure_manual_dns`
   nested inside it exactly as before (§5). `package_kubeconfig_bundle` then
   archives the resulting kubeconfig and transfers it back to the bastion the same
   way.
3. **`bastion/playbooks/unpack-cluster-access.yaml`** runs
   `unpack_kubeconfig_bundle` on the bastion, after which `sno_kubeconfig` points at
   a real, reachable cluster and every `bastion/roles/ocp/*` day-2 role runs exactly
   as it does on bare metal — no AWS-specific code anywhere in that layer.

There is no cross-host `delegate_to`/proxy dance for any of this: each host only
ever acts on itself (`hosts: localhost` throughout, same as bare metal), and every
hop is a one-directional file transfer using the existing media/rsync abstraction —
the same pattern as the main staging→bastion bundle and the backup-export relay in
`bare-metal-architecture.md` §8.

## 4. Getting the repo onto the two EC2 hosts

Neither EC2 host has this repo (or even Ansible) on it yet — both start as blank
instances, same as a real bare-metal staging host starts as a blank machine on the
customer's network. `aws-infra/playbooks/provision-hosts.yaml` closes that gap for
the staging side automatically, then the operator takes over:

1. SSHes directly to the staging host's public IP **with agent forwarding**
   (`ssh -A ...` — `provision-hosts.yaml`'s printed summary already includes `-A`)
   and runs `bash ~/bootstrap-staging-host.sh <repo-url> <ref>` (the exact command,
   with both arguments filled in, is in that same summary —
   `automation_repo_url`/`automation_repo_ref` are constants in
   `aws-infra/playbooks/group_vars/all.yaml`, not prompted for, since this repo's own
   git location and branch don't vary per environment). Agent forwarding matters
   because `automation_repo_url` defaults to an SSH URL: without `-A`, the staging
   host has no key GitHub trusts and the clone fails with `Permission denied
   (publickey)`. `-A` forwards the operator's own local ssh-agent instead of ever
   copying a private key onto the host — confirm a key is loaded first with
   `ssh-add -l` locally.
   `bootstrap-staging-host.sh` (`staging/bootstrap-staging-host.sh`, scp'd there by
   `provision-hosts.yaml` alongside the rendered inventory and AWS credentials file)
   does the minimum possible in bash: installs `python3`/`python3-pip`/`git` via the
   system package manager, clones the repo, runs `pip install -r requirements.txt`
   (which installs Ansible itself — unavoidable in bash, since nothing past that
   point can be an Ansible task until Ansible exists), and moves the already-pushed,
   fully-rendered `staging/inventory/inventory.yaml` into place (no VPC/subnet values
   are ever hand-copied — `provision-hosts.yaml` renders
   `staging/inventory/inventory-aws.yaml.j2` itself once the VPC/subnets it needs
   actually exist, not `configure-aws-env.yaml`, which runs before they do).
2. Runs `ansible-playbook prepare-staging-host.yaml -i ../inventory/inventory.yaml`
   (installs this repo's Galaxy collections and a couple of system packages — see
   `staging/roles/common/prepare_staging_host/README.md`), then
   `staging/playbooks/full-staging-setup-aws.yaml`, producing the bastion bundle
   tar.gz exactly as bare metal does.
3. Transfers that bundle to the bastion (SSH ProxyCommand through the staging host's
   public IP, printed by `aws_provision_bastion`'s README — `aws-infra/` doesn't
   automate this hop) and runs `bastion/playbooks/full-bastion-provision-aws.yaml`
   there (§3).
4. Transfers the resulting install-config bundle back to staging, runs `staging/
   playbooks/provision-sno-aws.yaml` there, transfers the resulting kubeconfig bundle
   back to the bastion, and runs `bastion/playbooks/full-bastion-configure-aws.yaml`
   (`unpack-cluster-access.yaml` + storage + logging + backup-dr — see §6 for why
   MetalLB/tracing/alerting/middleware aren't included).

## 5. Cloud credentials and ingress DNS: IAM and Route53 have no VPC endpoint

`aws-infra/roles/aws_provision_network`'s VPC endpoints cover `s3`, `ec2`,
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

Both are worked around the same way `api`/`api-int` already are handled — by doing
the AWS-API-calling step from a host with real internet (now the staging host,
where `create cluster` actually runs — see §3) instead of from inside the cluster:

- **`install-config.yaml`** sets `credentialsMode: Manual` (`bastion/roles/common/
  generate_install_config`, AWS-only — bare metal's `platform: none` has no CCO
  concept). `staging/roles/aws/aws_configure_manual_credentials` (run from
  `aws_provision_sno_ipi`, before `create cluster`) extracts the release image's
  `CredentialsRequest` manifests, runs `ccoctl aws create-all` to provision an OIDC
  identity provider (a public S3 bucket, fetched by AWS STS's own backend — not by
  the node) plus per-request IAM roles trusting it, and copies the resulting Secret
  manifests + signing key into the install directory. In-cluster components then
  authenticate via `AssumeRoleWithWebIdentity` against STS, which **does** have a VPC
  endpoint. `ccoctl_name` is a deterministic hash of `cluster_name`/`base_domain`
  (not random) so repeated retries reuse the same OIDC bucket/IAM roles instead of
  leaking new ones each time `ccoctl aws create-all` is run against a
  partially-failed prior attempt.
- **The apps wildcard DNS record** is set to `dnsManagementPolicy: Unmanaged` on the
  default `IngressController` (`staging/roles/aws/aws_configure_manual_dns/tasks/
  main.yaml`, an extra manifest rendered before `create cluster`), so the
  ingress-operator never attempts the impossible Route53 call.
  `aws_provision_sno_ipi` wraps `create cluster` in a `block`/`rescue`: the first
  attempt is expected to time out waiting for operators (nothing has created the
  apps record yet), and the `rescue:` runs `aws_configure_manual_dns`'s
  `create_apps_record.yml` — which reads the `router-default` Service's ELB hostname
  and publishes a `*.apps.<cluster>.<base_domain>` CNAME to it from the staging host,
  to **both** the account's public hosted zone and the cluster's own private hosted
  zone (the same two-zone pattern `api`/`api-int` already use) — then resumes with
  `openshift-install wait-for install-complete`, the exact recovery path the
  installer's own timeout error output suggests.

See `staging/roles/aws/aws_configure_manual_credentials/README.md` and `staging/
roles/aws/aws_configure_manual_dns/README.md` for the full mechanism.

Neither the ccoctl-created OIDC bucket/IAM roles nor the public-zone apps CNAME are
tracked by `openshift-install destroy cluster`'s own bookkeeping — `staging/roles/
aws/aws_destroy_cluster` cleans up both explicitly (§7).

## 6. DNS for the mirror registry

`mirror.{{ base_domain }}` has no public DNS path on AWS (unlike bare metal, where
the customer's own DNS admin creates this record directly — see
`bare-metal-architecture.md` §9): `aws-infra/roles/aws_provision_bastion` creates a
**private Route53 hosted zone** for `base_domain`, associated with the VPC, with an
A record pointing `mirror.{{ base_domain }}` at the bastion's private IP. This
resolves purely through the VPC's internal Route53 resolver — no internet route
needed, consistent with the bastion having none. It coexists with
`openshift-install`'s own separate private zone for `{{ cluster_name }}.{{
base_domain }}` (api/api-int/apps) since Route53 matches the most specific zone per
query. `aws-infra/roles/aws_destroy_infra` cleans up both the record and the zone on
teardown so repeated test runs don't accumulate orphaned zones in the account.

`amazon.aws.route53` overloads its own `region` module parameter to mean a
latency-based-routing-policy region (requiring `identifier` alongside it) — unrelated
to the AWS SDK connection region this repo's `module_defaults: group/aws:` block
sets for every other `amazon.aws.*` task. Both the create (`aws_provision_bastion`)
and delete (`aws_destroy_infra`) `amazon.aws.route53` tasks explicitly override
`region: "{{ omit }}"` to avoid tripping that validation — `amazon.aws.route53_zone`
is unaffected and uses the module_defaults region normally.

## 7. Teardown

Teardown is split across the same two trees that provisioning is, and must run in
the opposite order:

1. **`staging/playbooks/destroy-sno-aws.yaml`** (`staging/roles/aws/
   aws_destroy_cluster`) — tears down, in dependency order: the ccoctl-created OIDC
   S3 bucket and IAM roles (`ccoctl aws delete`, recomputing the same deterministic
   `ccoctl_name` as §5) and the public-zone apps wildcard CNAME (§5) — both
   `ignore_errors: true`, since a prior attempt may never have reached either step —
   then `openshift-install destroy cluster`.
2. **`aws-infra/playbooks/destroy-hosts.yaml`** (`aws-infra/roles/
   aws_destroy_infra`) — only after step 1 — tears down the bastion and staging EC2
   instances, the `mirror.{{ base_domain }}` Route53 record and private hosted zone
   (§6), VPC endpoints, the internet gateway, non-main route tables, subnets,
   security groups, and finally the VPC itself — each step retried where AWS's own
   eventual-consistency can otherwise cause a premature `DependencyViolation`.

There is no equivalent teardown automation for bare metal (decommissioning physical
hardware is an out-of-band, non-Ansible activity).

## 8. What the AWS loop exercises vs. skips

`bastion/playbooks/full-bastion-configure-aws.yaml` deliberately runs a smaller
slice than bare metal's `full-bastion-setup-baremetal.yaml`:

| Exercised on AWS | Bare-metal-only (not exercised here) |
|---|---|
| Provisioning (`full-bastion-provision-aws.yaml` + staging's `provision-sno-aws.yaml`) | MetalLB (`configure-metallb.yaml`) — AWS test loop has no non-HTTP TCP middleware exposure requirement |
| Storage: LVMS + MCG (`configure-storage.yaml`) | Tracing (`configure-tracing.yaml`) |
| Logging: LokiStack + Grafana (`configure-logging.yaml`) | Alerting (`configure-alerting.yaml`) |
| Backup/DR validation (`configure-backup-dr.yaml`) | Day 2 middleware platform (`configure-middleware.yaml`) |

The skipped items aren't AWS-incompatible — they're simply not yet wired into the
AWS loop.

`configure-backup-dr.yaml` validates `bastion/roles/ocp/configure_oadp_backup`,
which targets the in-cluster NooBaa provided by `configure_mcg` — the same backend
used on bare metal, run here unmodified. An earlier `aws` backend option pointed
OADP directly at a real external S3 bucket; that only ever worked here because
`aws_provision_network` creates an S3 VPC Gateway Endpoint, routing that traffic
over AWS's private network without an internet route — it was removed once
`configure_mcg` ran on both providers, since it had no remaining use case and was
never portable to bare metal anyway (no equivalent endpoint, no internet route at
all there). See `bare-metal-architecture.md` §8 and `bastion/roles/ocp/
configure_oadp_backup/README.md`.

## 9. Known AWS-test-loop-specific gaps

- `full-bastion-configure-aws.yaml` doesn't exercise MetalLB, tracing, alerting, or
  the Day 2 middleware platform (§8) — those paths are currently only validated
  against bare-metal inventory via `--syntax-check`/`ansible-playbook --check`, not
  against a live AWS cluster.
- `oc_mirror_operator_packages` catalog/channel values recorded in
  `bare-metal-architecture.md` §13 were confirmed by directly querying
  `registry.redhat.io`'s operator indexes from a real AWS staging host — this is the
  actual verification mechanism for that doc's "verify against a live cluster"
  caveats, even though the content itself is provider-agnostic.
- The 3-hop install-config/kubeconfig handback (§3) and the automated inventory
  render-and-delivery step (§4) are new in this split and have not yet been
  exercised against a live AWS run — the staging/bastion bundle handoff they're
  modeled on was already
  flagged as unverified against a real two-host transfer in `package_bastion_bundle`'s
  and `unpack_bastion_bundle`'s READMEs; the same caveat applies here until a real
  end-to-end AWS run confirms it.
- `aws_sno_instance_type` (`bastion/roles/common/generate_install_config/defaults/
  main.yaml`) and `bastion_instance_type` (`aws-infra/roles/aws_provision_bastion/
  defaults/main.yaml`) previously lived in one shared `playbooks/group_vars/all.yaml`
  before the staging/bastion split; each now has its own role default local to the
  tree that actually uses it, per this repo's "role defaults aren't shared across
  roles" convention — not a functional change, just re-homed.
