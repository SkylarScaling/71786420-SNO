# High Level Design — Single Node OpenShift Platform for Disconnected Bare-Metal Environments

**Prepared for:** [Customer Name] — Project Number: [TBD]
**Version:** 1 (initial draft) — see [`bare-metal-architecture.md`](bare-metal-architecture.md) for the
maintained, living technical reference this report is generated from.

## Confidentiality, Copyright, and Disclaimer

This is a customer-facing document shared between the implementing team and
[Customer Name]. This document is not a quote and does not include any binding
commitments. Real environment-specific values (IP addresses, hostnames, credentials,
customer/site names) are deliberately omitted from this report and are tracked
instead in per-environment inventory files, consistent with this project's
reusability requirements — see this repo's `CLAUDE.md`.

## Review History

| Version | Date | Contributor | Description |
|---|---|---|---|
| 1 | [TBD] | [TBD] | Initial draft, generated from `docs/bare-metal-architecture.md` |

---

## 1. Introduction

The implementing team has been engaged to design and deploy a Single Node OpenShift
(SNO) platform for [Customer Name], targeting a single bare-metal server at the
customer's production site, together with the supporting automation that builds,
configures, and maintains it as a repeatable, disconnected deployment.

The platform runs in a **fully disconnected (air-gapped) manner** — the SNO node and
its bastion have no internet route at all. Required content (OpenShift release
images, Operator catalogs, application images) is prepared on a separate
internet-connected host and relayed in through a mirroring pipeline described in
§3.3.

### 1.1. Purpose

This document outlines the target bare-metal architecture for stakeholders whose
agreement and understanding are required to deliver the solution — infrastructure,
security, and operations teams within [Customer Name], and the implementing delivery
team.

### 1.2. Scope

This document describes the problem statement, requirements, proposed architecture,
and the rationale behind the design decisions made.

Anything not explicitly listed as in-scope is deemed out of scope of this design
document.

### 1.3. Audience

The primary audience is the [Customer Name] infrastructure/platform team responsible
for the design, implementation, and ongoing operational support of the solution.

| Name | Position | Email |
|---|---|---|
| [TBD] | [TBD] | [TBD] |

### 1.4. Terms and Acronyms

| Acronym | Description |
|---|---|
| BMC | Baseboard Management Controller |
| LVMS | Logical Volume Manager Storage |
| MCG | Multicloud Object Gateway (standalone NooBaa) |
| ODF | OpenShift Data Foundation |
| OADP | OpenShift API for Data Protection |
| OCP | OpenShift Container Platform |
| RHCOS | Red Hat CoreOS |
| RPO | Recovery Point Objective |
| RTO | Recovery Time Objective |
| SIEM | Security Information and Event Management |
| SMTP | Simple Mail Transfer Protocol |
| SNO | Single Node OpenShift |
| VIP | Virtual IP |

### 1.5. Referenced Documents

| Document | Description |
|---|---|
| [`bare-metal-architecture.md`](bare-metal-architecture.md) | Living implementation reference — what's deployed, why, which role/playbook owns it, and the requirements-traceability table this report summarizes |
| [`architectural-decisions.md`](architectural-decisions.md) | Rationale for specific carried-forward design patterns (disconnected mirroring, backup storage isolation) |
| Red Hat OpenShift Container Platform documentation | Product documentation for the installed OpenShift version |
| Red Hat Quay documentation | Product documentation for the mirror and on-cluster registries |

---

## 2. High Level Overview

### 2.1. Objective

The platform provides [Customer Name] with a production-grade, single-node OpenShift
environment running at a single physical site, built once via automation and kept
consistent across every future rebuild or disaster-recovery scenario.

### 2.2. Requirements

The MoSCoW method is used to classify requirements:

- **MUST** — a fit-for-purpose requirement that cannot be changed (regulatory,
  contractual, or firm business/technical constraint).
- **SHOULD** — a fit-for-purpose requirement that can be modified if needed.
- **COULD** — a best-effort requirement; the solution is still fit-for-purpose if
  unmet.
- **WON'T** — a deliberate-omission requirement the solution does not attempt to
  meet.

