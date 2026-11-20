# configure_rabbitmq

Installs the RabbitMQ Cluster Operator and creates a single-replica
`RabbitmqCluster` CR for the application's message broker — "cheap and
simple" per the customer's stated priorities, no clustering/HA.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `rabbitmq_operator_channel` | `"{{ operator_catalog.rabbitmq.channel }}"` | Single source is `operator_catalog.rabbitmq` in `staging/inventory/inventory.yaml`, shared with `stage_mirror_content`'s mirrored pin. |
| `rabbitmq_catalog_source` | derived from `operator_catalog.rabbitmq.catalog` (default `community`) | The RabbitMQ Cluster Operator package (`rabbitmq-cluster-operator`) isn't reliably carried in `redhat-operators` — confirmed mirrored from `community-operators`. |
| `rabbitmq_catalog_source_namespace` | `openshift-marketplace` | |
| `rabbitmq_namespace` | `rabbitmq` | |
| `rabbitmq_replicas` | `1` | Single replica — no HA requirement today. |
| `rabbitmq_storage_size` | `10Gi` | |
| `rabbitmq_storage_class` | `"{{ lvms_vg_name \| default('vg1') }}"` | Defaults to the LVMS-provided storage class from `roles/ocp/configure_lvms`. |
| `rabbitmq_expose_external` | `false` | When `true`, creates a `type: LoadBalancer` Service for AMQP (5672) annotated `metallb.io/address-pool: default`. |

## Cross-role dependencies

- Storage class defaults to whatever `configure_lvms` provisions
  (`lvms_vg_name`). If LVMS hasn't run, set `rabbitmq_storage_class`
  explicitly to a StorageClass that exists.
- `rabbitmq_expose_external: true` requires `roles/ocp/configure_metallb` to
  have already created an `IPAddressPool` — without it the LoadBalancer
  Service will stay `<pending>` indefinitely. Leave `rabbitmq_expose_external`
  at its default `false` if MetalLB isn't installed; in-cluster consumers can
  always reach RabbitMQ via the ClusterIP Service the operator creates
  (`rabbitmq` in `rabbitmq_namespace`) regardless of this setting.

## Known gaps

- No TLS, no vhost/user provisioning beyond the operator's defaults, no
  queue/exchange definitions — those are application-specific and out of
  scope here, same as the Postgres role leaves realm/schema specifics to the
  app.
