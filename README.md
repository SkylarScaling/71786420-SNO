# SNO Bare-Metal Production Automation

Ansible automation that builds, configures, and maintains a Single Node OpenShift
(SNO) platform on a single bare-metal server (single server, single switch, single
bastion), as a repeatable, disconnected deployment. Infrastructure provisioning is
abstracted behind `infra_provider: aws | baremetal` so the same feature automation can
be proven out against an AWS test loop before real hardware is available — see
`docs/aws-test-environment-architecture.md`.

The platform runs **fully disconnected (air-gapped)** on both providers — the SNO
node and its bastion have no internet route at all, and are not assumed to have a
live network path to the staging host either. This automation is split into
independent top-level trees for that reason:

- **`staging/`** — runs directly on the internet-connected staging host (`hosts:
  localhost`). Mirrors release/operator content and the install-time binaries to
  disk, then packages everything the bastion needs — content, binaries, the entire
  `bastion/` tree, and resolved per-environment config — into one `tar.gz`. On AWS
  only, it also runs `openshift-install create cluster` itself (`staging/roles/aws/*`
  — see `docs/aws-test-environment-architecture.md` §3 for why).
- **`bastion/`** — runs directly on the bastion (`hosts: localhost`), once that
  tar.gz has been physically copied there (the default) or rsynced over (opt-in —
  see `staging/roles/common/package_bastion_bundle`'s README). Installs the mirror
  registry, generates and boots the agent-based install ISO (bare metal) or
  generates the install-config for staging to consume (AWS), and configures every
  Day 2 feature (storage, logging, tracing, alerting, backup/DR, middleware) against
  the live cluster — this layer is identical across both providers, with no
  AWS-specific logic anywhere in it.
- **`aws-infra/`** — AWS only, no bare-metal equivalent. Provisions the two EC2 hosts
  (staging + bastion) that the trees above then run on. See `aws-infra/README.md`.

See `docs/architectural-decisions.md` #2 for the full disconnected-mirroring
rationale.

## Architecture design documents

[`docs/bare-metal-architecture.md`](docs/bare-metal-architecture.md) is the full
implementation reference — what's deployed, why, which role/playbook owns it, and a
requirements-traceability table back to the customer's stated requirements. It's a
living document: update it alongside any role/playbook change, and treat it (not
memory of what was built) as the source of truth for what this repo currently does.

[`docs/aws-test-environment-architecture.md`](docs/aws-test-environment-architecture.md)
covers only what's different about running the AWS test loop — it references
`bare-metal-architecture.md` for everything shared rather than duplicating it, and is
not part of the customer deliverable.

[`docs/architectural-decisions.md`](docs/architectural-decisions.md) covers the
narrower *why* behind specific carried-forward design patterns (disconnected content
mirroring, OADP backup/DR storage isolation).

## Status

Implemented using the Agent-Based Installer pattern against the target production
hardware (Dell PowerEdge R7725, iDRAC9/10). ISO generation and BMC virtual-media boot
(standard Redfish via `community.general.redfish_command`) are both implemented;
**still unverified against real hardware** (no live BMC tested against yet) and will
fail fast with a clear message until `bmc_address`/`bmc_username`/`bmc_password`/
`iso_http_url` are set per-environment in `staging/inventory/inventory.yaml`. The
staging/bastion bundle handoff itself is also unverified against a real two-host
transfer — see the known gaps called out in `package_bastion_bundle`'s and
`unpack_bastion_bundle`'s READMEs.

## Repository structure

```
shared-defaults.yaml  # the few constants genuinely shared across trees (currently just
                       #   mirror_registry_quay_port) — read via group_vars/all.yaml in
                       #   staging/ and aws-infra/; see its own header comment for why this
                       #   plain, static file isn't a cross-tree runtime dependency
requirements.txt       # staging's own Python deps (ansible, kubernetes, openshift, boto3, botocore)
requirements-bastion.txt  # the bastion's subset (kubernetes, openshift only) — pip-downloaded into
                          #   a wheelhouse by stage_mirror_content, installed offline by bootstrap-bastion-host.sh
requirements.yml       # Ansible Galaxy collections (kubernetes.core, community.general, amazon.aws, ansible.posix)
aws-infra/       # AWS only, no bare-metal equivalent — provisions the staging + bastion EC2 hosts
  inventory/inventory.yaml      # per-environment, rendered by configure-aws-env.yaml
  playbooks/
    group_vars/all.yaml         # automation_repo_url/automation_repo_ref — constant, not per-environment
    configure-aws-env.yaml      # one-time: AWS creds + renders aws-infra/'s own inventory
    provision-hosts.yaml        # VPC/subnets/endpoints + staging + bastion EC2 instances; also renders
                                 #   staging/inventory/inventory.yaml (needs VPC/subnet facts this creates) and
                                 #   scp's it, the AWS creds file, and bootstrap-staging-host.sh to staging's $HOME
    destroy-hosts.yaml          # run AFTER staging/playbooks/destroy-sno-aws.yaml
  roles/         # aws_provision_network, aws_provision_mirror_staging_host, aws_provision_bastion, aws_destroy_infra
staging/
  bootstrap-staging-host.sh     # first thing run on a blank staging host — installs python3/pip/git, clones
                                 #   this repo, pip-installs requirements.txt (incl. Ansible itself); bash, not
                                 #   Ansible, since Ansible doesn't exist on the host until this runs
  inventory/
    inventory-baremetal.yaml    # committed example — copy/symlink to inventory.yaml to activate
    inventory-aws.yaml.j2       # committed template, rendered by aws-infra/playbooks/provision-hosts.yaml
    inventory.yaml              # per-environment, gitignored — THE single source of per-environment config
  playbooks/
    prepare-staging-host.yaml       # run right after bootstrap-staging-host.sh — Galaxy collections + packages
    stage-and-package.yaml          # stage_mirror_content + package_bastion_bundle
    full-staging-setup-baremetal.yaml   # imports stage-and-package.yaml
    full-staging-setup-aws.yaml         # imports stage-and-package.yaml
    provision-sno-aws.yaml          # AWS only: unpack install-config bundle -> create cluster -> package kubeconfig bundle
    destroy-sno-aws.yaml            # AWS only: aws_destroy_cluster
    receive-backup.yaml         # unpack_staging_backup_bundle + push_backup_to_external_s3
    group_vars/all.yaml         # generic, non-secret defaults only
  roles/
    common/    # stage_mirror_content, package_bastion_bundle, install-config/kubeconfig bundle handback, backup-export relay
    aws/       # AWS only: aws_provision_sno_ipi, aws_configure_manual_credentials, aws_configure_manual_dns, aws_destroy_cluster
bastion/
  bootstrap-bastion-host.sh      # AWS only — installs ansible-core + kubernetes/openshift Python
                                  #   modules offline, from what stage_mirror_content bundled; bare-metal
                                  #   bastions are assumed to already have these pre-baked into their image
  inventory/inventory.yaml      # minimal placeholder — localhost only
  playbooks/
    provision-sno-baremetal.yaml    # unpack bundle -> prepare bastion -> mirror registry -> install-config -> agent ISO -> BMC boot -> wait for install
    provision-sno-aws.yaml          # unpack bundle -> mirror registry -> install-config -> package it back to staging
    destroy-sno-baremetal.yaml
    unpack-cluster-access.yaml      # AWS only: unpack the kubeconfig staging hands back
    configure-storage.yaml / configure-metallb.yaml / configure-logging.yaml /
    configure-tracing.yaml / configure-alerting.yaml / configure-backup-dr.yaml /
    configure-middleware.yaml
    mirror-refresh.yaml         # standalone content refresh + on-cluster app Quay
    export-backup.yaml          # periodic/on-demand app-S3-data egress out of the bastion
    upgrade-sno.yaml / simulate-node-failure.yaml
    full-bastion-setup-baremetal.yaml    # provision + storage + MetalLB + logging + tracing + alerting + backup + Day 2 middleware
    full-bastion-provision-aws.yaml      # imports provision-sno-aws.yaml
    full-bastion-configure-aws.yaml      # unpack-cluster-access + storage + logging + backup-dr (see AWS test loop doc §8)
    group_vars/all.yaml         # placeholder — overwritten by unpack_bastion_bundle from staging's resolved config
  roles/
    common/    # bundle unpack/package, mirror registry install, install-config rendering, kubeconfig wait, bastion services, backup export
    baremetal/ # bastion prep, agent ISO generation, BMC boot
    ocp/       # Day 2 features: LVMS/MCG, OADP, logging, tracing, MetalLB, middleware, upgrades, Quay — identical across both providers
docs/          # architecture reference (bare-metal-architecture.md is provider-agnostic/customer-facing; aws-test-environment-architecture.md is AWS-only)
```

## Quick start (bare metal)

1. Fill in `staging/inventory/inventory.yaml` (copied/symlinked from
   `inventory-baremetal.yaml`) with the real BMC credentials, MAC address,
   rendezvous IP, DNS/gateway/NTP, storage device paths, SMTP, and backup-export vars
   it already has placeholders for. This is the **one** file to edit — everything the
   bastion needs is derived from it.

2. On the staging host, stage content and package the bastion bundle:

   ```bash
   cd staging/playbooks
   ansible-playbook full-staging-setup-baremetal.yaml -i ../inventory/inventory.yaml
   ```

   This produces `/tmp/staging-export/sno-bastion-bundle-<cluster_name>.tar.gz` by
   default (physical-media transfer) — copy it to the bastion and extract it into an
   empty working directory there (e.g. `~/sno-deploy/`). To push it over the network
   instead, set `bastion_transfer_method: rsync` (and the matching
   `bastion_transfer_*` vars) in `staging/inventory/inventory.yaml` — see
   `staging/roles/common/package_bastion_bundle`'s README.

3. On the bastion, from inside the extracted bundle's `bastion/playbooks` directory,
   run the full production rollout:

   ```bash
   cd bastion/playbooks
   ansible-playbook full-bastion-setup-baremetal.yaml -i ../inventory/inventory.yaml
   ```

   Or step by step:

   ```bash
   ansible-playbook provision-sno-baremetal.yaml -i ../inventory/inventory.yaml
   ansible-playbook configure-storage.yaml    -i ../inventory/inventory.yaml
   ansible-playbook configure-metallb.yaml    -i ../inventory/inventory.yaml
   ansible-playbook configure-logging.yaml    -i ../inventory/inventory.yaml
   ansible-playbook configure-tracing.yaml    -i ../inventory/inventory.yaml
   ansible-playbook configure-alerting.yaml   -i ../inventory/inventory.yaml
   ansible-playbook configure-backup-dr.yaml  -i ../inventory/inventory.yaml
   ansible-playbook configure-middleware.yaml -i ../inventory/inventory.yaml
   ```

4. Tear down (destructive — see the role's own guard):

   ```bash
   ansible-playbook destroy-sno-baremetal.yaml -i ../inventory/inventory.yaml
   ```

## Quick start (AWS test loop)

See `aws-infra/README.md` for the one-time AWS credential setup and host
provisioning, and `docs/aws-test-environment-architecture.md` §4 for the full phase
sequence (provision hosts → clone this repo onto the staging host → run
`full-staging-setup-aws.yaml` → transfer the bundle to the bastion → run
`full-bastion-provision-aws.yaml` → transfer the install-config back to staging → run
`provision-sno-aws.yaml` → transfer the kubeconfig back to the bastion → run
`full-bastion-configure-aws.yaml`). Tear down with `staging/playbooks/
destroy-sno-aws.yaml` **then** `aws-infra/playbooks/destroy-hosts.yaml`, in that
order (§7 of the AWS doc).

See `staging/README.md` and `bastion/README.md` for the full variable reference on
each side.