| ID | Category | Importance | Requirement |
|---|---|---|---|
| 1 | Platform Architecture | MUST | The solution consists of a Single Node OpenShift cluster — single server, single switch, single bastion — at the customer's production site. |
| 2 | Hosting Location | MUST | The solution is deployed on-premises, within a secured and segmented network boundary. |
| 3 | General Design | MUST | The solution operates fully disconnected (air-gapped) — the SNO node and bastion have no internet route under any circumstance. |
| 4 | Image Management | MUST | Required content is staged on a separate internet-connected host, then relayed to the bastion's local mirror registry before being used by the cluster. |
| 5 | Cluster Installation | MUST | The cluster is deployed using the Agent-Based Installer, using Red Hat Enterprise Linux CoreOS (RHCOS) on the node. |
| 6 | Hardware Provisioning | MUST | The node is provisioned by mounting the installer ISO via the server's BMC (Redfish) and power-cycling it — no manual media handling. |
| 7 | Networking | MUST | Application HTTP(S) ingress uses the default OpenShift Ingress Controller; there is no separate API/Ingress VIP. |
| 8 | Networking | SHOULD | Non-HTTP TCP middleware services (message queue, database, cache) are optionally exposed via a MetalLB-provisioned address pool. |
| 9 | Networking | WON'T | NIC bonding/traffic isolation is not implemented — the target hardware uses a single NIC per function with no bonding. |
| 10 | Storage | MUST | Block storage for all workloads is backed by LVMS over the server's hardware RAID5 array. |
| 11 | Storage | MUST | S3-compatible object storage is provided by a standalone Multicloud Object Gateway, with no additional OCP-level storage replication layered on top of hardware RAID5. |
| 12 | Storage | WON'T | Full ODF/Ceph is not implemented — this is a true single-node deployment and will not scale out. |
| 13 | Logging | MUST | Audit, infrastructure, and application logs are collected and retained via an in-cluster LokiStack, visualized through Grafana. |
| 14 | Logging | COULD | A syslog-based forwarding output to an external SIEM is supported alongside the LokiStack output; the endpoint configured today is a placeholder, and the authentication/RBAC needed to forward to the customer's actual SIEM is not yet finalized. |
| 15 | Monitoring/Tracing | COULD | Application-level distributed tracing is available via an OpenTelemetry Collector and Tempo, wired into the same Grafana instance. |
| 16 | Alerting | MUST | Cluster alerts are routed to a customer-provided SMTP server via email. |
| 17 | Registry | MUST | A bastion-hosted mirror registry serves install-time content only; a separate, long-term on-cluster registry serves application images post-install. |
| 18 | Platform Operations | MUST | Administrators can install and manage Red Hat and certified Operators via OperatorHub, sourced from the mirrored catalog. |
| 19 | Day 2 Application Platform | MUST | The customer's application middleware (message queue, database, cache, identity/auth) is deployed and managed as part of the platform, not left to the customer to stand up separately. |
| 20 | Backup and Restore | MUST | Cluster resources, persistent volumes, and application/namespace data are backed up and restorable via OpenShift API for Data Protection (OADP). |
| 21 | Backup and Restore | MUST | Application object-storage data is periodically exported off the node, protecting against total node/chassis loss (RAID5 alone only protects against single-disk failure). The realistic export path is manual removable media or a push to a backup system the customer already runs on the disconnected network — a direct connection to a real internet-reachable S3 target is supported but unlikely to be available on this kind of deployment. |
| 22 | DNS/NTP | MUST | DNS and NTP services are provided by the customer's existing infrastructure; the platform is not expected to run its own. |
| 23 | High Availability | WON'T | The solution does not provide control-plane or node-level high availability — this is a true single-node deployment; recovery after total node loss is via reinstall + OADP restore, not failover. |
| 24 | Lifecycle | MUST | The platform supports scheduled/on-demand upgrades and a gated, destructive node-failure recovery drill for operational readiness validation. |
| 25 | Support | SHOULD | `oc adm must-gather` output and standard Red Hat support escalation are the supported path for platform issues. |

---

## 3. Platform Architecture and Design

### 3.1. Architectural Design Decisions

