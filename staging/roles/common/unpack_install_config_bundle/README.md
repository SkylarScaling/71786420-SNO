# unpack_install_config_bundle

AWS-only. The staging-side counterpart of `bastion/roles/common/
package_install_config_bundle` — extracts the `install-config.yaml` tar.gz the
bastion produced into staging's own `install_dir`, so
`staging/roles/aws/aws_provision_sno_ipi` has something to run
`openshift-install create cluster` against. First task in
`staging/playbooks/provision-sno-aws.yaml`.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `install_config_bundle_path` | `~/sno-install-config-bundle.tar.gz` | Where the bastion-produced tar.gz landed (physically copied or rsynced). |

## Prerequisite

Copy (or rsync) the tar.gz `package_install_config_bundle` produced on the bastion
here first — this role only extracts what's already present.

## Known gap

Unverified against a real AWS run since this restructuring.
