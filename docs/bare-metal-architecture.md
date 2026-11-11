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
only in `staging/inventory/inventory.yaml`, never in this document, so the
automation stays reusable across environments/deployments.

This document describes the bare-metal production target only, and can be lifted
out of this repo on its own (alongside `architectural-decisions.md`) as the
standalone design reference for the customer deployment.

See [`architectural-decisions.md`](architectural-decisions.md) for the *why* behind
specific carried-forward design patterns (disconnected mirroring, backup storage
isolation). This document is the current-state *what or where*: the full system as
built, and a traceability table back to the customer's stated requirements.

## Prerequisites (outside this automation)

Nothing in this list is provisioned or validated by this repo — these are inputs
the automation assumes already exist, either supplied by the customer or prepared by
the operator running it, before any playbook is run. Several roles fail fast (loudly,
not silently) when one of these is missing, but only once a playbook actually reaches
that point — confirm the list below up front rather than discovering gaps one failed
task at a time.

**From the customer:**

| Item | Detail |
|---|---|
| Physical hardware racked, cabled, powered | Dell PowerEdge R7725, single switch (dual switch opt-in) — §10 |
| Staging host and bastion both provisioned as RHEL 10, with `rhel-10-for-x86_64-baseos-rpms`/`-appstream-rpms` attached to staging's subscription | Must match exactly — `stage_mirror_content` resolves/downloads RPMs on staging for an offline `dnf install` on the bastion (`bastion_packages`/`bastion_required_repos`); a version mismatch installs cleanly on neither host or silently resolves the wrong RPM set — §1 |
| iDRAC9/10 reachable from the bastion's network, with BMC credentials | `bmc_address`/`bmc_username`/`bmc_password` — §10 |
| Static IP/gateway/MAC assignments for the SNO node (and the bastion itself) | `rendezvous_ip`, `sno_mac_address`, `default_gateway`, `machine_network_cidr` — this repo consumes these, it doesn't assign them |
| DNS records created against `base_domain` | `mirror.<base_domain>`, `api.`/`api-int.`/`*.apps.<cluster_name>.<base_domain>`, plus app-specific hostnames — full list and purpose in §9 |
| NTP server reachable from the SNO node/bastion network | `ntp_server` — §9 |
| SMTP relay reachable from the cluster network | `alert_smtp_host`/`alert_email_to` — `configure_alerting` assumes direct reachability, it doesn't stand up a relay |
| MetalLB address pool: a contiguous, routable, reserved IP range on the machine network | `metallb_address_pool` — §5; non-HTTP TCP middleware only |
| External S3 target (endpoint, bucket, credentials), only if `backup_egress_mode: network` or `both` | `backup_external_s3_*` — §8 |
| Outbound firewall egress from the staging host to Red Hat's content sources | `registry.redhat.io`, `quay.io`, `mirror.openshift.com`, `console.redhat.com` and friends — §3; the bastion and SNO node need no egress at all |
| A way to physically carry the bastion bundle from staging to the bastion | Removable media by default (`bastion_transfer_method: media`); a network path between the two hosts only if `rsync` is opted into instead — §2 |

**From the operator running this automation (prepared once per environment, before
`staging/inventory/inventory.yaml` is filled in):**

| Item | Detail |
|---|---|
| Red Hat pull secret | From [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) under an account entitled to OpenShift Platform Plus (§1) — saved locally and referenced via `pull_secret`'s `lookup('file', ...)` |
| SSH key pair for the staging host's own OS access | `ssh_key`/`ssh_private_key` — not related to the mirror-registry-internal SSH key `deploy_mirror_registry` generates for itself on the bastion |
| Confirmed RAID5 block device path on the actual racked hardware | `lvms_device_paths` — can't be known until the server exists; see §13 |

If a value above isn't a real per-environment value yet, `staging/inventory/inventory.yaml`
marks it with a `TODO:` comment — grep for `TODO:` there before a first run against a
new environment.

## 1. Target environment

