# Architectural Decisions Carried Forward

See [`bare-metal-architecture.md`](bare-metal-architecture.md) for the full
current-state design of the deployment — what's deployed, where, and the
requirements-traceability table. This document is just the *why* behind specific
carried-forward patterns, not the whole system.

These are design patterns proven on prior bare-metal OpenShift engagements, captured
here so they're applied consistently to new deployments rather than re-derived each
time. They're written generically — no site-specific names, IPs, or domains — and the
roles that implement them expose the specifics as variables.

## 1. Disconnected content mirroring

Every deployment is treated as fully disconnected. There is no connected/non-mirrored
install path.

1. **Stage to disk** on the internet-connected staging host using `oc mirror`
   ("mirror to disk") — `staging/roles/common/stage_mirror_content`. No registry
   runs on this host; it just produces a portable archive.
2. **Package** that archive, the install-time binaries, and the entire `bastion/`
   automation tree into one `tar.gz` — `staging/roles/common/package_bastion_bundle`.
   Physical media is the default transfer; an rsync push to the bastion is an
   explicit opt-in (`bastion_transfer_method: rsync`), for the case where a
   temporary network path genuinely exists. There is no assumption of a live network
   path between staging and the bastion otherwise.
3. **Unpack** the bundle on the bastion — `bastion/roles/common/unpack_bastion_bundle`
   — then **deploy the mirror registry** (`mirror-registry`/Quay) and push the
   archive into it ("disk to mirror") — `bastion/roles/common/deploy_mirror_registry`.
   This is the registry `install-config.yaml`'s
   `imageContentSources`/`additionalTrustBundle` always point at
   (`bastion/roles/common/generate_install_config` has no connected fallback). The
   `mirror-registry`/`oc-mirror`/`openshift-install`/`oc` tool tarballs themselves
   are also downloaded on staging in step 1 and carried over by step 2, not fetched
   directly on the bastion — it has no internet route to do that with either.
4. Install via the Agent-Based Installer — the cluster node never reaches the public
   internet.
5. Post-install, deploy an on-cluster, highly available Quay registry
   (`roles/ocp/configure_onprem_quay`) to serve application images going forward —
   the bastion's mirror registry is for install-time content only.

## 2. Data protection & storage isolation

OADP backups (`roles/ocp/configure_oadp_backup`) target the in-cluster NooBaa S3
endpoint provided by `roles/ocp/configure_mcg` — keeping backup traffic entirely
on-cluster with no external dependency at all. This is the pattern for sovereign
bare-metal environments where even an external cloud S3 bucket isn't an option.

This keeps local PV and Kubernetes-resource backups on infrastructure the cluster
already owns.
