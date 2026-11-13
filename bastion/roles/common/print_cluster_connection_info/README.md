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

## Variables

Uses only variables already set elsewhere in this repo — no new defaults file:
`sno_kubeconfig`, `install_dir`.
