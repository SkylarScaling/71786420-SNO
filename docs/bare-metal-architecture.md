# Bare-Metal Production Architecture

**Status: living document — maintain alongside the automation.** Whenever a role,
playbook, or variable referenced here changes, update this doc in the same change.
When they drift, treat this doc as wrong until reconciled, not the automation —
verify against the actual `roles/`/`playbooks/` tree before trusting a stale
description here.

This is the implementation reference for the **bare-metal production** Single Node
OpenShift (SNO) platform this repo builds — what's deployed, why, and which
role/playbook owns it. It's written to be shared with the customer as well as used
internally — parameters are described generically (as the variables this repo
already uses), with real per-environment values (IPs, hostnames, credentials) living
only in `inventory/baremetal/inventory.yaml`, never in this document, so the
automation stays reusable across environments/deployments.

This document describes the bare-metal production target only, and can be lifted
out of this repo on its own (alongside `architectural-decisions.md`) as the
standalone design reference for the customer deployment.

See [`architectural-decisions.md`](architectural-decisions.md) for the *why* behind
specific carried-forward design patterns (disconnected mirroring, backup storage
isolation). This document is the current-state *what or where*: the full system as
built, and a traceability table back to the customer's stated requirements.

## 1. Target environment

| Item | Value |
|---|---|
| Topology | Single Node OpenShift — single server, single switch (default) or dual switch (opt-in), single bastion |
| Server | Dell PowerEdge R7725, iDRAC9/10 (Redfish), 768GB RAM |
| Disks | 3x 3.2TB SSD + 2x 960GB NVMe, hardware RAID5 (≤6TB usable), no OCP-level storage replication on top |
| Networking | 1G. Single NIC per function by default; dual-switch active-backup bonding on the SNO node is opt-in (§5) |
| Install method | Agent-Based Installer (disconnected) |
| DNS / NTP | Customer-provided (Windows DNS, NTP server) — see §9 |
| Connectivity | Fully disconnected — the SNO node and bastion have no internet route at all |
| Subscription | OpenShift Platform Plus (entitles the operators used throughout) |

## 2. Two-host disconnected topology

This repo models the customer's own description of their network
("jumphost with internet → jumphost/disconnected bastion → cluster environment"):

```
Internet ── mirror-staging host ──(private network / single switch)── bastion ── SNO node
            (only internet-         (disconnected mirror registry,     (no internet route
             connected host)         DNS/NTP-adjacent services,         at all)
                                      backup relay hop)
```

| Role | Implementation (`roles/baremetal/*`) |
|---|---|
| Mirror-staging host | `mirror_staging_host` inventory group — a real internet-connected host on the customer's network |
| Bastion | `bastion` inventory group — the physical single bastion, no internet route |
| SNO node | The physical server, agent-based install |

The bastion needs real headroom, not just connectivity: `deploy_mirror_registry`
installs `mirror-registry`, which runs Quay+Redis+Postgres as concurrent containers.
A 4GB/no-swap test host hard-hung under that load — confirmed by the hypervisor's own
instance-status check as guest-level unresponsiveness, not a host fault — and needed
8GB to install cleanly. Size the physical bastion accordingly.

It matters here because every content-movement mechanism in this repo (inbound
mirroring *and* backup export, §3/§8) depends on it: nothing ever assumes the
cluster or bastion can reach the internet directly.

## 3. Disconnected content mirroring (inbound)

