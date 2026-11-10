# package_install_config_bundle

AWS-only. Packages `{{ install_dir }}/install-config.yaml` (and nothing else — see
below) for the trip from `bastion` back to `staging`, where
`staging/roles/aws/aws_provision_sno_ipi` actually runs `openshift-install create
cluster`. Called from `bastion/playbooks/provision-sno-aws.yaml`, after
`generate_install_config`.

## Why install-config.yaml only

`generate_install_config` must still run on the bastion, colocated with
`deploy_mirror_registry`'s `mirror_registry_ca_cert`/`mirror_registry_auth_b64` facts
(same reason as bare metal). But cluster creation can't happen there for AWS (no VPC
endpoint for Route53/IAM — see `staging/roles/aws/aws_provision_sno_ipi`'s README), so
the one artifact that matters — the fully rendered `install-config.yaml`, CA bundle
and merged pull secret already baked in — has to travel back to staging. Nothing else
in `install_dir` is needed there yet; `aws_configure_manual_credentials`/
`aws_configure_manual_dns` add their own manifests directly into staging's local
`install_dir` after `unpack_install_config_bundle` lays this one file down.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `install_config_transfer_method` | `media` | `media` (default) produces the tar.gz and prints instructions. `rsync` (opt-in, the typical AWS choice since a live VPC path exists) also pushes it directly. |
| `install_config_bundle_export_dir` | `/tmp/bastion-export` | |
| `install_config_bundle_name` | `sno-install-config-{{ cluster_name }}.tar.gz` | |
| `install_config_transfer_host`/`_user`/`_ssh_key`/`_dest_dir` | unset / `root` / `{{ ssh_private_key }}` / `/root` | Only used when `install_config_transfer_method: rsync`. |

## Automatic rsync

Set `install_config_transfer_method: rsync` and `install_config_transfer_host`/
`_user`/`_dest_dir` in `staging/inventory/inventory.yaml` (already the default for
AWS in `inventory-aws.yaml.j2`, pointed at the mirror-staging host's private IP) and
this role pushes the bundle itself instead of printing manual-copy instructions. This
needs `ssh_private_key` (`_ssh_key`'s default) to resolve to a real file on the
bastion — `unpack_bastion_bundle` stages one there automatically from the main
bundle's `relay-key` (see that role's README); don't point `_ssh_key` at a path that
doesn't exist on the bastion itself.

## Known gap

Unverified against a real AWS run since this restructuring.
