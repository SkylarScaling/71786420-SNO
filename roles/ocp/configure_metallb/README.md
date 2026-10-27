# configure_metallb

Installs the MetalLB operator and creates a `MetalLB` CR, an `IPAddressPool`, and an
`L2Advertisement` so that non-HTTP(S) TCP middleware services can be exposed via
`type: LoadBalancer` Kubernetes Services.

## Why this is needed on a single-node, disconnected cluster

The default OCP Ingress Controller already handles HTTP(S) traffic to applications
without any VIP — true single-node doesn't need one for API/Ingress. MetalLB exists
here purely to give middleware services that speak raw TCP (not HTTP) — RabbitMQ/AMQP,
Postgres, Redis — a routable external IP, since Routes/Ingress can't front non-HTTP(S)
protocols. Those services themselves (the `Service` objects of `type: LoadBalancer`,
and the workloads behind them) are expected to be configured by the `configure_rabbitmq`,
`configure_postgres`, and `configure_redis` roles; this role only provides the
LoadBalancer IP infrastructure they depend on.

Layer 2 mode (`L2Advertisement`) is used rather than BGP — appropriate for a
single-switch, single-node bare-metal environment with no routing peer to speak BGP to.

## Variables

| Variable                | Default           | Notes |
|--------------------------|-------------------|-------|
| `metallb_channel`        | `stable`          | Operator subscription channel. |
| `metallb_namespace`      | `metallb-system`  | Namespace for operator + CRs. |
| `metallb_address_pool`   | *(none — required)* | Customer-provided IP range from their network team. **Not defaulted** — same precedence reason as `base_domain` in `playbooks/group_vars/all.yaml`: a real inventory override must win, so no generic value is set here. Must be set in `inventory/baremetal/inventory.yaml`'s `vars` block. Accepts a CIDR (e.g. `"192.168.1.240/28"`), an explicit range string (e.g. `"192.168.1.240-192.168.1.250"`), or a YAML list of either form — the role wraps a single string in a list automatically when templating `IPAddressPool.spec.addresses`. |

The role fails fast with a clear message if `metallb_address_pool` is undefined or
empty, same guard style as `roles/ocp/simulate_node_failure`.

## Known gaps

- Only a single `IPAddressPool`/`L2Advertisement` pair is created (`middleware-pool`).
  If RabbitMQ/Postgres/Redis later need separation (e.g. distinct pools per service),
  extend this role to accept a list of pools instead of one flat
  `metallb_address_pool`.