See `architectural-decisions.md` §2 for full rationale. Pipeline:
`roles/common/stage_mirror_content` (mirror-staging host, "mirror to disk") →
`roles/common/sync_mirror_to_bastion` (rsync or physical media) →
`roles/common/deploy_mirror_registry` (bastion, "disk to mirror" — installs
`mirror-registry`/Quay and is what `generate_install_config`'s
`imageContentSources`/`additionalTrustBundle` always point at, and whose generated
credentials `generate_install_config` also merges into `pullSecret` — without that,
nothing on the node can authenticate to pull images from it, which otherwise
manifests as bootstrapping silently timing out rather than a clear auth error). The
bastion has no
internet route at all (§2), so it can't fetch the `mirror-registry`/`oc-mirror` tool
tarballs itself either — `stage_mirror_content` downloads both on the
internet-connected mirror-staging host under `mirror_installers_dir`, and
`sync_mirror_to_bastion` carries them over the same way it carries the content
archive; `deploy_mirror_registry` unarchives them from that synced local copy. The
bastion's own OS packages (`dnsmasq`/`httpd`, installed by
`roles/common/configure_bastion_services`) go through the identical path —
`stage_mirror_content` resolves their full dependency closure into
`mirror_installers_dir/bastion-rpms` via `dnf install --downloadonly`, and
`configure_bastion_services` installs from that synced copy with `disablerepo: '*'`,
since a direct `dnf install` on the bastion itself fails (RHUI has no route either).

`oc_mirror_operator_packages` (role default in `stage_mirror_content`) controls which
operators get mirrored — entries are either a bare package name (default catalog
channel) or a `{name, channel}` dict to pin a non-default channel, or a
`{name, channel, catalog}` dict when a package ships from a different operator index
(`certified`/`community`/`marketplace` rather than the default `redhat` index — see
the role's `defaults/main.yaml` for the confirmed values used by the roles below).
Every feature role below that installs an operator needs its package present in this
list with a matching channel/catalog.

`sync_mirror_to_bastion` and (for backup export, §8) `sync_backup_to_staging` rsync
directly between the mirror-staging host and the bastion over the private network
they share (§2) — not through the controller. Since `ansible.posix.synchronize`
needs real SSH credentials on whichever host actually originates that rsync, both
roles temporarily stage a copy of the same `ssh_private_key` both hosts already
trust (the same authorized key on both) for just that one task, then remove it —
see either role's README for why (a real, previously-hit bug: getting the
`synchronize`+`delegate_to` direction wrong there fails opaquely as a connection
timeout rather than an obviously-wrong-direction error).

Post-install, `roles/ocp/configure_onprem_quay` deploys a separate, long-term
on-cluster Quay for application images going forward — the bastion's
`mirror-registry` is install-time only. Deliberately **non-HA** (`quay_replicas: 1`,
`clair`/`mirror` components unmanaged) — no availability requirement at this scale,
and a smaller footprint matters more than registry redundancy on a true SNO. Keeps
its own dedicated single-instance Postgres+Redis (operator-managed) rather than
sharing the application's `configure_postgres`/`configure_redis`, to avoid coupling
Quay's availability to the application database's.

## 4. Storage

| Layer | Role | Purpose |
|---|---|---|
| Block (PVCs) | `roles/ocp/configure_lvms` | True-SNO default — carves the RAID5 volume (`lvms_device_paths`) into PVs for everything below that needs one |
| S3-compatible object storage | `roles/ocp/configure_mcg` | Standalone Multicloud Object Gateway (NooBaa), **no CephCluster** |

**Why standalone MCG, not full ODF/Ceph (`StorageCluster` mode):** the hardware
RAID5 array already provides disk-level redundancy. Running Ceph's own 3x
replication on top — even forced to `replica: 1` — adds OSD/mon/mgr operational
weight for no additional resiliency. Full ODF/Ceph is not implemented in this repo —
this is a true single-node deployment and will not scale out.

`configure_mcg` exposes `mcg_s3_endpoint`/`mcg_s3_access_key`/`mcg_s3_secret_key` as
facts for every other role that needs an S3 bucket (Loki, Tempo, the backup export
relay, and the application itself via its connectors).

