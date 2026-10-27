# configure_grafana

Installs the Grafana Operator and a minimal `Grafana` instance wired with `Loki` and
(optionally) `Tempo` datasources, giving a single pane of glass for logs and traces on
this SNO test harness.

## Dependencies

- **Hard dependency on `roles/ocp/configure_lokistack`**: the Loki datasource assumes
  that role's LokiStack CR (`loki_lokistack_name`, default `{{ cluster_name }}-loki`)
  already exists, and targets its generated query-frontend Service directly.
- **Soft dependency on `roles/ocp/configure_opentelemetry`**: the Tempo datasource is
  only created when `opentelemetry_tempo_enabled` is true (default), so this role
  doesn't hard-fail when a given environment runs logging without tracing.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `grafana_channel` | `v5` | **Verify** the real OperatorHub channel string/catalog before a real run. |
| `grafana_namespace` | `openshift-logging` | Reuses `configure_lokistack`'s namespace — simplest layout for a single small cluster. |
| `grafana_instance_name` | `{{ cluster_name }}-grafana` | Name of the `Grafana` CR and the label selector used by its `GrafanaDatasource`s. |
| `loki_lokistack_name` | `{{ cluster_name }}-loki` | **Must match** `configure_lokistack`'s value of the same name. |
| `loki_query_service` / `loki_query_port` | `{{ loki_lokistack_name }}-query-frontend-http` / `3100` | Derived LokiStack Service name/port — see caveat below. |
| `tempo_stack_name` | `{{ cluster_name }}-tempo` | **Must match** `configure_opentelemetry`'s TempoStack name. |
| `tempo_query_service` / `tempo_query_port` | `{{ tempo_stack_name }}-query-frontend` / `3200` | Derived TempoStack Service name/port — verify against a live cluster. |
| `opentelemetry_tempo_enabled` | `true` | Gates the Tempo datasource creation. |

## Known gaps / needs live-cluster verification

- `grafana_channel` placeholder — confirm exact channel/catalog source.
- The Loki datasource points at the LokiStack's query-frontend Service directly,
  bypassing the tenant gateway that `configure_lokistack`'s
  `spec.tenants.mode: openshift-logging` sets up. This is simplest for a one-off test
  cluster but may not actually be reachable/authorized — see
  `configure_lokistack`'s README for the same caveat. If it isn't, switch this
  datasource to the gateway Service with a bearer-token auth block instead.
- `loki_query_service`/`tempo_query_service` Service-name conventions
  (`<name>-query-frontend-http` / `<name>-query-frontend`) are the documented
  LokiStack/TempoStack naming patterns but haven't been confirmed against a live
  cluster for the exact operator versions in use — verify with
  `oc get svc -n {{ grafana_namespace }}` after those CRs reconcile.
- No readiness wait on the `Grafana` CR's own Deployment or on the `GrafanaDatasource`
  reconcile status — only the operator Deployment is polled.
