# sno_upgrade

Drives a `ClusterVersion` upgrade and waits for completion — meant to validate a
tailored "minimal-downtime maintenance" upgrade strategy for SNO against a real
cluster before documenting the production-facing runbook.

## Variables (pass with `-e`)

- `sno_upgrade_channel`: e.g. `stable-4.19`
- `sno_upgrade_target_version`: e.g. `4.19.4`
- `sno_upgrade_ack_key` (optional): admin-ack ConfigMap key if the target version
  requires acknowledging a removed API or known issue.
- `sno_upgrade_prune_images` (default `true`): runs `oc adm prune images --confirm`
  after the upgrade completes. This is a disk-constrained, single-node cluster on a
  fixed RAID5 pool — superseded release/operator/machine-os images aren't purged
  automatically by the upgrade itself and accumulate across every upgrade if left
  alone. Set `false` to skip (e.g. mid-investigation of a failed upgrade, where you
  want superseded images still present for debugging).

## Known gap: on-cluster Quay (application images) has no pruning here

The pruning step above only covers the cluster's own internal image registry
(release/operator/machine-os images, via `oc adm prune images`). It does **not**
touch `roles/ocp/configure_onprem_quay`'s long-term, post-install registry, which
serves application images and has no garbage-collection/tag-expiration policy
configured anywhere in that role today. Confirm an actual retention policy with the
customer (Quay's time-machine/tag-expiration settings are namespace-level, not a
one-shot prune command) before relying on that registry not filling the same RAID5
pool over time — not fixed here, flagged as a gap.

## Rollback

SNO has no second control-plane node to fail over to, so "rollback" in practice means
restoring from the OADP backup taken immediately before the upgrade
(`configure_oadp_backup`), not an in-place `oc adm upgrade` rollback. Document that
distinction explicitly in any production runbook — it's the single biggest difference
from a multi-node upgrade strategy.
