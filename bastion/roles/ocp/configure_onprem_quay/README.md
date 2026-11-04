# configure_onprem_quay

Deploys a **lightweight, non-HA** on-cluster Quay registry for application
workloads — the long-term registry referenced in
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md#2-disconnected-content-mirroring),
distinct from the temporary bootstrap Quay (`mirror-registry`, via
`roles/common/deploy_mirror_registry`) used to stage install-time content.

Non-HA is deliberate, not a gap: there's no availability requirement at this scale,
and keeping Quay's footprint small matters more than registry redundancy on a true
SNO. `quay_replicas: 1` (default) is the actual, enforced replica count (see below) —
bump it if that priority ever changes.

Backs Quay's registry storage with an object bucket from the `openshift-storage`
NooBaa instance `roles/ocp/configure_mcg` provisions — this role must run after it.

## What's deliberately turned off to keep this lightweight

- `clair: managed: false` — vulnerability scanning brings its own Postgres-backed
  service; real weight for no stated requirement at this scale. Flip to `true` if
  image scanning becomes a requirement later.
- `mirror: managed: false` — Quay's own built-in repo-mirroring worker is unused;
  this repo's content flow is `oc-mirror`, not Quay's mirroring feature.
- `horizontalpodautoscaler: managed: false` — no autoscaling.
- Quay's app Deployment is explicitly scaled to `quay_replicas` (1) after creation —
  see "Known gaps" below for why this needs an explicit scale task rather than a CR
  field.
- **Kept as the operator's own managed, single-instance Postgres+Redis** for Quay's
  metadata/build-log DB, rather than sharing `configure_postgres`/`configure_redis`
  (the application's own instances) — deliberately not coupling Quay's availability
  to the application database's, even though sharing would save a bit more
  footprint. Revisit if resource pressure becomes a real constraint.

## Known gaps in this scaffold

- The operator-deployment readiness check in `tasks/main.yaml` can't predict the exact
  deployment name (it embeds a patch version) and is best-effort (`ignore_errors`) —
  confirm the operator is actually ready before the `ObjectBucketClaim` step runs, or
  add a `retries` loop against `csv` status instead.
- The `quay-app` Deployment is located via the `quay-component=quay-app` label
  selector (the operator's convention) rather than a predictable name, since the
  generated Deployment name includes the QuayRegistry name — verify this selector
  against the actual installed operator version on first real run.