| Item | Value |
|---|---|
| Topology | Single Node OpenShift — single server, single switch (default) or dual switch (opt-in), single bastion |
| Server | Dell PowerEdge R7725, iDRAC9/10 (Redfish), 768GB RAM |
| OS | RHEL 10 on both the staging host and the bastion — must match exactly, see Prerequisites above |
| Disks | 3x 3.2TB SSD + 2x 960GB NVMe, hardware RAID5 (≤6TB usable), no OCP-level storage replication on top |
| Networking | 1G. Single NIC per function by default; dual-switch active-backup bonding on the SNO node is opt-in (§5) |
| Install method | Agent-Based Installer (disconnected) |
| DNS / NTP | Customer-provided (Windows DNS, NTP server) — see §9 |
| Connectivity | Fully disconnected — the SNO node and bastion have no internet route at all |
| Subscription | OpenShift Platform Plus (entitles the operators used throughout) |

## 2. Two-host disconnected topology

This repo models the customer's own description of their network
("jumphost with internet → jumphost/disconnected bastion → cluster environment"), and
is itself split into two fully independent automation trees that mirror that
topology — `staging/` and `bastion/` (see the root `README.md`). Each tree only ever
runs against its own host as `localhost`; there is no assumption of a live network
path between the two, let alone a third controller with reach into both:

```
Internet ── staging host ──(physical media by default, rsync opt-in)── bastion ── SNO node
            (only internet-    (disconnected mirror registry,          (no internet route
             connected host,    DNS/NTP-adjacent services,              at all)
             runs staging/)     backup relay hop, runs bastion/)
```

| Role | Implementation |
|---|---|
| Staging host | Runs the `staging/` tree directly (`hosts: localhost`) — a real internet-connected host on the customer's network |
| Bastion | Runs the `bastion/` tree directly (`hosts: localhost`), once the staging-produced bundle has been copied over — the physical single bastion, no internet route |
| SNO node | The physical server, agent-based install |

The bastion needs real headroom, not just connectivity: `deploy_mirror_registry`
installs `mirror-registry`, which runs Quay+Redis+Postgres as concurrent containers.
A 4GB/no-swap test host hard-hung under that load — confirmed by the hypervisor's own
instance-status check as guest-level unresponsiveness, not a host fault — and needed
8GB to install cleanly. Size the physical bastion accordingly.

**8GB was only validated against the install itself, not a full sustained push** —
on a real customer run, the "disk to mirror" push (483 images, ~22 minutes) hit a
batch of `received unexpected HTTP status: 500 Internal Server Error` from the
registry's own bearer-token endpoint, spread across the run rather than one clean
cutoff (the release images, mirrored first, all succeeded; operator images, pushed
later/concurrently with heavier shared-layer dedup traffic, took the hit).

**Root cause confirmed**, directly on the customer's own bastion: `/var` was at 100%
utilization, not a RAM/CPU/connection-pool constraint as first suspected. Podman's
default storage root (`/var/lib/containers`) backs both `mirror-registry`'s own
Quay/Postgres/Redis containers and every blob `oc-mirror`/`podman`/`skopeo` stage
locally while copying — filling it up breaks container storage in a way that
surfaces as a registry-side `500 Internal Server Error`, not an obvious disk-full
error, which is what made it hard to diagnose from the customer side at first.
`deploy_mirror_registry` now fails fast up front with a `/var` free-space check
(`bastion_min_free_disk_gb`, default 100GB placeholder — tune once a real run's
actual usage is known) rather than discovering this ~20+ minutes into a push — see
that role's README.

`deploy_mirror_registry`'s push task also retries automatically (already-pushed
blobs are deduped/skipped on retry, so this is safe) — see that role's README. That
retry is still reasonable insurance for a genuinely transient overload, but it does
not fix a persistently full `/var`, which fails identically on every attempt — the
pre-flight check above is the actual fix for this failure mode.
**Open item**: confirm the customer's planned 16 cores/16GB/2TB spec leaves enough
free space under `/var` specifically (not just total disk) for a full mirror push
under real content volumes, and tune `bastion_min_free_disk_gb` once that's known.

