# configure_alerting

Configures OpenShift's platform Alertmanager to send cluster health alerts by email
through the customer's own on-site SMTP relay.

## Mechanism

Overwrites the `alertmanager-main` Secret in `openshift-monitoring` (key
`alertmanager.yaml`) with a complete, minimal config: a single route and an
`email-notifications` receiver using `email_configs`. This is the long-standing,
universal OCP 4.x mechanism for custom Alertmanager config and works across versions,
unlike the newer `AlertmanagerConfig` CRD path (which requires
`enableUserWorkload`/platform-alertmanager-config feature gates that aren't assumed to
be enabled here).

## Known limitation — REPLACES, does not merge

This role overwrites the entire `alertmanager-main` Secret rather than merging into any
existing custom Alertmanager config. If the cluster already has other receivers,
inhibition rules, or routing trees configured by hand or by another automation, they
will be lost. Revisit this (read the existing Secret's `alertmanager.yaml`, parse and
merge YAML properly, e.g. with a small `community.general.jinja2`/`ansible.builtin.set_fact`
+ `combine` step or a dedicated filter) if the customer ever needs additional receivers
alongside email.

## Network assumption

The cluster is assumed to reach `alert_smtp_host` directly — same on-site network as
the SNO node, not the internet, consistent with the fully-disconnected design of this
repo. No mail relay, NAT, or firewall rule is provisioned by this role; if the real
environment needs one, it must be set up separately before this role will actually
deliver mail.

## Variables

| Variable           | Default                                        | Notes |
|---------------------|------------------------------------------------|-------|
| `alert_smtp_port`   | `25`                                             | SMTP port on the relay. |
| `alert_email_from`  | `alertmanager@{{ cluster_name }}.{{ base_domain }}` | Envelope/header "From" address. |
| `alert_smtp_host`   | *(none — required)*                             | Customer's on-site SMTP relay hostname/IP. **Not defaulted** — same precedence reason as `base_domain`/`aws_key_pair` in `playbooks/group_vars/all.yaml`. Set in `inventory/baremetal/inventory.yaml`'s `vars` block. |
| `alert_email_to`    | *(none — required)*                             | Real alert recipient address. **Not defaulted**, same reason as `alert_smtp_host`. |

The role fails fast with a clear message if `alert_smtp_host` or `alert_email_to` is
undefined or empty, same guard style as `roles/ocp/simulate_node_failure`.
