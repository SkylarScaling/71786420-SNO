# What to copy into the customer (bare-metal-only) repo

This repo tests everything behind a swappable `infra_provider: aws | baremetal`
abstraction (see `CLAUDE.md`). The customer deliverable only ever runs
`infra_provider: baremetal` — none of the AWS provisioning layer, AWS test
inventory, or AWS-test-loop documentation belongs in that repo. This file lists
exactly what to copy and what to leave behind.

Provisioning/destroy entry points are already split into fully separate,
per-provider playbooks (`provision-sno-aws.yaml`/`destroy-sno-aws.yaml` vs.
`provision-sno-baremetal.yaml`/`destroy-sno-baremetal.yaml` — see CLAUDE.md's
Conventions section for why), so dropping the `aws/` side below is a straight
deletion, not a file edit.

## Copy as-is

### Top level
- `CLAUDE.md` — optional; it documents role responsibilities and conventions
  generically, but also describes the AWS test loop in detail. Either strip the
  AWS-specific sections before copying, or leave it out entirely and rely on
  `docs/bare-metal-architecture.md` (see below), which is explicitly written to be
  self-contained and customer-facing.
- `README.md`
- `requirements.txt`
- `requirements.yml`
- `.gitignore`

### docs/
- `docs/bare-metal-architecture.md` — **the customer deliverable.** Already written
  to be self-contained with no dependency on the AWS doc (see its own header note).
- `docs/architectural-decisions.md` — the disconnected-mirroring rationale applies to
  both providers; doesn't reference AWS specifics.
- `docs/high-level-design.md` — checked, contains no AWS references; copy as-is.
- **Do not copy** `docs/aws-test-environment-architecture.md` — purely about the AWS
  test loop (VPC endpoints, Route53 workarounds, ccoctl/STS, EC2 instance sizing).

### inventory/
- `inventory/baremetal/inventory.yaml` — fill in with the real customer environment
  values (it ships with placeholder/TODO values today).
- **Do not copy** `inventory/aws/` (both `inventory.yaml.j2` and any environment
  file like `sandbox249.opentlc.com.yaml`).

### playbooks/
- `playbooks/ansible.cfg`
- `playbooks/README.md`
- `playbooks/group_vars/all.yaml` — shared vars for both providers; the AWS-specific
  block inside it (`aws_sno_instance_type`, `bastion_instance_type`, etc.) is inert
  when `infra_provider: baremetal` and doesn't need to be removed, but can be trimmed
  for cleanliness.
- `playbooks/provision-sno-baremetal.yaml`
- `playbooks/destroy-sno-baremetal.yaml`
- `playbooks/infra_providers/baremetal/provision.yaml`
- `playbooks/infra_providers/baremetal/destroy.yaml`
- `playbooks/full-baremetal-production-setup.yaml`
- `playbooks/configure-alerting.yaml`
- `playbooks/configure-backup-dr.yaml`
- `playbooks/configure-logging.yaml`
- `playbooks/configure-metallb.yaml`
- `playbooks/configure-middleware.yaml`
- `playbooks/configure-storage.yaml`
- `playbooks/configure-tracing.yaml`
- `playbooks/mirror-content.yaml`
- `playbooks/export-backup.yaml`
- `playbooks/collect-diagnostics.yaml`
- `playbooks/upgrade-sno.yaml`
- `playbooks/simulate-node-failure.yaml`
- **Do not copy** `playbooks/configure-aws-env.yaml`, `playbooks/full-sno-test-setup.yaml`,
  `playbooks/provision-sno-aws.yaml`, `playbooks/destroy-sno-aws.yaml`, or
  `playbooks/infra_providers/aws/` (both `provision.yaml` and `destroy.yaml`).

### roles/
- `roles/common/**` — entirely provider-agnostic by design (CLAUDE.md's "one rule").
  Copy all of it: `configure_bastion_services`, `deploy_mirror_registry`,
  `export_backup_from_noobaa`, `generate_install_config`, `install_ocp_prerequisites`,
  `push_backup_to_external_s3`, `push_backup_to_internal_target`,
  `stage_mirror_content`, `sync_backup_to_staging`, `sync_mirror_to_bastion`,
  `collect_must_gather`, `wait_for_sno_install`.
- `roles/baremetal/**` — all of it: `baremetal_boot_node_via_bmc`,
  `baremetal_destroy_sno`, `baremetal_generate_agent_iso`, `baremetal_prepare_bastion`.
- `roles/ocp/**` — entirely provider-agnostic by design. Copy all of it: every
  `configure_*` role (alerting, grafana, keycloak, log_forwarding, lokistack, lvms,
  mcg, mcg_backup_export, metallb, oadp_backup, onprem_quay, opentelemetry, postgres,
  rabbitmq, redis), plus `simulate_node_failure` and `sno_upgrade`.
- **Do not copy** `roles/aws/**` at all: `aws_configure_manual_credentials`,
  `aws_configure_manual_dns`, `aws_destroy_sno`, `aws_provision_bastion`,
  `aws_provision_mirror_staging_host`, `aws_provision_network`,
  `aws_provision_sno_ipi` — every one of these exists only to work around AWS's own
  infrastructure quirks (VPC endpoints, EC2, Route53, IAM) and has no bare-metal
  equivalent or purpose.

## Never copy

- `temp/` — personal scratch directory, not part of the automation. Also currently
  contains customer-named files that must not end up in a shared/delivered repo
  regardless of this exercise.
- `.idea/`, `.claude/` — editor/tooling state, not part of the deliverable.
- Anything under `inventory/*/` containing real credentials, BMC passwords, or SMTP
  secrets for a specific environment — these are per-environment and sensitive; the
  customer repo should carry a template/placeholder inventory (as
  `inventory/baremetal/inventory.yaml` already is today), with real values supplied
  separately (e.g. via `ansible-vault`), never committed directly.

## Suggested copy command

Run from a clone of this repo, into an empty target directory:

```bash
rsync -a --exclude='.git' --exclude='temp/' --exclude='.idea/' --exclude='.claude/' \
  --exclude='inventory/aws/' --exclude='docs/aws-test-environment-architecture.md' \
  --exclude='playbooks/configure-aws-env.yaml' \
  --exclude='playbooks/full-sno-test-setup.yaml' \
  --exclude='playbooks/provision-sno-aws.yaml' \
  --exclude='playbooks/destroy-sno-aws.yaml' \
  --exclude='playbooks/infra_providers/aws/' \
  --exclude='roles/aws/' \
  ./ /path/to/customer-repo/
```

No follow-up edits needed — every remaining playbook in the destination already works
standalone, since provisioning/destroy are per-provider files rather than one
dispatcher that referenced both.