It matters here because every content-movement mechanism in this repo (inbound
mirroring *and* backup export, §3/§8) depends on it: nothing ever assumes the
cluster, the bastion, or staging can reach each other over a live network by
default — each side acts on itself and, optionally, pushes outward.

## 3. Disconnected content mirroring (inbound)

See `architectural-decisions.md` §2 for full rationale. Pipeline:
`staging/staging/roles/common/stage_mirror_content` (staging host, "mirror to disk") →
`staging/roles/common/package_bastion_bundle` (archives content + binaries + the
entire `bastion/` tree + resolved config into one `tar.gz`; physical media by
default, rsync opt-in) → `bastion/roles/common/unpack_bastion_bundle` (bastion,
extracts the bundle) → `bastion/roles/common/deploy_mirror_registry` (bastion, "disk
to mirror" — installs `mirror-registry`/Quay and is what `generate_install_config`'s
`imageContentSources`/`additionalTrustBundle` always point at, and whose generated
credentials `generate_install_config` also merges into `pullSecret` — without that,
nothing on the node can authenticate to pull images from it, which otherwise
manifests as bootstrapping silently timing out rather than a clear auth error). The
bastion has no internet route at all (§2), so it can't fetch the
`mirror-registry`/`oc-mirror`/`openshift-install`/`oc` tool tarballs itself either —
`stage_mirror_content` downloads all of them on the internet-connected staging host
under `mirror_installers_dir`, and `package_bastion_bundle`/`unpack_bastion_bundle`
carry them over inside the bundle the same way they carry the content archive;
`deploy_mirror_registry` unarchives `mirror-registry`/`oc-mirror` from that bundled
local copy. The bundle also carries a minimal oc-mirror cache handoff
(`release-cache/`) that `deploy_mirror_registry`'s disk-to-mirror push needs for
`openshift/release`'s per-component images — oc-mirror v2's own archive format never
includes that content on its own (see `stage_mirror_content`'s README) — and a copy
of the operator's own SSH private key (`relay-key`), needed for the one return-trip
push the bastion can originate (the backup-export relay, §8) since that key
otherwise only ever lives on staging. The bastion's own OS packages (`dnsmasq`/`httpd`, installed by
`bastion/bastion/roles/common/configure_bastion_services`) go through the identical path —
`stage_mirror_content` resolves their full dependency closure into
`mirror_installers_dir/bastion-rpms` via `dnf download --resolve`, then runs
`createrepo_c` against that directory so it travels as a real local-only dnf repo
(not just a pile of RPM files — dnf's solver needs repo metadata to resolve a
dependency closure correctly, confirmed against a real customer environment where
installing from a raw file list wasn't reliable), and `configure_bastion_services`
installs by package name against that local repo's metadata (`disablerepo: '*'`),
since a direct `dnf install` on the bastion itself fails (RHUI has no route either).

`oc_mirror_operator_packages` (role default in `stage_mirror_content`) controls which
operators get mirrored — entries are either a bare package name (default catalog
channel) or a `{name, channel}` dict to pin a non-default channel, or a
`{name, channel, catalog}` dict when a package ships from a different operator index
(`certified`/`community`/`marketplace` rather than the default `redhat` index — see
the role's `defaults/main.yaml` for the confirmed values used by the roles below).
Every feature role below that installs an operator needs its package present in this
list with a matching channel/catalog.

Mirroring the operator content to the bastion's registry is necessary but not
sufficient — OLM still resolves every `Subscription` in this repo against the
cluster's three *default* CatalogSources (`redhat-operators`/`community-operators`/
`certified-operators`), which point at `registry.redhat.io`/
`registry.connect.redhat.com` out of the box and are unreachable here. Confirmed
live: left alone, those CatalogSource pods sit in `Init:ImagePullBackOff` forever and
every Subscription just never resolves. `bastion/roles/ocp/
configure_mirror_catalog_sources` (called once, right after the kubeconfig first
exists — the last step of `provision-sno.yaml`) fixes this: it applies the
`ImageDigestMirrorSet`/`ImageTagMirrorSet`/release-signature manifests oc-mirror v2
already generates under `{{ mirror_archive_dir }}/working-dir/cluster-resources/`,
disables OperatorHub's managed default sources (`disableAllDefaultSources: true` —
confirmed live, a plain `spec.image` patch against a default CatalogSource gets
silently reverted within seconds otherwise), and recreates all three *under the same
names* pointed at the mirrored index images, so every existing `source:
redhat-operators` etc. in this repo's Subscription templates keeps working
unmodified. It also waits for the resulting MachineConfigPool rollout (the IDMS/ITMS
content only takes effect once `/etc/containers/registries.conf` is re-rendered on
the node) before returning, so the Subscription tasks that immediately follow don't
race it.

