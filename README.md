# SNO Bare-Metal Production Automation

Ansible automation that builds, configures, and maintains a Single Node OpenShift
(SNO) platform on a single bare-metal server (single server, single switch, single
bastion), as a repeatable, disconnected deployment.

The platform runs **fully disconnected (air-gapped)** — the SNO node and its bastion
have no internet route at all. Required content (OpenShift release images, Operator
catalogs, application images) is prepared on a separate internet-connected host and
relayed in through a mirroring pipeline (`roles/common/stage_mirror_content` →
`sync_mirror_to_bastion` → `deploy_mirror_registry`) — see
`docs/architectural-decisions.md` #2.

## Architecture design documents

[`docs/bare-metal-architecture.md`](docs/bare-metal-architecture.md) is the full
implementation reference — what's deployed, why, which role/playbook owns it, and a
requirements-traceability table back to the customer's stated requirements. It's a
living document: update it alongside any role/playbook change, and treat it (not
memory of what was built) as the source of truth for what this repo currently does.

[`docs/architectural-decisions.md`](docs/architectural-decisions.md) covers the
narrower *why* behind specific carried-forward design patterns (disconnected content
mirroring, OADP backup/DR storage isolation).

## Status

Implemented using the Agent-Based Installer pattern against the target production
hardware (Dell PowerEdge R7725, iDRAC9/10). ISO generation and BMC virtual-media boot
(standard Redfish via `community.general.redfish_command`) are both implemented;
**still unverified against real hardware** (no live BMC tested against yet) and will
fail fast with a clear message until `bmc_address`/`bmc_username`/`bmc_password`/
`iso_http_url` are set per-environment in `inventory/baremetal/inventory.yaml`.

## Repository structure

```
inventory/
  baremetal/inventory.yaml    # bastion + mirror-staging hosts, BMC/network/customer-specific vars
playbooks/
  provision-sno-baremetal.yaml   # imports infra_providers/baremetal/provision.yaml (always mirrors content as part of provisioning)
  destroy-sno-baremetal.yaml     # imports infra_providers/baremetal/destroy.yaml
  full-baremetal-production-setup.yaml  # prereqs + provision + storage + MetalLB + logging + tracing + alerting + backup + Day 2 middleware
  configure-storage.yaml          # LVM Storage (LVMS, default) + MCG (S3)
  configure-backup-dr.yaml        # OADP backup/DR (in-cluster NooBaa) + external S3 export config validation
  configure-logging.yaml          # LokiStack + Grafana + external SIEM forwarding
  configure-tracing.yaml          # OpenTelemetry Collector + Tempo
  configure-alerting.yaml         # email alerting via customer SMTP
  configure-metallb.yaml          # non-HTTP TCP middleware LoadBalancer IPs
  configure-middleware.yaml       # RabbitMQ, Postgres (+pgAdmin), Redis, Keycloak
  mirror-content.yaml             # standalone content refresh + on-cluster app Quay
  export-backup.yaml              # periodic/on-demand app-S3-data egress, relayed via bastion -> mirror-staging (no internet route on the cluster)
  upgrade-sno.yaml                # minimal-downtime upgrade
  simulate-node-failure.yaml      # reboot/recovery drill
  infra_providers/
    baremetal/{provision,destroy}.yaml
roles/
  common/        # mirror staging/sync/registry, install-config rendering, kubeconfig wait, bastion services
  baremetal/     # bastion prep, agent ISO generation, BMC boot
  ocp/           # day-2 features: LVMS/MCG, OADP, logging, tracing, MetalLB, middleware, upgrades, Quay
```

## Quick start

1. Fill in `inventory/baremetal/inventory.yaml` with the real bastion and
   mirror-staging host details, and the BMC credentials, MAC address, rendezvous IP,
   DNS/gateway/NTP, storage device paths, SMTP, and backup-export vars it already has
   placeholders for.

2. Install local prerequisites and run the full production rollout:

   ```bash
   ansible-playbook playbooks/full-baremetal-production-setup.yaml \
     -i inventory/baremetal/inventory.yaml
   ```

   Or step by step:

   ```bash
   ansible-playbook playbooks/provision-sno-baremetal.yaml -i inventory/baremetal/inventory.yaml
   ansible-playbook playbooks/configure-storage.yaml       -i inventory/baremetal/inventory.yaml
   ansible-playbook playbooks/configure-metallb.yaml       -i inventory/baremetal/inventory.yaml
   ansible-playbook playbooks/configure-logging.yaml       -i inventory/baremetal/inventory.yaml
   ansible-playbook playbooks/configure-tracing.yaml       -i inventory/baremetal/inventory.yaml
   ansible-playbook playbooks/configure-alerting.yaml      -i inventory/baremetal/inventory.yaml
   ansible-playbook playbooks/configure-backup-dr.yaml     -i inventory/baremetal/inventory.yaml
   ansible-playbook playbooks/configure-middleware.yaml    -i inventory/baremetal/inventory.yaml
   ```

3. Tear down (destructive — see the role's own guard):

   ```bash
   ansible-playbook playbooks/destroy-sno-baremetal.yaml -i inventory/baremetal/inventory.yaml
   ```

See `playbooks/README.md` for the full variable reference.
