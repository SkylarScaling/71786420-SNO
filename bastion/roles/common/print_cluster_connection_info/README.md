# print_cluster_connection_info

Prints a short "how do I connect to this cluster" summary — API server URL, web
console URL, the kubeconfig path, and (when present on this host) the kubeadmin
password file path. Runs as the final task of each provider's full day-2-configure
playbook (`full-bastion-configure-aws.yaml`, `full-bastion-setup-baremetal.yaml`) so a
completed run ends with something actionable instead of just a PLAY RECAP.

Provider-agnostic — reads everything it needs from `sno_kubeconfig` and the live
cluster, same as every other `roles/ocp/*`/`roles/common/*` role.

## What it prints

- `API server` — read directly from `sno_kubeconfig`'s own `clusters[0].cluster.server`
  field, not reconstructed from a `base_domain`/`cluster_name` pattern.
- `Web console` — the `console` Route's host in `openshift-console`, looked up live
  (`ignore_errors: true` — a missing Route degrades to a note, not a task failure).
- `kubeconfig` — `sno_kubeconfig`'s path, plus the `export KUBECONFIG=...` command to
  use it.
- `kubeadmin password file` — **conditional on actually existing on this host.**
  `kubeadmin-password` is never bundled alongside `sno_kubeconfig` by either
  provider's handback path (`package_bastion_bundle`, `unpack_kubeconfig_bundle`) —
  it's gitignored repo-wide (`**/auth/kubeadmin-password`) and only ever exists on
  whichever host actually ran `openshift-install create cluster`:
  - **Bare metal**: that's this bastion (`wait_for_sno_install` runs here), so the
    file is present and its path is printed directly.
  - **AWS**: that's `staging` (`aws_provision_sno_ipi`), never copied to the bastion.
    This role prints a note pointing at staging's `install_dir` instead of a path
    that doesn't exist here.
- `SOCKS tunnel command` — **AWS only** (`infra_provider == 'aws'`). `generate_install_config`
  sets `publish: External`, so the API load balancer is internet-reachable directly —
  but `aws_configure_manual_dns` deliberately sets the default Ingress's ELB to
  `scope: Internal` (the SNO node has no internet route, so an internet-facing apps
  ELB would be unreachable from inside the cluster's own machine network). Confirmed
  live: the console hostname resolves publicly but only to an
  `internal-*.elb.amazonaws.com` with private IPs — a laptop outside the VPC can't
  route to it directly. This prints the `ssh -D ... -N` command through
  `mirror-staging` (public subnet, same VPC, has a route to that private ELB) needed
  to reach the console from a local browser via a SOCKS5 proxy. Bare metal has no
  such split (the console is directly reachable on the customer's own LAN), so this
  block doesn't print there.

## Variables

Uses only variables already set elsewhere in this repo — no new defaults file:
`sno_kubeconfig`, `install_dir`, `infra_provider`, and (AWS only)
`mirror_staging_public_ip`/`mirror_staging_ssh_user` (added to
`staging/inventory/inventory-aws.yaml.j2` and carried to the bastion via
`bastion-resolved-vars.yaml.j2` — see those files' comments).