**Storage classes**: `configure_lvms` creates two — `vg1` (LVMS's own, `Delete`
reclaim, immutable) used by RabbitMQ, Redis, LokiStack, TempoStack, and MCG's own
backing PVC; and `vg1-retain` (a plain `StorageClass` pointed at the same underlying
`vg1` device class via topolvm's `topolvm.io/device-class` parameter, `Retain`
reclaim), defaulted to by `roles/ocp/configure_postgres` only — Postgres is the one
workload here whose data has no separate durable copy elsewhere, so Retain closes the
gap between `configure_oadp_backup`'s backup windows. See `configure_lvms`'s README.

## 5. Networking

- **Application HTTP(S) ingress**: the default OCP Ingress Controller. SNO's single
  node IP serves this role directly — there is no API/Ingress VIP anywhere in this
  repo.
- **Non-HTTP TCP middleware** (AMQP, Postgres, Redis): `roles/ocp/configure_metallb`
  provisions an `IPAddressPool` (`metallb_address_pool`, a customer-provided
  range/CIDR) + `L2Advertisement`, consumed by `configure_rabbitmq`/
  `configure_postgres`/`configure_redis`'s optional `type: LoadBalancer` Services
  (`*_expose_external`, default `false`/ClusterIP).
- **NIC bonding / switch topology**: `roles/baremetal/baremetal_generate_agent_iso`
  selects via `sno_network_topology` — `single_switch` (default): one NIC per
  function, no bonding, matching the production default topology. `dual_switch`
  (opt-in): bonds two NICs on the SNO node (`active-backup`) across two ToR switches
  for switch-level redundancy, requiring a second physical NIC on the server. This is
  **SNO-node-only** — the bastion's own NICs aren't configured by this automation at
  all (`baremetal_prepare_bastion` only validates reachability against pre-existing,
  pre-configured hardware), so bastion-side switch redundancy, if wanted, is a manual/
  physical concern outside this repo. See that role's README for the exact vars.

## 6. Logging, tracing & alerting

| Capability | Role(s) | Notes |
|---|---|---|
| Log storage | `roles/ocp/configure_lokistack` | Loki, S3-backed via `configure_mcg`. 30-day total retention (`loki_retention_days`), 7-day override on the `application` stream (`loki_hot_retention_days`) as the closest LokiStack approximation of a two-tier hot/total retention requirement — **not real storage tiering**, see the role's README. |
| Dashboards | `roles/ocp/configure_grafana` | Datasources wired to LokiStack and (if tracing is enabled) Tempo. |
| External SIEM forwarding | `roles/ocp/configure_log_forwarding` | `ClusterLogForwarder` has two outputs side by side: a `lokiStack` output (`loki_output_enabled`, default `true`) — the production path — and an external syslog output (`log_forward_endpoint`). **The syslog output is a placeholder, not production-ready**: the real external SIEM target and its auth model (token vs. mTLS) aren't finalized, and the RBAC it needs isn't wired up yet (see role README). |
| Application tracing | `roles/ocp/configure_opentelemetry` | OpenTelemetry Collector (OTLP receiver) + Tempo, S3-backed via `configure_mcg`. Gives the application an OTLP endpoint to send traces to. |
| Email alerting | `roles/ocp/configure_alerting` | Patches the cluster Alertmanager config with an email receiver pointed at a customer-provided SMTP server (`alert_smtp_host`/`alert_email_to`). **Assumes direct network reachability** — same site, not internet; this role doesn't stand up a relay. Known limitation: replaces rather than merges any existing custom Alertmanager config (see role README). |

## 7. Day 2 application platform

The customer is handed a fully working application, not a bare cluster — this repo
deploys its middleware too:

