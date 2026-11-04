# aws_provision_sno_ipi

Runs on `staging` (`hosts: localhost`) — `openshift-install create cluster` needs
real internet access to reach Route53 and IAM/ccoctl (see
`aws_configure_manual_credentials`/`aws_configure_manual_dns` for why), which only
`staging` has in this split. `bastion` generates `install-config.yaml` itself
(colocated with `deploy_mirror_registry`'s facts) and hands it back to `staging` via
`bastion/roles/common/package_install_config_bundle` →
`staging/roles/common/unpack_install_config_bundle`, which must run before this role.

Unlike `main`'s original version of this role, this one does **not**
`include_role: generate_install_config` itself — that already happened on `bastion`.
Its self-heal block (destroy-and-retry on a stale `metadata.json`) also only clears
leftover state, not the freshly-unpacked `install-config.yaml`, since nothing in this
role regenerates it.

After a successful `create cluster`, `staging/playbooks/provision-sno-aws.yaml` runs
`wait_for_sno_install` (shared, provider-agnostic) and then
`package_kubeconfig_bundle` to hand `sno_kubeconfig` back to the bastion, so the
shared `roles/ocp/*` day-2 roles can run there unchanged.

## Known gap

Unverified against a real AWS run since this restructuring.
