# configure_opentelemetry

## tl;dr

Installs the (Red Hat build of) OpenTelemetry Operator and Tempo Operator, an
`OpenTelemetryCollector` with an OTLP receiver, and a `TempoStack` for trace storage —
giving applications on this SNO cluster an OTLP endpoint to send distributed traces to,
and wiring those traces into the same observability stack as `configure_lokistack`/
`configure_grafana`.

### To use this correctly:

- Requires `configure_mcg` to have already run (see "Hard dependency" below).
- Both operators' OperatorGroups use AllNamespaces (`spec: {}`) — based on Red Hat's
  documented install steps, not a confirmed CSV check (see "OperatorGroup scoping"
  below). If either Subscription is ever rejected with `OwnNamespace InstallModeType
  not supported`, that confirms it; if instead it's accepted but behaves oddly,
  that's a sign this assumption needs revisiting.
- If you split `tempo_namespace` from `otel_namespace`, Tempo gets its own
  Namespace/OperatorGroup automatically — don't also hand-create one, see
  "OperatorGroup scoping" below.

## Full Details:

## Hard dependency

Requires `roles/ocp/configure_mcg` to have already provisioned the standalone NooBaa
instance (namespace `openshift-storage`, StorageClass `openshift-storage.noobaa.io`)
that this role's Tempo `ObjectBucketClaim` targets — identical pattern to
`configure_lokistack`'s and `configure_onprem_quay`'s OBCs.

## Where applications send traces

Point application OTLP exporters at the Collector Service:
- gRPC: `{{ otel_collector_name }}-collector.{{ otel_namespace }}.svc.cluster.local:4317`
- HTTP: `{{ otel_collector_name }}-collector.{{ otel_namespace }}.svc.cluster.local:4318`

(The OpenTelemetry Operator generates a `<CR name>-collector` Service for a
`mode: deployment` `OpenTelemetryCollector` — verify the exact name against
`oc get svc -n {{ otel_namespace }}` once the operator reconciles it.)

## Grafana wiring

`roles/ocp/configure_grafana`'s Tempo `GrafanaDatasource` points at this role's
TempoStack query-frontend Service (`tempo_stack_name` must match
`configure_grafana`'s `tempo_stack_name` default). Set `opentelemetry_tempo_enabled:
false` in both roles together to skip tracing entirely for an environment.

## OperatorGroup scoping

Both `otel-subscription.yaml.j2` and `tempo-subscription.yaml.j2` use AllNamespaces
(`spec: {}`), not `targetNamespaces` — Red Hat's own install docs for both operators
show their OperatorGroup with no `targetNamespaces` at all, matching the
`OwnNamespace`-unsupported bug class confirmed live for MetalLB and the Loki
Operator (see `configure_metallb`'s and `configure_lokistack`'s READMEs). This
hasn't been confirmed against the literal CSV `installModes` the way those two were
(Red Hat's build isn't in the public bundle repos), so if a live run ever rejects
either Subscription on InstallMode grounds despite this, that's new information —
update this note.

`tempo_namespace` defaults to `{{ otel_namespace }}` (same namespace as the
OpenTelemetry Collector operator) — `tempo-subscription.yaml.j2` only creates its
own Namespace/OperatorGroup when `tempo_namespace` differs from `otel_namespace`;
otherwise it reuses the OperatorGroup `otel-subscription.yaml.j2` already created.
Two separately-named OperatorGroups in the same namespace fail with
`TooManyOperatorGroups` regardless of InstallMode — same conflict `configure_mcg`
avoids in `openshift-storage` by reusing `configure_lvms`'s OperatorGroup instead of
creating its own.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `otel_namespace` | `openshift-opentelemetry` | Namespace for both the Collector operator/CR and (by default) Tempo. |
| `otel_channel` | `stable` | **Verify** against the mirrored catalog. |
| `tempo_namespace` | `{{ otel_namespace }}` | Deliberately shared with the Collector's namespace — simplest for a single small cluster; override to split them. |
| `tempo_channel` | `stable` | **Verify** against the mirrored catalog. |
| `tempo_bucket_name` | `{{ cluster_name }}-tempo` | Name of the Tempo `ObjectBucketClaim`/bucket. |
| `tempo_size` | `1x.extra-small` | Smallest documented TempoStack size tier; bump per-environment once real trace volume is known. |
| `tempo_stack_name` | `{{ cluster_name }}-tempo` | **Must match** `configure_grafana`'s `tempo_stack_name`. |
| `tempo_storage_class` | `{{ lvms_vg_name \| default('vg1') }}` | Block storage for TempoStack's own local/WAL storage. |
| `opentelemetry_tempo_enabled` | `true` | Master switch; `configure_grafana` reads the same var name to gate its Tempo datasource. |
| `otel_collector_name` | `{{ cluster_name }}-otel-collector` | Name of the `OpenTelemetryCollector` CR. |

## Known gaps / needs live-cluster verification

- Subscription package names `opentelemetry-product` and `tempo-product` are the
  typical Red Hat OperatorHub names for these builds — **verify** against the
  mirrored catalog; these have been known to change during rebrands.
- `otel_channel`/`tempo_channel` default to `stable` as a placeholder — verify exact
  channel strings.
- The Collector's exporter endpoint (`{{ tempo_stack_name }}-distributor`) and the
  Grafana datasource's query-frontend Service name are both *assumed*
  TempoStack-generated Service names — verify both against `oc get svc` once the
  Tempo Operator CRD is installed, naming has shifted across operator releases.
- `templates/tempo-storage-secret.yaml.j2` field names (`access_key_id`,
  `access_key_secret`, `bucket`, `endpoint`) — verify against
  `oc explain tempostack.spec.storage.secret` on a live cluster.
- No readiness wait on the TempoStack's own component Deployments or the Collector
  Deployment — only the two operator Deployments are polled.
- The `tempo-operator-controller-manager` vs `tempo-operator-controller` Deployment
  name used in the wait task is a best guess at the operator's generated name —
  confirm against `oc get deploy -n {{ tempo_namespace }}` and adjust if it differs.
