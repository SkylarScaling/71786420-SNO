# Architectural Decisions Carried Forward

See [`bare-metal-architecture.md`](bare-metal-architecture.md) for the full
current-state design of the customer (bare-metal production) deployment — what's
deployed, where, and the requirements-traceability table — and
[`aws-test-environment-architecture.md`](aws-test-environment-architecture.md) for
how this repo's AWS test loop proves that design out first. This document is just the
*why* behind specific carried-forward patterns, not the whole system.

These are design patterns proven on prior bare-metal OpenShift engagements, captured
here so they're applied consistently to new deployments rather than re-derived each
time. They're written generically — no site-specific names, IPs, or domains — and the
roles that implement them expose the specifics as variables.

## 1. Disconnected content mirroring

Every deployment — AWS test environment included — is treated as fully disconnected.
There is no connected/non-mirrored install path for either provider; this keeps the
thing actually under test (the mirroring workflow itself) exercised on every run
instead of only once hardware is available.

1. **Stage to disk** on an internet-connected host using `oc mirror` ("mirror to
   disk") — `roles/common/stage_mirror_content`. No registry runs on this host; it
   just produces a portable archive.
2. **Sync** that archive to the disconnected bastion (rsync over a private network
   path, or physical media where no network path exists at all) —
   `roles/common/sync_mirror_to_bastion`.
3. **Deploy the mirror registry on the bastion** (`mirror-registry`/Quay) and push the
   archive into it ("disk to mirror") — `roles/common/deploy_mirror_registry`. This is
   the registry `install-config.yaml`'s `imageContentSources`/`additionalTrustBundle`
   always point at (`roles/common/generate_install_config` has no connected fallback).
   The `mirror-registry` and `oc-mirror` tool tarballs themselves are also downloaded
   on the internet-connected host in step 1 and carried over by step 2, not fetched
   directly on the bastion — it has no internet route to do that with either.
4. Install via IPI (AWS) or the Agent-Based Installer (bare metal) — the cluster node(s)
   never reach the public internet.
5. Post-install, deploy an on-cluster, highly available Quay registry
   (`roles/ocp/configure_onprem_quay`) to serve application images going forward —
   the bastion's mirror registry is for install-time content only.

**On AWS**, "disconnected" is real, not simulated: `roles/aws/aws_provision_network`
builds a VPC with a public subnet used *only* by the mirror-staging host, and a
private subnet (reused as the cluster's machine network) with no internet gateway or
NAT route at all for the bastion or the SNO node. VPC endpoints (`s3`, `ec2`,
`elasticloadbalancing`, `sts`) give the installer and the in-cluster AWS cloud
provider the AWS API access they need without any internet route. The automation
controller itself (wherever `openshift-install`/Ansible run) still has normal internet
access — only the EC2 instances it creates are isolated.

## 2. Data protection & storage isolation

OADP backups (`roles/ocp/configure_oadp_backup`) target the in-cluster NooBaa S3
endpoint provided by `roles/ocp/configure_mcg`, on both providers — keeping backup
traffic entirely on-cluster with no external dependency at all. This is the pattern
for sovereign bare-metal environments where even AWS S3 isn't an option, and it's
used unmodified on the AWS test loop too (once `configure_mcg` ran on both
providers, there was no remaining case for a separate external-S3 backend: an
earlier `aws` option that pointed OADP directly at a real AWS S3 bucket only ever
worked on the AWS test loop — reachable there via an S3 VPC Gateway Endpoint, not a
real internet route — and would have simply timed out on bare metal's fully
disconnected network).

This keeps local PV and Kubernetes-resource backups on infrastructure the cluster
already owns.
