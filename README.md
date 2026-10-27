# SNO Test/Production Automation Pattern

Ansible automation pattern for testing Single Node OpenShift (SNO) architecture and
day-2 operational features before rolling them out to a bare-metal production
environment (single server, single switch, single bastion).

Since bare-metal hardware isn't always available up front, this repo keeps all
infrastructure provisioning behind a single switch — `infra_provider: aws` or
`infra_provider: baremetal` — so the same day-2 feature roles (storage, backup/DR,
logging, upgrades, node-failure drills) can be validated on AWS first and re-run
unchanged against a real bare-metal SNO cluster later. **Both paths are always fully
disconnected** (see below) — there's no connected-install shortcut on AWS, so the
mirroring workflow itself is exercised on every run, not just once hardware shows up.

## Design: swappable infra, shared features

```
infra_provider: aws               infra_provider: baremetal
┌───────────────────────────┐      ┌─────────────────────────────────┐
│ roles/aws/*               │      │ roles/baremetal/*               │
│  - aws_provision_network  │      │  - baremetal_prepare_bastion    │
│  - aws_provision_mirror_  │      │  - baremetal_generate_agent_iso │
│    staging_host           │      │  - baremetal_boot_node_via_bmc  │
│  - aws_provision_bastion  │      │                                 │
│  - aws_provision_sno_ipi  │      │                                 │
│  - aws_destroy_sno        │      └───────────┬─────────────────────┘
└───────────┬───────────────┘                  │
            └───────────────────┬──────────────┘
                 roles/common/*  (stage/sync/deploy mirror registry,
                                  install-config rendering, kubeconfig wait)
                 roles/ocp/*     (storage: LVMS + MCG; backup/DR +
                                  external S3 export; logging: Loki+Grafana;
                                  tracing: OpenTelemetry+Tempo; alerting;
                                  MetalLB; Day 2 app platform: RabbitMQ,
                                  Postgres, Redis, Keycloak; upgrades,
                                  node-failure drill — the features under test)
```

Only the provisioning layer differs per provider. Everything from "cluster is up"
onward is identical automation, which is the point: features validated on AWS carry
over to the bare-metal path without rewriting.

## Architecture design documents

[`docs/bare-metal-architecture.md`](docs/bare-metal-architecture.md) is the full
implementation reference for the bare-metal production target — what's deployed,
why, which role/playbook owns it, and a requirements-traceability table back to the
customer's stated requirements. It's self-contained (no reference to the AWS test
environment) and a living document: update it alongside any role/playbook change,
and treat it (not memory of what was built) as the source of truth for what this
repo currently does. Share it with the customer as the design reference for this
deployment.

[`docs/aws-test-environment-architecture.md`](docs/aws-test-environment-architecture.md)
is the internal counterpart covering only what's different about running the same
feature set against this repo's AWS test loop — it references
`bare-metal-architecture.md` for everything shared rather than duplicating it.

[`docs/architectural-decisions.md`](docs/architectural-decisions.md) covers the
narrower *why* behind specific carried-forward design patterns (disconnected content
mirroring, OADP backup/DR storage isolation) from prior engagements.

## AWS is genuinely disconnected, not simulated

`roles/aws/aws_provision_network` builds a VPC with two subnets:

- a **public** subnet used *only* by an ephemeral mirror-staging EC2 instance (the
  sole internet-connected host in the whole stack), and
- a **private** subnet — reused as the cluster's machine network — with **no internet
  gateway or NAT route at all**, hosting both the bastion and the SNO node.

VPC endpoints (`s3`, `ec2`, `elasticloadbalancing`, `sts`) give the installer and the
in-cluster AWS cloud provider the AWS API access they need without any internet route.
Content reaches the cluster exactly like it would on bare metal: staged to disk on the
connected host, synced to the (unreachable-from-the-internet) bastion, and served from
a mirror registry deployed there — see `docs/architectural-decisions.md` #2.

## Status of each path

- **AWS** (`roles/aws/*`): fully implemented — provisions the isolated VPC, mirror
  staging host, bastion, and a single-control-plane / zero-worker IPI cluster to
  emulate the SNO topology.
- **Bare metal** (`roles/baremetal/*`): implemented using the Agent-Based Installer
  pattern against the target production hardware (Dell PowerEdge R7725, iDRAC9/10).
  ISO generation and BMC virtual-media boot (standard Redfish via
  `community.general.redfish_command`) are both implemented; still unverified against
  real hardware (no live BMC to test against yet) and will fail fast with a clear
  message until `bmc_address`/`bmc_username`/`bmc_password`/`iso_http_url` are set
  per-environment.

## Repository structure