| ID | Decision Area | Description |
|---|---|---|
| AD1 | Deployment Site | The platform is deployed at the customer's production data center/site as a disconnected environment with no internet access for the cluster or bastion. |
| AD2 | Platform Topology | A single OpenShift node (control plane and workload combined) is deployed using the Agent-Based Installer. There is no separate worker pool. |
| AD3 | Physical Server | A single Dell PowerEdge R7725 (iDRAC9/10, Redfish-managed), 768GB RAM, with 3x 3.2TB SSD + 2x 960GB NVMe configured in hardware RAID5 (~6TB usable). |
| AD4 | Network Topology | Single top-of-rack switch, single bastion host, 1G networking, single NIC per function. No cross-switch redundancy and no NIC bonding on this deployment — the target hardware's NIC count doesn't support it, and it isn't a stated requirement. |
| AD5 | Pod/Service Networking | OVN-Kubernetes is the default CNI, with non-overlapping pod and service CIDR ranges. |
| AD6 | Ingress/API Access | No external load balancer or API/Ingress VIP is used; the single node's own IP serves both API and application ingress directly. |
| AD7 | Service Exposure | HTTP(S) application traffic uses the default OpenShift Ingress Controller. Non-HTTP TCP middleware (message queue, database, cache) is optionally exposed via a MetalLB-provisioned `IPAddressPool`, using a customer-supplied address range. |
| AD8 | Storage Platform | LVMS carves the RAID5 volume into block PVs for all workloads. A standalone Multicloud Object Gateway (no CephCluster) provides S3-compatible object storage, avoiding redundant replication on top of hardware RAID5. Full ODF/Ceph is not implemented — this is a true single-node deployment. |
| AD9 | Disconnected Content Preparation | A separate internet-connected host stages OpenShift release images, Operator catalogs, and required container images ("mirror to disk"), independent of the bastion/cluster. |
| AD10 | Content Transfer Method | Staged content is synced to the bastion over a private network path (or physical media where no network path exists), then loaded into a bastion-hosted mirror registry ("disk to mirror") that the installer's `imageContentSources` always point at — there is no connected install fallback. |
| AD11 | Post-Deployment Registry Strategy | After cluster install, a dedicated on-cluster Quay registry (non-HA, single replica — no availability requirement at this scale) serves application images going forward, separate from the bastion's install-time-only mirror. |
| AD12 | Observability | Logs are aggregated via an in-cluster LokiStack (object-storage-backed by the Multicloud Object Gateway) and visualized in Grafana. A syslog-based output to an external SIEM runs alongside the LokiStack path, but currently targets a placeholder endpoint — the customer's real SIEM target and auth model (token vs. mTLS) still need to be confirmed before this is production-ready. Application tracing is provided via an OpenTelemetry Collector and Tempo, also object-storage-backed, feeding the same Grafana instance. |
| AD13 | Alerting | Cluster Alertmanager is configured with an email receiver pointed at a customer-provided, directly reachable SMTP server. |
| AD14 | DNS/NTP | DNS and NTP are provided by the customer's existing infrastructure; the platform integrates with these for name resolution, ingress access, and time sync. |
| AD15 | Backup and Data Protection Strategy | OpenShift API for Data Protection (OADP) backs up Kubernetes resources and persistent volumes to S3-compatible storage on a default daily schedule. Application object-storage data is additionally exported off the node periodically, protecting against total node/chassis loss, which hardware RAID5 alone does not cover. Since the cluster has no internet route of its own, the default export path is a manual removable-media handoff from the bastion; pushing directly to a backup system the customer already runs on the disconnected network is supported as a drop-in upgrade once that target is confirmed. Relaying all the way to a genuine internet-reachable external S3 target is also supported but considered unlikely to apply here. |
| AD16 | Day 2 Application Platform | The customer's application middleware — message queue, relational database (plus an admin UI), cache, and identity/auth — is deployed and managed as part of the platform, backed by LVMS, single-replica (no stated HA requirement). |
| AD17 | Hardware Provisioning | The node is provisioned by mounting the Agent-Based Installer ISO via the server's BMC (Redfish `redfish_command`/`redfish_info`) and power-cycling it — no manual media handling required. |
| AD18 | Scaling Model | The single-node design reserves the storage-replication network pattern (used by multi-node deployments) for consistency, so a future scale-out to additional nodes does not require re-cabling, even though it carries no cross-node traffic on a true SNO. |
| AD19 | Lifecycle Operations | Scheduled/on-demand upgrades and a gated, destructive node-failure recovery drill are built into the automation for operational readiness validation ahead of go-live. |

