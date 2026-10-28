# package_kubeconfig_bundle

AWS-only. Packages `{{ sno_kubeconfig }}` for the trip from `staging` back to the
bastion, after `aws_provision_sno_ipi`/`wait_for_sno_install` succeed. Called from
`staging/playbooks/provision-sno-aws.yaml`, last step.

## Why this exists

The cluster's kubeconfig only exists where `openshift-install create cluster` ran —
`staging`, for AWS (see `staging/roles/aws/aws_provision_sno_ipi`'s README for why).
But every `roles/ocp/*` day-2 role runs on the bastion, so `bastion/` stays identical
across both providers — keeping it that way is the whole point of this split. This
role is the last leg of the 3-hop handoff (bastion generates install-config → staging
creates the cluster → bastion gets the kubeconfig back).

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `kubeconfig_transfer_method` | `media` | `media` (default) produces the tar.gz and prints instructions. `rsync` (opt-in, the typical AWS choice since a live VPC path exists) also pushes it directly. |
| `kubeconfig_bundle_export_dir` | `/tmp/staging-export` | |
| `kubeconfig_bundle_name` | `sno-kubeconfig-{{ cluster_name }}.tar.gz` | |
| `kubeconfig_transfer_host`/`_user`/`_ssh_key`/`_dest_dir` | unset / `root` / `{{ ssh_private_key }}` / `/root` | Only used when `kubeconfig_transfer_method: rsync`. |

## Known gap

Unverified against a real AWS run since this restructuring.
