# bastion/

Runs directly on the bastion (`hosts: localhost` everywhere in this tree), once the
staging-produced `tar.gz` bundle has been physically copied (or rsynced) over and
extracted into an empty working directory here (so this `bastion/` directory sits
alongside the bundle's `mirror-content/`, `mirror-installers/`, and
`bastion-resolved-vars.yaml`). `provision-sno-baremetal.yaml`/`provision-sno-aws.yaml`'s
first task, `unpack_bastion_bundle`, lays all of that out and writes
`playbooks/group_vars/all.yaml` from the bundled resolved config — don't hand-edit
that file; edit `staging/inventory/inventory.yaml` and re-package/re-transfer
instead.

This tree is identical across both providers — no AWS-specific role exists anywhere
under `roles/common/` or `roles/ocp/`. On AWS, `provision-sno-aws.yaml` generates the
install-config and hands it back to the staging host, which runs the actual
`openshift-install create cluster` (see `docs/aws-test-environment-architecture.md`
§3 for why); `unpack-cluster-access.yaml` then unpacks the kubeconfig staging hands
back, after which day-2 roles run exactly as they do on bare metal.

## Credentials

Secrets (`pull_secret`, `ssh_key`) and all other per-environment values arrive via
the bundle, not by editing anything here directly — see `staging/README.md`'s
variable reference for where each one is actually set.

## Bastion-only variables

These are only ever passed as one-off `-e` overrides at run time on the bastion (no
need to round-trip them through the staging bundle):

| Variable | Used by | Notes |
|---|---|---|
| `sno_upgrade_channel`, `sno_upgrade_target_version`, `sno_upgrade_ack_key`, `sno_upgrade_prune_images` | `sno_upgrade` | set per upgrade run |
| `sno_node_name`, `simulate_node_failure_confirm` | `simulate_node_failure` | destructive drill guard |
| `bastion_bundle_dir` | `unpack_bastion_bundle` | where the extracted bundle landed (default `~/sno-deploy`) |
| `staging_transfer_method`, `staging_transfer_host`/`_user`/`_ssh_key`/`_dest_dir` | `package_staging_bundle` | `media` (default, physical transfer) or `rsync` (opt-in network push), for the backup-export relay back to staging |

## Common commands

```bash
cd bastion/playbooks

# Full production rollout, bare metal (provision + storage + MetalLB + logging +
# tracing + alerting + backup + Day 2 middleware)
ansible-playbook full-bastion-setup-baremetal.yaml -i ../inventory/inventory.yaml

# Just provision, bare metal (always disconnected: unpacks the bundle, deploys the
# mirror registry, generates the agent ISO, boots the node via BMC, then installs)
ansible-playbook provision-sno-baremetal.yaml -i ../inventory/inventory.yaml

# AWS only: generate the install-config and hand it back to staging to create the
# cluster (see docs/aws-test-environment-architecture.md §3)
ansible-playbook full-bastion-provision-aws.yaml -i ../inventory/inventory.yaml

# AWS only: once staging has created the cluster and handed the kubeconfig back,
# unpack it and run storage/logging/backup-dr (see that doc's §8 for why MetalLB/
# tracing/alerting/middleware aren't included here)
ansible-playbook full-bastion-configure-aws.yaml -i ../inventory/inventory.yaml

# Upgrade drill
ansible-playbook upgrade-sno.yaml -i ../inventory/inventory.yaml \
  -e sno_upgrade_channel=stable-4.19 -e sno_upgrade_target_version=4.19.4

# Node failure/recovery drill (destructive — single node)
ansible-playbook simulate-node-failure.yaml -i ../inventory/inventory.yaml \
  -e simulate_node_failure_confirm=true -e sno_node_name=<node>

# Tear down (bare metal)
ansible-playbook destroy-sno-baremetal.yaml -i ../inventory/inventory.yaml

# Tear down (AWS) — run staging/playbooks/destroy-sno-aws.yaml first, then
# aws-infra/playbooks/destroy-hosts.yaml; there is no bastion-side AWS teardown step

# Refresh mirrored content (after a new bundle produced by
# staging/playbooks/stage-and-package.yaml has been copied over) + deploy the
# on-cluster app Quay
ansible-playbook mirror-refresh.yaml -i ../inventory/inventory.yaml

# Export app S3 data out of the bastion (periodic/on-demand — there's no always-on
# path from the cluster to the internet)
ansible-playbook export-backup.yaml -i ../inventory/inventory.yaml
```