### 3.2. Solution Overview

#### 3.2.1. Deployment Architecture and Platform Services

The platform is deployed as a disconnected, on-premises Single Node OpenShift
cluster using the Agent-Based Installer. Required install-time content is prepared
on a separate internet-connected host and relayed through a dedicated bastion host
at the customer site, which has no internet route of its own, nor does the SNO node.
After installation, an on-cluster Quay registry takes over serving application
images; the bastion's registry remains install-time-only.

#### 3.2.2. Cluster Topology and Node Roles

The cluster is a true single node — there is no separate control-plane/worker
split. All platform services, Day 2 application middleware, logging, and tracing
workloads run on the one node.

#### 3.2.3. Physical Infrastructure and High Availability Design

A single Dell PowerEdge R7725 server (iDRAC9/10, Redfish) behind a single
top-of-rack switch, with a single bastion host. There is no rack-, switch-, or
node-level redundancy in this design — availability for application data is
addressed instead through hardware RAID5 (single-disk protection) and periodic
off-node export of application data (whole-chassis-loss protection), not through
infrastructure duplication.

#### 3.2.4. Network Design

1G networking, no NIC bonding on this deployment. The default OCP Ingress Controller
serves HTTP(S) application traffic directly off the node's own IP — there is no
API/Ingress VIP. A MetalLB-provisioned address pool is available, opt-in, for
non-HTTP TCP middleware services that need a stable external IP.

#### 3.2.5. Platform Storage

LVMS provides block storage for every PVC-consuming workload on the node, carved
from the hardware RAID5 array. A standalone Multicloud Object Gateway (NooBaa, no
CephCluster) provides S3-compatible object storage for logging, tracing, backup
export, and application use — deliberately not full ODF/Ceph, since the hardware
RAID5 array already provides disk-level redundancy and a second replication layer on
top would add operational weight without added resiliency at this scale. Full
ODF/Ceph is not implemented in this automation — this is a true single-node
deployment and will not scale out.

#### 3.2.6. Logging, Tracing & Alerting

An in-cluster LokiStack, object-storage-backed by the Multicloud Object Gateway,
retains audit, infrastructure, and application logs, visualized through Grafana.
A second, syslog-based output to an external SIEM runs alongside — not
replacing — the LokiStack path; this is a supported capability, not yet a finished
one — it currently points at a placeholder endpoint, and the service-account
RBAC/authentication needed to forward to the customer's actual SIEM has not been
finalized. It should not be treated as production-ready until the real SIEM target
and its auth model are confirmed. Application-level distributed tracing is available
via an OpenTelemetry Collector (OTLP endpoint) and Tempo, also object-storage-backed,
feeding the same Grafana instance. Email alerting is configured against a
customer-provided, directly reachable SMTP server.

#### 3.2.7. Day 2 Application Platform

The customer is handed a working application platform, not a bare cluster: a message
queue, a relational database with an admin UI, an in-memory cache, and an
identity/auth provider are deployed alongside the application. All default to
LVMS-backed storage and single-replica, matching the no-stated-HA-requirement scope
of this engagement; external exposure of any of these (where required) uses the
MetalLB address pool described in §3.2.4.

#### 3.2.8. Software Editions and Subscriptions

The deployment is entitled under OpenShift Platform Plus, which covers OpenShift
Container Platform itself plus the operator-managed components used throughout this
design (storage, logging/tracing, registry, backup/DR).

#### 3.2.9. Future Considerations

- Automated, continuous log/metrics export off the node (currently out of scope —
  only application object-storage data is covered by the export job).

### 3.3. Disconnected Mirroring & Registry

Because the SNO node and bastion have no internet route at all, every piece of
install-time and operator content follows a one-directional relay:

```
Internet-connected staging host --(mirror to disk)--> sync to bastion --(disk to mirror)--> bastion mirror registry --> SNO node
```

1. **Stage to disk** on the internet-connected host — downloads OpenShift release
   images, Operator catalog content, and required container images into a portable
   archive.
2. **Sync** that archive to the bastion, over a private network path or physical
   media where no network path exists.
3. **Deploy the mirror registry on the bastion** and load the archive into it — this
   is what the installer's `imageContentSources`/trust bundle always point at; there
   is no connected-install fallback.
