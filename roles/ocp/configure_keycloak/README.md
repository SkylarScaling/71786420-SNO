# configure_keycloak

Installs the Red Hat build of Keycloak Operator and creates a single-instance
`Keycloak` CR backed by Postgres, plus an optional realm import. Single
replica — no HA requirement today.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `keycloak_operator_channel` | `stable` | |
| `keycloak_operator_package` | `rhbk-operator` | **Verify** the exact package name against the mirrored catalog — some catalog snapshots carry this as `keycloak-operator` instead. |
| `keycloak_catalog_source` / `keycloak_catalog_source_namespace` | `redhat-operators` / `openshift-marketplace` | |
| `keycloak_namespace` | `keycloak` | |
| `keycloak_replicas` | `1` | |
| `keycloak_storage_class` | `"{{ lvms_vg_name \| default('vg1') }}"` | Not directly consumed by the `Keycloak` CR itself (Keycloak stores no local PV state beyond Postgres), kept for parity/future use if file-based theme storage etc. is added. |
| `keycloak_db_host` | `postgres-primary.{{ postgres_namespace \| default('postgres') }}.svc` | **Assumption to verify.** Built from Crunchy PGO's `<clustername>-primary` Service naming convention for the `PostgresCluster` named `postgres` created by `roles/ocp/configure_postgres`. This isn't a documented stable contract — confirm the actual Service name (`oc get svc -n postgres`) once both roles have run against a live cluster, and override this var if it differs. |
| `keycloak_db_port` | `5432` | |
| `keycloak_db_name` | `keycloak` | A database/user named `keycloak` must exist in the PostgresCluster — this role does not create it; add a `database` entry to `configure_postgres`'s `PostgresCluster` CR (or create it manually) before relying on this. |
| `keycloak_db_secret_name` | `postgres-pguser-keycloak` | Expected Crunchy-generated user Secret name (`<clustername>-pguser-<username>` convention) — same caveat as `keycloak_db_host`, verify once live. |
| `keycloak_realm_file` | `""` | Empty by default. Set to a local path containing an app-specific realm JSON export to auto-import it. Authoring that realm config is app-specific and explicitly out of this repo's scope. |
| `keycloak_expose_external` | `false` | Reserved; Keycloak is exposed via the CR's built-in `ingress.enabled: true` (an OpenShift Route), not a LoadBalancer Service, so this var isn't currently wired to anything — kept for interface consistency with the other three roles. |

## Realm import lookup placement

`keycloak_realm_file`'s content is read via `lookup('file', ...)` in
`tasks/main.yaml` (a `set_fact`), not inside
`templates/keycloak-realm-import.yaml.j2`. The file's JSON content needs to be
embedded as an indented YAML block scalar inside the `KeycloakRealmImport`
CR, which is simpler to get right once in a task than re-deriving indentation
inside the template on every render. This differs slightly from the
`ssh_key`/`pull_secret` pattern in `playbooks/group_vars/all.yaml`, which
inlines the `lookup()` directly in the var's default value — that pattern
doesn't fit here because those vars are plain strings substituted directly,
not multi-line content that needs YAML-safe indentation.

## Cross-role dependencies

- **`roles/ocp/configure_postgres` must run first.** This role assumes a
  `PostgresCluster` named `postgres` already exists in the `postgres`
  namespace (that role's defaults) and that a `keycloak` database/user has
  been provisioned on it — neither is created automatically by this role.
- `keycloak_storage_class` defaults to `configure_lvms`'s `lvms_vg_name`,
  though it isn't currently consumed anywhere in this role's templates.

## Known gaps

- No automatic creation of the `keycloak` Postgres database/user — add a
  `database:`/`users:` entry to `configure_postgres`'s `PostgresCluster` CR,
  or provision it manually, before this role's `Keycloak` CR can actually
  connect.
- `keycloak_realm_file` defaults to empty — without it, Keycloak comes up
  with no realms beyond `master`, and the application team must either set
  this var or import their realm manually post-install.
