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

## Known gap

Unverified against a real AWS run since this restructuring.
