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
   `imageDigestSources`/`additionalTrustBundle` always point at
   (`bastion/roles/common/generate_install_config` has no connected fallback). The
   `mirror-registry`/`oc-mirror`/`openshift-install`/`oc` tool tarballs themselves
   are also downloaded on staging in step 1 and carried over by step 2, not fetched
   directly on the bastion — it has no internet route to do that with either.
4. Install via the Agent-Based Installer — the cluster node never reaches the public
   internet.
5. Post-install, deploy an on-cluster, highly available Quay registry
   (`roles/ocp/configure_onprem_quay`) to serve application images going forward —
   the bastion's mirror registry is for install-time content only.

The bastion's own OS-level RPM dependencies (`dnsmasq`/`httpd`/etc., installed by
`bastion/roles/common/configure_bastion_services`) follow the same stage → package →
unpack shape but travel through their **own**, independently-runnable pipeline —
`staging/roles/common/sync_bastion_rpms` → `package_bastion_rpms_bundle` →
`bastion/roles/common/unpack_bastion_rpms_bundle` — with its own tar.gz
(`sno-bastion-rpms-*.tar.gz`) and standalone playbooks on both ends
(`staging/playbooks/sync-bastion-rpms.yaml`, `bastion/playbooks/unpack-bastion-rpms.yaml`),
separate from the content-mirroring pipeline above. This was split out on 2026-11-17
at customer request: a full `reposync` of the bastion's required repos can run 8+
hours on its own, and tying it to the (also hours-long) oc-mirror "mirror to disk"
step meant neither could be retried or refreshed without redoing the other. Both
pipelines are still wired into the combined `stage-and-package.yaml`/
`provision-sno.yaml` flows, so a normal end-to-end run is unaffected — the standalone
path exists purely so either half can be re-run alone.

## 2. Per-environment vars propagate from staging to the bastion through one explicit, maintained list

`staging/inventory/inventory.yaml` is the single source of per-environment config for
*both* staging and the bastion (see point 1) — `package_bastion_bundle` flattens it
into a resolved-vars file that `unpack_bastion_bundle` writes verbatim to
`bastion/group_vars/all.yaml`. That flattening (`templates/bastion-resolved-vars.yaml.j2`)
hand-lists each var explicitly rather than dumping every role's defaults wholesale —
deliberately, since most staging-side role defaults are staging-local storage
paths/URLs (`oc_mirror_workspace`, `mirror_installers_dir`, `ocp_mirror_url`, etc.)
that must stay independent per host, matching separately-defined defaults on the
bastion side. Dumping them wholesale would silently push one host's absolute paths
onto the other.

**The hand-listed set (plus `package_bastion_bundle`'s small per-role allowlists, e.g.
`stage_mirror_content`'s `_stage_mirror_bastion_facing_vars`) is meant to be kept
current as the complete, reviewable record of what crosses over** — not something to
route around. Confirmed live as a real gap from letting that upkeep lag: a customer's
`bastion_rpm_sync_method: resolve` override had no effect on the bastion at all,
because that var had never been added to the hand-listed set, so the override never
reached `bastion/group_vars/all.yaml`.

A separate, narrower mechanism exists purely for one-off/iterative testing: any var
added directly to `inventory.yaml`'s own `vars:` block — with no role default and not
yet on any explicit list — still reaches the bastion automatically, so testing isn't
blocked on a code change first. That's a convenience for testing, not a substitute
for the explicit lists above — once an ad-hoc var turns out to be a permanent
fixture rather than a one-off, it should be migrated into the hand-listed set (or the
relevant role's allowlist) like any other permanent var, not left to ride along on
the fallback indefinitely. See `staging/roles/common/package_bastion_bundle`'s README
for the mechanics.

## 3. Data protection & storage isolation

OADP backups (`roles/ocp/configure_oadp_backup`) target the in-cluster NooBaa S3
endpoint provided by `roles/ocp/configure_mcg` — keeping backup traffic entirely
on-cluster with no external dependency at all. This is the pattern for sovereign
bare-metal environments where even an external cloud S3 bucket isn't an option.

This keeps local PV and Kubernetes-resource backups on infrastructure the cluster
already owns.
