# bastion/

Runs directly on the bastion (`hosts: localhost` everywhere in this tree), once the
staging-produced `tar.gz` bundle has been physically copied (or rsynced) over and
extracted into an empty working directory here (so this `bastion/` directory sits
alongside the bundle's `mirror-content/`, `mirror-installers/`, and
`bastion-resolved-vars.yaml`). `provision-sno.yaml`'s first task,
`unpack_bastion_bundle`, lays all of that out and writes
`playbooks/group_vars/all.yaml` from the bundled resolved config — don't hand-edit
that file; edit `staging/inventory/inventory.yaml` and re-package/re-transfer
instead.

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

# Full production rollout (provision + storage + MetalLB + logging + tracing +
# alerting + backup + Day 2 middleware)
ansible-playbook full-bastion-setup.yaml -i ../inventory/inventory.yaml

# Just provision (always disconnected: unpacks the bundle, deploys the mirror
# registry, generates the agent ISO, boots the node via BMC, then installs)
ansible-playbook provision-sno.yaml -i ../inventory/inventory.yaml

# Upgrade drill
ansible-playbook upgrade-sno.yaml -i ../inventory/inventory.yaml \
  -e sno_upgrade_channel=stable-4.19 -e sno_upgrade_target_version=4.19.4

# Node failure/recovery drill (destructive — single node)
ansible-playbook simulate-node-failure.yaml -i ../inventory/inventory.yaml \
  -e simulate_node_failure_confirm=true -e sno_node_name=<node>

# Tear down
ansible-playbook destroy-sno.yaml -i ../inventory/inventory.yaml

# Refresh mirrored content (after a new bundle produced by
# staging/playbooks/stage-and-package.yaml has been copied over) + deploy the
# on-cluster app Quay
ansible-playbook mirror-refresh.yaml -i ../inventory/inventory.yaml

# Export app S3 data out of the bastion (periodic/on-demand — there's no always-on
# path from the cluster to the internet)
ansible-playbook export-backup.yaml -i ../inventory/inventory.yaml
```