```
inventory/
  aws/inventory.yaml.j2       # template — configure-aws-env.yaml renders one <domain>.yaml per environment
  baremetal/inventory.yaml    # infra_provider: baremetal, static bastion + mirror-staging hosts
playbooks/
  configure-aws-env.yaml           # prompts for AWS credentials + base_domain, writes
                                    # ~/tmp/<domain>-creds and inventory/aws/<domain>.yaml
  provision-sno-aws.yaml           # imports infra_providers/aws/provision.yaml (always mirrors content as part of provisioning)
  provision-sno-baremetal.yaml     # imports infra_providers/baremetal/provision.yaml — separate files, not one dispatcher, so a
                                    # bare-metal-only copy of this repo can delete the aws/ side wholesale (see bare-metal-repo-copy.md)
  destroy-sno-aws.yaml
  destroy-sno-baremetal.yaml
  full-sno-test-setup.yaml        # prereqs + provision + storage (LVMS+MCG) + logging (Loki+Grafana) + backup (AWS test loop)
  full-baremetal-production-setup.yaml  # adds MetalLB + tracing + alerting + Day 2 middleware (bare-metal rollout)
  configure-storage.yaml          # LVM Storage (LVMS, default) + MCG (S3)
  configure-backup-dr.yaml        # OADP backup/DR (in-cluster NooBaa) + external S3 export config validation
  configure-logging.yaml          # LokiStack + Grafana + external SIEM forwarding
  configure-tracing.yaml          # OpenTelemetry Collector + Tempo
  configure-alerting.yaml         # email alerting via customer SMTP
  configure-metallb.yaml          # non-HTTP TCP middleware LoadBalancer IPs (bare metal only)
  configure-middleware.yaml       # RabbitMQ, Postgres (+pgAdmin), Redis, Keycloak
  mirror-content.yaml             # standalone content refresh + on-cluster app Quay
  export-backup.yaml              # periodic/on-demand app-S3-data egress, relayed via bastion -> mirror-staging (cluster has no internet route on either provider)
  upgrade-sno.yaml                # minimal-downtime upgrade
  simulate-node-failure.yaml      # reboot/recovery drill
  infra_providers/
    aws/{provision,destroy}.yaml
    baremetal/{provision,destroy}.yaml
roles/
  common/        # mirror staging/sync/registry, install-config rendering, kubeconfig wait, bastion services
  aws/           # AWS-specific provisioning (swappable): network, mirror-staging host, bastion, SNO IPI
  baremetal/     # bare-metal-specific provisioning (swappable, partly stubbed): bastion prep, agent ISO, BMC boot
  ocp/           # provider-agnostic day-2 features: LVMS/MCG, OADP, logging, tracing, middleware, upgrades, Quay
```

## Quick start (AWS test environment)

Every new test environment (new sandbox account, new assigned domain) starts with:

```bash
ansible-playbook playbooks/configure-aws-env.yaml
# prompts for base_domain + AWS credentials, imports your ssh_key as a new
# per-environment EC2 key pair, then writes:
#   ~/tmp/<base_domain>-creds
#   inventory/aws/<base_domain>.yaml
```

Then, using that environment's generated inventory file:

```bash
ansible-playbook playbooks/full-sno-test-setup.yaml -i inventory/aws/<base_domain>.yaml
```

Or step by step:

```bash
ansible-playbook playbooks/provision-sno-aws.yaml  -i inventory/aws/<base_domain>.yaml
ansible-playbook playbooks/configure-storage.yaml  -i inventory/aws/<base_domain>.yaml
ansible-playbook playbooks/configure-backup-dr.yaml -i inventory/aws/<base_domain>.yaml
ansible-playbook playbooks/configure-logging.yaml  -i inventory/aws/<base_domain>.yaml
```

Tear down:

```bash
ansible-playbook playbooks/destroy-sno-aws.yaml -i inventory/aws/<base_domain>.yaml
```

Run `configure-aws-env.yaml` again with a different domain to stand up another
environment — each gets its own credentials file and inventory file, so they can be
provisioned concurrently without colliding. One remaining shared-state caveat:
`cluster_name` and `tmp_dir`/`install_dir` (in `group_vars/all.yaml`) default to the
same values for every environment — pass `-e cluster_name=<unique-name>` per
environment if you're actually running two AWS provisions at the same time on the same
workstation, or those local working directories will collide.

## Moving to a bare-metal environment

When bare-metal hardware is available:

1. Fill in `inventory/baremetal/inventory.yaml` with the real bastion and
   mirror-staging hosts, and `group_vars` with BMC credentials, MAC address,
   rendezvous IP, DNS/gateway.
2. Finish `roles/baremetal/baremetal_boot_node_via_bmc` against the actual BMC.
3. Re-run the exact same `playbooks/configure-*.yaml` and `playbooks/upgrade-sno.yaml`
   playbooks — no changes needed, since those roles never touched AWS or bare-metal
   specifics directly.

See `playbooks/README.md` for the full variable reference.
