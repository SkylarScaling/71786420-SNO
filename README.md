# SNO Bare-Metal Production Automation

Ansible automation that builds, configures, and maintains a Single Node OpenShift
(SNO) platform on a single bare-metal server (single server, single switch, single
bastion), as a repeatable, disconnected deployment.

The platform runs **fully disconnected (air-gapped)** — the SNO node and its bastion
have no internet route at all, and are not assumed to have a live network path to the
staging host either. This automation is split into two fully independent top-level
trees for that reason:

- **`staging/`** — runs directly on the internet-connected staging host (`hosts:
  localhost`). Mirrors release/operator content and the install-time binaries to
  disk, then packages everything the bastion needs — content, binaries, the entire
  `bastion/` tree, and resolved per-environment config — into one `tar.gz`.
- **`bastion/`** — runs directly on the bastion (`hosts: localhost`), once that
  tar.gz has been physically copied there (the default) or rsynced over (opt-in —
  see `staging/roles/common/package_bastion_bundle`'s README). Installs the mirror
  registry, generates and boots the agent-based install ISO, and configures every
  Day 2 feature (storage, logging, tracing, alerting, backup/DR, middleware) against
  the live cluster.

See `docs/architectural-decisions.md` #2 for the full disconnected-mirroring
rationale.

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
`iso_http_url` are set per-environment in `staging/inventory/inventory.yaml`. The
staging/bastion bundle handoff itself is also unverified against a real two-host
transfer — see the known gaps called out in `package_bastion_bundle`'s and
`unpack_bastion_bundle`'s READMEs.

## Repository structure

```
staging/
  inventory/inventory.yaml      # THE single source of per-environment config (BMC/network/customer-specific vars) — edit here only
  playbooks/
    stage-and-package.yaml      # stage_mirror_content + package_bastion_bundle
    full-staging-setup.yaml     # imports stage-and-package.yaml
    receive-backup.yaml         # unpack_staging_backup_bundle + push_backup_to_external_s3
    group_vars/all.yaml         # generic, non-secret defaults only
  roles/common/
    stage_mirror_content        # mirror release/operator content + binaries to disk
    package_bastion_bundle      # archive content + binaries + bastion/ tree + resolved config into one tar.gz
    push_backup_to_external_s3  # backup-export relay, final hop
    unpack_staging_backup_bundle  # backup-export relay, receives the bastion's bundle
bastion/
  inventory/inventory.yaml      # minimal placeholder — localhost only
  playbooks/
    provision-sno.yaml          # unpack bundle -> prepare bastion -> mirror registry -> install-config -> agent ISO -> BMC boot -> wait for install
    destroy-sno.yaml
    configure-storage.yaml / configure-metallb.yaml / configure-logging.yaml /
    configure-tracing.yaml / configure-alerting.yaml / configure-backup-dr.yaml /
    configure-middleware.yaml
    mirror-refresh.yaml         # standalone content refresh + on-cluster app Quay
    export-backup.yaml          # periodic/on-demand app-S3-data egress out of the bastion
    upgrade-sno.yaml / simulate-node-failure.yaml
    full-bastion-setup.yaml     # provision + storage + MetalLB + logging + tracing + alerting + backup + Day 2 middleware
    group_vars/all.yaml         # placeholder — overwritten by unpack_bastion_bundle from staging's resolved config
  roles/
    common/    # bundle unpack/package, mirror registry install, install-config rendering, kubeconfig wait, bastion services, backup export
    baremetal/ # bastion prep, agent ISO generation, BMC boot
    ocp/       # Day 2 features: LVMS/MCG, OADP, logging, tracing, MetalLB, middleware, upgrades, Quay
docs/          # architecture reference (provider-agnostic, customer-facing)
```

## Quick start

1. Fill in `staging/inventory/inventory.yaml` with the real BMC credentials, MAC
   address, rendezvous IP, DNS/gateway/NTP, storage device paths, SMTP, and
   backup-export vars it already has placeholders for. This is the **one** file to
   edit — everything the bastion needs is derived from it.

2. On the staging host, stage content and package the bastion bundle:

   ```bash
   cd staging/playbooks
   ansible-playbook full-staging-setup.yaml -i ../inventory/inventory.yaml
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
   ansible-playbook full-bastion-setup.yaml -i ../inventory/inventory.yaml
   ```

   Or step by step:

   ```bash
   ansible-playbook provision-sno.yaml        -i ../inventory/inventory.yaml
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
   ansible-playbook destroy-sno.yaml -i ../inventory/inventory.yaml
   ```

See `staging/README.md` and `bastion/README.md` for the full variable reference on
each side.