`package_bastion_bundle` and (for backup export, §8) `package_staging_bundle`
default to physical media precisely because no live network path between staging and
the bastion is assumed. Where one genuinely exists (e.g. during initial bring-up
before the bastion is fully air-gapped), both support an opt-in one-directional
`rsync` push instead (`bastion_transfer_method`/`staging_transfer_method: rsync`) —
each side only ever pushes outward from itself, with no cross-host orchestration
needed, since staging and the bastion are independent automation runs rather than
two hosts one controller reaches at once.

Post-install, `bastion/roles/ocp/configure_onprem_quay` deploys a separate, long-term
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
| Block (PVCs) | `bastion/roles/ocp/configure_lvms` | True-SNO default — carves the RAID5 volume (`lvms_device_paths`) into PVs for everything below that needs one |
| S3-compatible object storage | `bastion/roles/ocp/configure_mcg` | Standalone Multicloud Object Gateway (NooBaa), **no CephCluster** |

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
reclaim), defaulted to by `bastion/roles/ocp/configure_postgres` only — Postgres is the one
workload here whose data has no separate durable copy elsewhere, so Retain closes the
gap between `configure_oadp_backup`'s backup windows. See `configure_lvms`'s README.

## 5. Networking

- **Application HTTP(S) ingress**: the default OCP Ingress Controller. SNO's single
  node IP serves this role directly — there is no API/Ingress VIP anywhere in this
  repo.
- **Non-HTTP TCP middleware** (AMQP, Postgres, Redis): `bastion/roles/ocp/configure_metallb`
  provisions an `IPAddressPool` (`metallb_address_pool`, a customer-provided
  range/CIDR) + `L2Advertisement`, consumed by `configure_rabbitmq`/
  `configure_postgres`/`configure_redis`'s optional `type: LoadBalancer` Services
  (`*_expose_external`, default `false`/ClusterIP).
- **NIC bonding / switch topology**: `bastion/roles/baremetal/baremetal_generate_agent_iso`
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
| Log storage | `bastion/roles/ocp/configure_lokistack` | Loki, S3-backed via `configure_mcg`. 30-day total retention (`loki_retention_days`), 7-day override on the `application` stream (`loki_hot_retention_days`) as the closest LokiStack approximation of a two-tier hot/total retention requirement — **not real storage tiering**, see the role's README. |
| Dashboards | `bastion/roles/ocp/configure_grafana` | Datasources wired to LokiStack and (if tracing is enabled) Tempo. |
| External SIEM forwarding | `bastion/roles/ocp/configure_log_forwarding` | `ClusterLogForwarder` has two outputs side by side: a `lokiStack` output (`loki_output_enabled`, default `true`) — the production path — and an external syslog output (`log_forward_endpoint`). **The syslog output is a placeholder, not production-ready**: the real external SIEM target and its auth model (token vs. mTLS) aren't finalized, and the RBAC it needs isn't wired up yet (see role README). |
| Application tracing | `bastion/roles/ocp/configure_opentelemetry` | OpenTelemetry Collector (OTLP receiver) + Tempo, S3-backed via `configure_mcg`. Gives the application an OTLP endpoint to send traces to. |
| Email alerting | `bastion/roles/ocp/configure_alerting` | Patches the cluster Alertmanager config with an email receiver pointed at a customer-provided SMTP server (`alert_smtp_host`/`alert_email_to`). **Assumes direct network reachability** — same site, not internet; this role doesn't stand up a relay. Known limitation: replaces rather than merges any existing custom Alertmanager config (see role README). |

