# aws_configure_manual_dns

Companion to `staging/roles/aws/aws_configure_manual_credentials` — together they fix the two
independent reasons the default ingress controller degrades on a real run:
credentials (fixed by Manual mode + ccoctl, see that role's README) and, separately,
**Route53 itself has no VPC endpoint at all**, so the ingress-operator can never reach
`route53.amazonaws.com` to write the `*.apps` wildcard DNS record from inside the
cluster — regardless of whether its credentials are valid. This is a network
reachability problem, not a credentials problem, and Manual mode alone does not fix
it.

Confirmed against a real run: left as the default `Managed` policy, the ingress
controller's `DNSRecord` reported `DNSReady=False (NoZones: The record isn't present
in any zones.)`, which cascaded into `authentication`/`console` never reporting
Available (both resolve hostnames under `*.apps...`) and `openshift-install create
cluster` timing out waiting for cluster operators.

## Two-part fix

1. **`tasks/main.yaml`** (run before `create cluster`, from `aws_provision_sno_ipi`):
   renders an extra manifest setting the default `IngressController`'s
   `spec.endpointPublishingStrategy.loadBalancer.dnsManagementPolicy: Unmanaged` —
   this stops the ingress-operator from ever attempting the Route53 call itself, so it
   doesn't degrade waiting on something that can never succeed from inside the
   cluster. The same manifest also sets `scope: Internal` — the SNO node has no
   internet route at all, so an internet-facing (the default, `External`) ELB for the
   router is unreachable from inside the cluster's own machine network. Confirmed
   live: with `scope: External`, console/authentication/the ingress canary check all
   failed with "context deadline exceeded" dialing the apps Classic ELB even after its
   DNS record resolved correctly (verified via a direct AWS API check that its
   `Scheme` was `internet-facing`). `Internal` creates a VPC-private ELB reachable from
   the SNO node (and staging/bastion, both in the same VPC) over normal VPC routing —
   same reasoning as the API load balancer already being internal for `api-int`.

2. **`tasks/create_apps_record.yml`** (included from `aws_provision_sno_ipi`'s
   `rescue:` block, after `create cluster`'s own operator-wait fails as expected):
   reads the `router-default` Service's ELB hostname (that part succeeds fine — ELB
   creation goes through EC2/ELB APIs, which DO have VPC endpoints) and publishes a
   `*.apps.<cluster>.<base_domain>` CNAME to it directly from the controller — exactly
   mirroring how `api`/`api-int` already work (openshift-install creates those from
   the controller too, never from inside the cluster). Written to **both** the
   account's public hosted zone (so the record resolves from outside AWS, same as
   `api`) and the cluster's own private hosted zone (so in-cluster CoreDNS's upstream
   resolution via the VPC's own resolver also finds it) — confirmed via direct
   inspection of the real zones/records this produced for `api`/`api-int`, which
   follow the identical two-zone pattern.

   The public zone is found by exact name match among non-private zones for
   `base_domain` (the same zone openshift-install itself auto-discovers for
   `publish: External`). The private zone is found by exact name match for
   `<cluster_name>.<base_domain>` specifically — **not** just "any private zone
   associated with our VPC", since `aws_provision_bastion`'s separate
   `mirror.{{ base_domain }}` private zone is also associated with the same VPC and
   would otherwise collide.

`aws_provision_sno_ipi`'s rescue block then re-runs
`openshift-install wait-for install-complete` — the exact recovery path
`create cluster`'s own error output suggests — rather than treating the first
operator-wait timeout as a hard failure.
