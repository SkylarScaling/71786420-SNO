# configure_postgres

Installs the Crunchy PostgreSQL Operator (PGO) and creates a single-instance
`PostgresCluster` CR, plus an optional pgAdmin UI. "Cheap and simple" per the
customer's stated priorities — no HA/replica set.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `postgres_operator_channel` | `v5` | **Verify** against the mirrored catalog/CSV — Crunchy PGO's channel naming has shifted across major versions. |
| `postgres_catalog_source` / `postgres_catalog_source_namespace` | `redhat-operators` / `openshift-marketplace` | Verify the `crunchy-postgres-operator` package is actually present in whichever catalog was mirrored. |
| `postgres_namespace` | `postgres` | |
| `postgres_replicas` | `1` | Single instance — no HA requirement today. |
| `postgres_storage_size` | `20Gi` | Used for both the data volume and the pgBackRest repo volume. |
| `postgres_storage_class` | `"{{ lvms_retain_storage_class_name \| default('vg1-retain') }}"` | Defaults to `configure_lvms`'s Retain-policy StorageClass, not the shared `vg1` (Delete) default — see "Storage class" below. |
| `pgadmin_enabled` | `true` | Deploys a plain pgAdmin Deployment+Service+Route (no operator exists for pgAdmin). |
| `pgadmin_image` | `docker.io/dpage/pgadmin4:latest` | See mirroring gap below. |
| `pgadmin_default_email` / `pgadmin_default_password` | `admin@example.com` / `changeme` | Change these for anything beyond throwaway testing. |
| `postgres_expose_external` | `false` | Reserved for a future LoadBalancer Service for the Postgres port; not wired up in this scaffold since direct external DB access is unusual — app workloads should reach Postgres in-cluster via the Crunchy-generated Service. |

## pgAdmin image mirroring gap

This is a disconnected-only repo (see top-level `CLAUDE.md`) — nothing reaches
the cluster that wasn't staged through
`roles/common/stage_mirror_content` → `sync_mirror_to_bastion` →
`deploy_mirror_registry`. That pipeline's `oc_mirror_operator_packages` var
only handles **operator catalog images** (OLM bundles + their related images).
`dpage/pgadmin4` is a plain Docker Hub container image with no operator
wrapping it, so it is **not** covered by that pipeline and the pgAdmin
Deployment will fail to pull on a real disconnected cluster unless the image
is mirrored separately — e.g. `oc image mirror dpage/pgadmin4:latest
<mirror-registry>/dpage/pgadmin4:latest` run manually/added as an extra step
in the staging pipeline, or by pushing the image into the on-cluster Quay from
`roles/ocp/configure_onprem_quay` and pointing `pgadmin_image` at that
registry instead. This role does not attempt to solve generic arbitrary-image
mirroring — flagged here as a known gap, not fixed.

## Storage class

Unlike every other block-storage consumer in this repo (RabbitMQ, Redis, LokiStack,
TempoStack), Postgres defaults to `configure_lvms`'s Retain-policy StorageClass
(`{{ lvms_retain_storage_class_name }}`, default `vg1-retain`) rather than the shared
`vg1` (Delete reclaim) default. Postgres holds stateful application data as its source
of truth with no separate durable copy elsewhere — Retain protects the volume from
being wiped by an accidental namespace/`PostgresCluster` deletion, closing the gap
between `configure_oadp_backup`'s backup windows. `vg1-retain` is a plain
`StorageClass` pointed at the same underlying `vg1` device class (not a second LVMS
deviceClass/thin pool) — see `configure_lvms`'s README for why.

## Cross-role dependencies

- Storage class defaults to `configure_lvms`'s `lvms_retain_storage_class_name`
  (requires `configure_lvms` to have run first, same as before).
- Real backup/DR (retention, offsite copies) is intentionally left to
  `roles/ocp/configure_oadp_backup` — the `backups.pgbackrest` stanza here
  only provisions a local PVC repo so PGO is functional, it is not a backup
  strategy.
- `roles/ocp/configure_keycloak` expects a Postgres Service it can point its
  `database` stanza at — see that role's README for the exact Service-name
  assumption to verify once both roles have run against a live cluster.
