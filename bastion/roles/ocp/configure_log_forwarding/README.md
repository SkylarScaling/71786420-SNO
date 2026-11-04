# configure_log_forwarding

Installs the Cluster Logging operator and a `ClusterLogForwarder` sending
application/infrastructure/audit logs to an external SIEM/audit endpoint, and
(by default) a second, parallel output to the in-cluster LokiStack.

## Dual-output behavior

The `ClusterLogForwarder` this role creates fans the same
application/infrastructure/audit logs out to **two** independent outputs/pipelines:
- `siem-output` / `forward-to-siem`: present whenever `log_forward_endpoint` is set,
  using `log_forward_type` as before — unaffected by the Loki changes below. **This
  is a placeholder output, not a production-ready integration**: the real external
  SIEM target and its auth model (token vs. mTLS) haven't been finalized with the
  customer, and (see "Not yet included" below) the RBAC this output's ServiceAccount
  needs isn't wired up yet either. Don't treat this as a finished feature until both
  are confirmed against a real target.
- `lokistack-output` / `forward-to-lokistack`: a `type: lokiStack` output targeting
  the LokiStack CR created by `roles/ocp/configure_lokistack`, authenticating via a
  ServiceAccount token (the `lokiStack` output type talks to the LokiStack's gateway
  directly by CR reference, so no Service hostname is needed here — unlike
  `configure_grafana`'s Loki datasource, which does need one).

Set `loki_output_enabled: false` to disable the Loki output and keep only the SIEM
forward (e.g. an environment that doesn't deploy `configure_lokistack` at all).

**Hard dependency**: when `loki_output_enabled` is true (the default), this role
requires `roles/ocp/configure_lokistack` to have already created the LokiStack CR
named `loki_lokistack_name` (default `{{ cluster_name }}-loki`) in `loki_namespace`
(default `openshift-logging`) — both values must match `configure_lokistack`'s
defaults of the same name.

## Not yet included

- The `log-collector` ServiceAccount and its `ClusterRoleBinding`s
  (`collect-application-logs`, `collect-infrastructure-logs`, `collect-audit-logs`)
  referenced by `spec.serviceAccount.name` — add them here once the target SIEM and
  its auth model (mTLS vs token) are confirmed, since the RBAC and any TLS secret
  differ by target.
- Retention policy / local log rotation — this role only covers forwarding, not
  in-cluster retention sizing (see `roles/ocp/configure_lokistack`'s README for how
  LokiStack's own retention is configured).
- The `lokiStack` output type's RBAC requirements (the ServiceAccount referenced by
  `spec.serviceAccount.name` needs permission to write to the LokiStack's
  application/infrastructure/audit tenants under `tenants.mode: openshift-logging`)
  aren't set up here — confirm against a live cluster whether the default
  `log-collector` ServiceAccount already has this via the Cluster Logging operator's
  own RBAC bootstrap, or whether an explicit ClusterRoleBinding is needed.
