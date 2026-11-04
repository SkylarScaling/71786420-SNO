# configure_redis

Deploys Redis as a plain, single-replica `StatefulSet` — no operator, no
clustering/sentinel, no HA. This is a deliberate design choice, not a
scaffold left unfinished: there is no free Red Hat-distributed Redis
Operator (Redis Enterprise requires separate licensing beyond standard
OperatorHub subscriptions), and the customer's stated priorities are "keep it
cheap and simple" plus "no current HA needs." A plain StatefulSet is the
cheapest thing that satisfies both.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `redis_namespace` | `redis` | |
| `redis_replicas` | `1` | Single replica — intentionally no clustering. |
| `redis_storage_size` | `5Gi` | |
| `redis_storage_class` | `"{{ lvms_vg_name \| default('vg1') }}"` | Defaults to the LVMS-provided storage class. |
| `redis_image` | `registry.redhat.io/rhscl/redis-6-rhel7` | **Verify** this is the actual image present in the mirrored content set — pick whatever Red Hat-distributed Redis image tag is current and confirmed mirrored before first run. |
| `redis_expose_external` | `false` | When `true`, creates a `type: LoadBalancer` Service annotated `metallb.io/address-pool: default`. |

## What this is NOT

No HA, no clustering, no Sentinel, no persistence guarantees beyond a single
PVC on a single pod. If HA ever becomes a requirement, replace this role's
StatefulSet with either the community Redis Operator (via a custom
CatalogSource, since it's not in redhat-operators) or Redis Enterprise
(separate commercial licensing) — at that point this role's `tasks/main.yaml`
would be replaced wholesale with a Subscription + custom-resource flow
matching the pattern used by `configure_rabbitmq`/`configure_postgres`/
`configure_keycloak`, rather than extended in place.

## Cross-role dependencies

- Storage class defaults to `configure_lvms`'s `lvms_vg_name`.
- `redis_expose_external: true` requires `roles/ocp/configure_metallb` to have
  already provisioned an `IPAddressPool`, or the LoadBalancer Service will
  stay `<pending>` indefinitely. In-cluster consumers can always reach Redis
  via the `redis` ClusterIP Service regardless of this setting.