| Component | Role | Notes |
|---|---|---|
| Message queue | `roles/ocp/configure_rabbitmq` | RabbitMQ Cluster Operator, confirmed shipping from `community-operators` (not `redhat-operators`), channel `stable`. |
| Database | `roles/ocp/configure_postgres` | Crunchy PGO, confirmed shipping from `certified-operators` (not `redhat-operators`), channel `v5`, plus a plain pgAdmin Deployment (pgAdmin has no operator). pgAdmin's container image isn't covered by `oc_mirror_operator_packages` (that's operator-catalog-only) — needs separate image-mirroring handling, not yet solved (see role README). |
| Cache | `roles/ocp/configure_redis` | Plain StatefulSet, **no operator** (Redis Enterprise needs separate licensing beyond the Platform Plus entitlement; a community operator wasn't judged necessary) — matches "no current HA needs" and the customer's cost/simplicity priority. |
| Auth | `roles/ocp/configure_keycloak` | Red Hat build of Keycloak Operator. Depends on `configure_postgres` for its database backend — the exact generated Service/Secret names it assumes are flagged in the role README as needing live-cluster verification, and nothing yet provisions the `keycloak` database/user on the PostgresCluster itself (gap, not yet solved). |

All four default to LVMS-backed PVCs and single replica (no HA requirement stated by
the customer).

## 8. Backup, DR & external export

Two independent concerns:

1. **In-cluster backup/restore**: `roles/ocp/configure_oadp_backup` (OADP) targets
   the in-cluster NooBaa provided by `configure_mcg` — the only backend this role
   supports. An external cloud S3 bucket backend was considered early on but
   removed: **this deployment has no internet route at all**, so an external-S3
   backend would just time out. The role also creates a default Velero `Schedule` CR
   (`oadp_backup_schedule_name`/`oadp_backup_schedule_cron`/`oadp_backup_ttl`/
   `oadp_backup_excluded_namespaces`) — a once-daily, 30-day-retention full backup as
   a general-purpose baseline, not a customer-confirmed RPO/RTO; override per
   environment once real targets are agreed. DR restore rehearsal (actually running
   `velero restore create` against one of these backups) is not automated — see the
   role's README.
2. **External export, off the node entirely**: RAID5 protects against a single disk
   failing; it does nothing for losing the whole chassis. The customer wants
   application S3 data (and, separately/not yet built, log data) exported
   somewhere off the node. A genuine internet-reachable external S3 target is the
   **least likely** of the three export paths to actually exist on a deployment
   like this — don't assume it by default. The realistic options are manual
   removable media, or pushing to a backup system the customer already runs on the
   same disconnected network as the bastion.

**The cluster has no internet route** (§2), so external export cannot be a
continuously-running in-cluster CR (an earlier attempt at this — a NooBaa
`BackingStore` pointed directly at an external endpoint — was built, found to be
architecturally impossible, and removed; don't reintroduce it). Instead,
`playbooks/export-backup.yaml` always stages data on the bastion first
(`export_backup_from_noobaa`, same private network as the SNO node), then takes one
of three paths out, selected by `backup_egress_mode` (set per environment), run
periodically/on-demand — there's no always-on path, so this isn't part of the
initial setup playbooks:

- **`media`** (default): no further automation — manually copy the bastion's staged
  export to removable media (no API exists for "replicate a bucket to a USB
  drive"). Assumes nothing about what the customer's network allows, so it's the
  safe default.
- **`internal`**: `push_backup_to_internal_target` (runs on the bastion) pushes the
  staged data straight to an S3-compatible backup system the customer already runs
  on the *same disconnected network* — no internet route needed. Prefer this over
  `network` once the customer's on-prem backup target is confirmed; it's the more
  realistic automated path for this kind of deployment.
- **`network`** / **`both`**: relays data through the same two hosts the inbound
  mirroring pipeline uses, reversed, all the way to a real internet-reachable
  external S3 target:

  ```
  NooBaa (SNO node) → export_backup_from_noobaa (bastion, same private network)
                    → sync_backup_to_staging (bastion → mirror-staging, reverse of sync_mirror_to_bastion)
                    → push_backup_to_external_s3 (mirror-staging, the only host with real internet)
                    → real external S3 target
  ```

  Unlikely to apply on a genuinely disconnected production deployment — only use
  this if the customer has explicitly confirmed that outbound path exists. `both`
  also leaves the staged bastion copy in place for an additional manual media
  export.

`roles/ocp/configure_mcg_backup_export` only validates the target vars for whichever
mode is active (`backup_internal_target_*` for `internal`, `backup_external_s3_*`
for `network`/`both`) — it applies no CRs.

**Log/metrics export is explicitly out of scope / not yet built** — don't assume
`backup_egress_mode` covers Loki data.

## 9. DNS and NTP

Customer-provided Windows DNS and NTP servers — not automated by this repo (the
`dns_server`/`ntp_server` inventory vars just point the node at them;
`roles/common/configure_bastion_services`'s dnsmasq is only used when no external DNS
is provided, e.g. a bare-metal lab run without customer DNS).

**DNS records the customer's DNS admin needs to create** against `base_domain`:

| Record | Points to | Used for |
|---|---|---|
| `api.<cluster_name>.<base_domain>` | SNO node IP | API access — must be created manually since there's no automated DNS provider on bare metal |
| `api-int.<cluster_name>.<base_domain>` | SNO node IP | internal API access (bootstrap/cluster-internal) |
| `*.apps.<cluster_name>.<base_domain>` | SNO node IP | application/console ingress (wildcard) |
| `mirror.<base_domain>` | bastion IP | the install-time mirror registry (`mirror_registry_quay_hostname`) |
| Application-specific hostnames (Keycloak, RabbitMQ management UI, pgAdmin, etc.) | SNO node IP (via Route) or the MetalLB pool IP for LoadBalancer-exposed services | customer/app-team to finalize the exact list once the application's own Routes/Ingress are defined |

`additionalNTPSources` in `install-config.yaml` is set from `ntp_server` when defined
(`roles/common/generate_install_config`).

## 10. Hardware provisioning

`roles/baremetal/baremetal_boot_node_via_bmc` mounts the agent ISO via BMC virtual
media and power-cycles the node — implemented against Dell iDRAC9/10 using standard
Redfish (`community.general.redfish_command`/`redfish_info`), no vendor-specific
payload beyond the fixed iDRAC resource IDs. **Unverified against real hardware** —
no live BMC to test against yet; see the role's README before the first real run.

## 11. Support & lifecycle

- **Upgrades**: `roles/ocp/sno_upgrade`, quarterly or on-demand per the customer's
  stated cadence. Rollback is via OADP restore, not `oc adm upgrade` rollback — SNO
  has no second control plane to fail over to. After the upgrade completes, the role
  runs `oc adm prune images` (`sno_upgrade_prune_images`, default on) to reclaim space
  from superseded release/operator/machine-os images — this is a disk-constrained
  single-node cluster on a fixed RAID5 pool, and the upgrade itself doesn't purge
  anything. The on-cluster Quay registry (`configure_onprem_quay`, application images)
  has no equivalent GC/retention policy configured yet — see that role's and
  `sno_upgrade`'s READMEs.
- **Node failure drill**: `roles/ocp/simulate_node_failure`, gated behind
  `simulate_node_failure_confirm: true`.
- **Must-gather / support escalation**: not yet automated as a role — customer's
  stated process is `oc adm must-gather`, then either open a Red Hat support ticket
  directly or route through their internal support org. Worth a small role if this
  needs to be repeatable/scripted; currently a manual runbook step.

## 12. Requirements traceability

Maps the customer's stated requirements (from the architecture/requirements review)
to the implementing automation, so gaps are visible rather than assumed covered.

| Requirement | Implementation | Status |
|---|---|---|
| S3-compatible storage, RAID5-backed | `configure_lvms` + `configure_mcg` | Built; NooBaa CRD field names flagged for live-cluster verification |
| 6TB RAID5, no OCP-level replication | MCG standalone (no CephCluster) | Built |
| External backup, no data loss tolerance for app data | OADP + `export-backup.yaml` relay | Built; log/metrics export not yet built |
| Loki + Grafana, 7-day/30-day retention | `configure_lokistack` + `configure_grafana` | Built; retention approximated via per-stream override, see §6 |
| OpenTelemetry application tracing | `configure_opentelemetry` | Built; operator package names flagged for verification |
| Email alerting | `configure_alerting` | Built; assumes direct SMTP reachability |
| Must-gather / support ticket workflow | — | Manual runbook only, not automated |
| Dell R7725, iDRAC10, agent-based install | `baremetal_boot_node_via_bmc`, `baremetal_generate_agent_iso` | Built; unverified against real hardware |
| Single/dual switch topology, opt-in NIC bonding on the SNO node | `sno_network_topology` in `baremetal_generate_agent_iso` | Built; unverified against real dual-NIC hardware |
| Customer DNS/NTP | `dns_server`/`ntp_server` inventory vars | Built; DNS record list documented in §9, not automated against the customer's Windows DNS |
| KeyCloak auth | `configure_keycloak` | Built; Postgres service/secret name assumptions flagged |
| MetalLB VIP range | `configure_metallb` | Built; for non-HTTP TCP middleware only, not app ingress — confirm this matches customer intent for the range they provided |
| RabbitMQ, Postgres/pgAdmin, Redis | `configure_rabbitmq`/`configure_postgres`/`configure_redis` | Built; catalog source and image-mirroring gaps flagged, see §7 |
| Single node, single bastion, single switch | Two-host disconnected topology, §2 | Already-existing design |

## 13. Open items before first production run

Consolidated from the "verify against a live cluster" notes scattered across
individual role READMEs — resolve these on the first real run against mirrored
content / the actual hardware, don't assume they're already correct:

- ~~Operator catalog channel/package names: Loki, Grafana, RabbitMQ Cluster
  Operator, Crunchy PGO~~ — confirmed against the redhat/certified/community
  operator indexes for `openshift_version: 4.22` via `oc-mirror list operators`:
  `loki-operator` is `stable-6.6` (redhat-operators — **this channel string moves
  with every OCP minor**, re-verify against the new version's index on upgrade);
  `grafana-operator` is `v5` (**community-operators**, not redhat-operators);
  `rabbitmq-cluster-operator` is `stable` (**community-operators**);
  `crunchy-postgres-operator` is `v5` (**certified-operators**).
  `oc_mirror_operator_packages` now supports a per-package `catalog:` key so
  `stage_mirror_content` mirrors each from the right index — see
  `roles/common/stage_mirror_content/defaults/main.yaml`.
- OpenTelemetry/Tempo, Keycloak (`rhbk-operator` vs `keycloak-operator`)
  channel/package names — not yet independently confirmed
  (no error surfaced against these in the first real mirroring run, but that only
  confirms the package/channel *exist*, not that they're the intended ones).
- CRD field names: NooBaa standalone backing-store fields, LokiStack/TempoStack
  storage-secret and retention field paths.
- Generated Service name assumptions used for cross-role wiring (LokiStack
  query-frontend, Tempo distributor, Keycloak's Postgres service).
- pgAdmin's plain container image needs a separate mirroring mechanism (not covered
  by `oc_mirror_operator_packages`).
- Keycloak's database/user isn't yet provisioned on the PostgresCluster.
- `roles/baremetal/baremetal_boot_node_via_bmc` unverified against real iDRAC
  hardware.
- `sno_network_topology: dual_switch` (`roles/baremetal/baremetal_generate_agent_iso`)
  unverified against real dual-NIC hardware — the bonded nmstate syntax hasn't been
  tested against a live Agent-Based install yet.
- `mirror_registry_version` (`roles/common/stage_mirror_content/defaults/main.yaml`,
  currently `2.0.12`) is a pinned point-in-time version, not a "latest" alias — Red
  Hat's own `latest/` path requires a cookie-based redirect a plain `get_url` can't
  follow. Re-verify against
  https://mirror.openshift.com/pub/cgw/mirror-registry/ before a production run if
  it's been a while; a stale pin still works (older `mirror-registry` versions remain
  downloadable), it just won't have newer fixes.