## 7. Day 2 application platform

The customer is handed a fully working application, not a bare cluster — this repo
deploys its middleware too:

| Component | Role | Notes |
|---|---|---|
| Message queue | `bastion/roles/ocp/configure_rabbitmq` | RabbitMQ Cluster Operator, confirmed shipping from `community-operators` (not `redhat-operators`), channel `stable`. |
| Database | `bastion/roles/ocp/configure_postgres` | Crunchy PGO, confirmed shipping from `certified-operators` (not `redhat-operators`), channel `v5`, plus a plain pgAdmin Deployment (pgAdmin has no operator). pgAdmin's container image isn't covered by `oc_mirror_operator_packages` (that's operator-catalog-only) — needs separate image-mirroring handling, not yet solved (see role README). |
| Cache | `bastion/roles/ocp/configure_redis` | Plain StatefulSet, **no operator** (Redis Enterprise needs separate licensing beyond the Platform Plus entitlement; a community operator wasn't judged necessary) — matches "no current HA needs" and the customer's cost/simplicity priority. |
| Auth | `bastion/roles/ocp/configure_keycloak` | Red Hat build of Keycloak Operator. Depends on `configure_postgres` for its database backend — the exact generated Service/Secret names it assumes are flagged in the role README as needing live-cluster verification, and nothing yet provisions the `keycloak` database/user on the PostgresCluster itself (gap, not yet solved). |

All four default to LVMS-backed PVCs and single replica (no HA requirement stated by
the customer).

## 8. Backup, DR & external export

Two independent concerns:

1. **In-cluster backup/restore**: `bastion/roles/ocp/configure_oadp_backup` (OADP) targets
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
`bastion/playbooks/export-backup.yaml` always stages data on the bastion first
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
- **`network`** / **`both`**: packages and relays data through the same two sides
  the inbound mirroring pipeline uses, reversed, all the way to a real
  internet-reachable external S3 target:

  ```
  NooBaa (SNO node) → export_backup_from_noobaa (bastion, same private network)
                    → package_staging_bundle (bastion, reverse of package_bastion_bundle;
                       physical media by default, rsync opt-in)
                    → unpack_staging_backup_bundle + push_backup_to_external_s3 (staging,
                       the only side of this split with real internet)
                    → real external S3 target
  ```

  Unlikely to apply on a genuinely disconnected production deployment — only use
  this if the customer has explicitly confirmed that outbound path exists. `both`
  also leaves the staged bastion copy in place for an additional manual media
  export.

`bastion/roles/ocp/configure_mcg_backup_export` only validates the target vars for whichever
mode is active (`backup_internal_target_*` for `internal`, `backup_external_s3_*`
for `network`/`both`) — it applies no CRs.

**Log/metrics export is explicitly out of scope / not yet built** — don't assume
`backup_egress_mode` covers Loki data.

## 9. DNS and NTP

Customer-provided Windows DNS and NTP servers — not automated by this repo (the
`dns_server`/`ntp_server` inventory vars just point the node at them;
`bastion/roles/common/configure_bastion_services`'s dnsmasq is only used when no external DNS
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
(`bastion/roles/common/generate_install_config`).

## 10. Hardware provisioning

`bastion/roles/baremetal/baremetal_boot_node_via_bmc` mounts the agent ISO via BMC virtual
media and power-cycles the node — implemented against Dell iDRAC9/10 using standard
Redfish (`community.general.redfish_command`/`redfish_info`), no vendor-specific
payload beyond the fixed iDRAC resource IDs. **Unverified against real hardware** —
no live BMC to test against yet; see the role's README before the first real run.

## 11. Support & lifecycle

- **Upgrades**: `bastion/roles/ocp/sno_upgrade`, quarterly or on-demand per the customer's
  stated cadence. Rollback is via OADP restore, not `oc adm upgrade` rollback — SNO
  has no second control plane to fail over to. After the upgrade completes, the role
  runs `oc adm prune images` (`sno_upgrade_prune_images`, default on) to reclaim space
  from superseded release/operator/machine-os images — this is a disk-constrained
  single-node cluster on a fixed RAID5 pool, and the upgrade itself doesn't purge
  anything. The on-cluster Quay registry (`configure_onprem_quay`, application images)
  has no equivalent GC/retention policy configured yet — see that role's and
  `sno_upgrade`'s READMEs.
- **Node failure drill**: `bastion/roles/ocp/simulate_node_failure`, gated behind
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
  `loki-operator` is `stable-6.7` (redhat-operators); `grafana-operator` is `v5`
  (**community-operators**, not redhat-operators); `rabbitmq-cluster-operator` is
  `stable` (**community-operators**); `crunchy-postgres-operator` is `v5`
  (**certified-operators**). `oc_mirror_operator_packages` supports a per-package
  `catalog:` key so `stage_mirror_content` mirrors each from the right index — see
  `staging/roles/common/stage_mirror_content/defaults/main.yaml`.

  **These channel strings move, confirmed live, not just hypothetically**:
  `loki-operator`'s channel was `stable-6.6` when first confirmed here, then
  silently dropped from the catalog by a later mirror run — `oc-mirror` failed
  outright, with the real cause buried in its own per-component logs rather than
  surfaced clearly (prompted an error-message improvement in `stage_mirror_content`'s
  "Fail if the oc-mirror run itself failed" task). Re-verify with
  `oc-mirror list operators` **periodically, not just on an `openshift_version`
  bump** — a catalog refresh can drop an older channel on its own. Each pinned
  channel exists in **two** places that must change together: the mirror-side pin
  here, and the matching role's own `*_channel` default (what its `Subscription`
  actually requests at install time) — see `stage_mirror_content`'s README
  ("Updating a mirrored operator's channel") for the full procedure. The same pass
  also found `quay-operator` (`configure_onprem_quay`) missing from
  `oc_mirror_operator_packages` entirely — its `Subscription` requested a channel
  nothing had ever mirrored; added as `{ name: quay-operator, channel: stable-3.13 }`.
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
- `bastion/roles/baremetal/baremetal_boot_node_via_bmc` unverified against real iDRAC
  hardware.
- `sno_network_topology: dual_switch` (`bastion/roles/baremetal/baremetal_generate_agent_iso`)
  unverified against real dual-NIC hardware — the bonded nmstate syntax hasn't been
  tested against a live Agent-Based install yet.
- `mirror_registry_version` (`staging/roles/common/stage_mirror_content/defaults/main.yaml`,
  currently `2.0.12`) is a pinned point-in-time version, not a "latest" alias — Red
  Hat's own `latest/` path requires a cookie-based redirect a plain `get_url` can't
  follow. Re-verify against
  https://mirror.openshift.com/pub/cgw/mirror-registry/ before a production run if
  it's been a while; a stale pin still works (older `mirror-registry` versions remain
  downloadable), it just won't have newer fixes.
- Bastion `/var` sizing for a full "disk to mirror" push, not just the
  `mirror-registry` install itself — a real customer run's 483-image push hit
  intermittent `500 Internal Server Error` from the registry's bearer-token endpoint.
  **Confirmed root cause**: `/var` (backing podman's default container storage) was
  at 100% utilization on the customer's bastion, not a RAM/CPU constraint — see §2.
  `deploy_mirror_registry` now fails fast up front with a `/var` free-space check
  (`bastion_min_free_disk_gb`, default 100GB placeholder) before attempting the
  install or push; tune that default once a real run's actual `/var` usage for this
  customer's `oc_mirror_operator_packages` selection is known.