4. **Install** the cluster via the Agent-Based Installer, entirely from mirrored
   content.
5. **Post-install**, a separate, long-term, on-cluster Quay registry (single
   replica — no availability requirement at this scale) takes over serving
   application images; the bastion's registry remains install-time-only.

### 3.4. Hardware Provisioning

The node is provisioned by mounting the Agent-Based Installer ISO via the server's
BMC (Dell iDRAC9/10, standard Redfish `redfish_command`/`redfish_info`) and
power-cycling it. No manual media handling or interactive installer steps are
required.

---

## 4. Backup, Disaster Recovery & External Export

Two independent concerns are addressed:

1. **In-cluster backup/restore** — OpenShift API for Data Protection (OADP) backs up
   Kubernetes resources and persistent volumes to S3-compatible object storage
   (backed by the Multicloud Object Gateway), supporting restore after
   configuration drift, accidental deletion, or application-level failure.
2. **External export, off the node entirely** — hardware RAID5 protects against a
   single disk failing; it does nothing for losing the whole chassis. Application
   object-storage data is periodically exported off the node; because the cluster
   has no internet route, this cannot run as a continuously-replicating in-cluster
   resource — it is a periodic/on-demand relay job, not an always-on path. The
   default export path is a manual removable-media handoff from the bastion — the
   safe assumption for a fully disconnected site. Where the customer already runs a
   backup system on the same disconnected network, data can instead be pushed
   there directly from the bastion, with no internet route needed. Relaying all the
   way to a genuine internet-reachable external S3 target is also supported, but is
   considered the least likely of the three to actually be available here.

Log/metrics export off the node is explicitly out of scope at this time.

**Disaster recovery scope** is limited to this single site: there is no secondary
site, no cross-site replication, and no automated failover. Recovery from total node
loss is: reinstall via the same disconnected pipeline described in §3.3, then restore
from OADP backup.

---

## 5. Lifecycle & Support

- **Upgrades**: performed on a scheduled or on-demand cadence as agreed with the
  customer. Rollback is via OADP restore, not an in-place upgrade rollback — a
  single-node cluster has no second control plane to fail over to during an upgrade.
- **Node failure drill**: a destructive recovery drill, explicitly gated behind a
  confirmation flag, validates the reinstall-and-restore path described in §4 without
  requiring an actual hardware failure.
- **Support escalation**: `oc adm must-gather` output, followed by the customer's
  internal support process or direct Red Hat support engagement.

---

## 6. Appendix — Requirements Traceability

| Requirement (§2.2) | Addressed By | Status |
|---|---|---|
| Single server/switch/bastion topology | §3.2.2, §3.2.3 | Delivered |
| Fully disconnected, no internet route | §3.3 | Delivered |
| Mirrored content relay | §3.3 | Delivered |
| Agent-Based Installer, RHCOS | §3.2.1, §3.4 | Delivered |
| BMC-driven provisioning | §3.4 | Delivered, pending hardware validation |
| Block storage over RAID5 | §3.2.5 | Delivered |
| S3-compatible storage, no redundant replication | §3.2.5 | Delivered |
| Logging + Grafana | §3.2.6 | Delivered |
| External SIEM forwarding (optional) | §3.2.6 | Supported, not production-ready — placeholder endpoint, auth/RBAC pending confirmation of the real SIEM target |
| Application tracing | §3.2.6 | Delivered |
| Email alerting | §3.2.6 | Delivered |
| On-cluster application registry | §3.3 | Delivered |
| OperatorHub via mirrored catalog | §3.3 | Delivered |
| Day 2 application middleware | §3.2.7 | Delivered |
| Backup/restore via OADP | §4 | Delivered |
| Off-node export of application data | §4 | Delivered as manual removable-media export (default) and push-to-internal-backup-system; direct-to-internet S3 export also supported but unlikely to apply. Log/metrics export not yet built |
| Customer-provided DNS/NTP | §3.2.1 | Delivered |
| No node/control-plane HA (true SNO) | §3.2.2, §3.2.3 | By design |
| Upgrades and node-failure drill | §5 | Delivered |
| Must-gather / support workflow | §5 | Manual runbook, not automated |

For the complete, current-state technical detail behind every row above — including
exact role/playbook ownership and open verification items — see
[`bare-metal-architecture.md`](bare-metal-architecture.md).
