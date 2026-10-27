# Playbooks

## Credentials

AWS credentials are per-environment Ansible variables, not `~/.aws/credentials` or
`AWS_PROFILE` — deliberately, so multiple AWS test environments can run in parallel
without sharing global credential state. Each environment gets its own generated
inventory file, `inventory/aws/<base_domain>.yaml`, which derives
`aws_access_key_id`/`aws_secret_access_key`/`aws_region` from a local JSON file at
`~/tmp/<base_domain>-creds` — the same `lookup('file', ...)` pattern used for
`pull_secret`/`ssh_key`.

Since those credentials and `base_domain` change every time a new AWS test
environment is spun up (new sandbox account, new assigned domain), run
`configure-aws-env.yaml` first — it interactively prompts for both, imports `ssh_key`
(`group_vars/all.yaml`) as a new EC2 key pair named `<base_domain>-keypair` so you
never have to find or create one yourself, and writes the per-environment credentials
file and inventory file for you:

```bash
ansible-playbook configure-aws-env.yaml
# -> imports ssh_key as EC2 key pair <base_domain>-keypair
# -> ~/tmp/<base_domain>-creds
# -> inventory/aws/<base_domain>.yaml
```

Run it again with a different `base_domain` to set up another environment — each gets
its own credentials file and inventory file, so they can be provisioned concurrently
without colliding. Use `-i inventory/aws/<base_domain>.yaml` for every other playbook
against that environment.

One remaining shared-state caveat: `cluster_name` and `tmp_dir`/`install_dir` (in
`group_vars/all.yaml`) default to the same value for every environment. If you're
actually running two AWS provisions at once on the same workstation, pass
`-e cluster_name=<unique-name>` per environment too, or their local working
directories (and `openshift-install`'s state) will collide.

## Variable reference

Shared defaults live in `group_vars/all.yaml`; per-environment values (`base_domain`,
AWS credentials/region) live only in the generated `inventory/aws/<base_domain>.yaml`
— never add defaults for those back into `group_vars/all.yaml` (see CLAUDE.md for why).
Secrets (`pull_secret`, `ssh_key`) are read from files via `lookup('file', ...)` —
never commit them.

| Variable | Used by | Notes |
|---|---|---|
| `cluster_name`, `base_domain`, `openshift_version` | all | cluster identity |
| `infra_provider` | `roles/common/generate_install_config` and other shared roles | `aws` or `baremetal`, set per-inventory — which `provision-sno-*.yaml`/`destroy-sno-*.yaml` you run is what actually selects the provider now, not this var (see CLAUDE.md) |
| `sno_kubeconfig` | `roles/ocp/*` | always `{{ install_dir }}/auth/kubeconfig` |
| `machine_network_cidr`, `cluster_network_cidr`, `service_network_cidr` | `generate_install_config` | identical across providers |
| `aws_access_key_id`, `aws_secret_access_key`, `aws_region` | `roles/aws/*` (via `module_defaults: group/aws`) | AWS only; generated per-environment, see Credentials above |
| `aws_key_pair` | `aws_provision_mirror_staging_host`, `aws_provision_bastion` | AWS only; `<base_domain>-keypair`, imported from `ssh_key` by `configure-aws-env.yaml` |
| `aws_sno_instance_type`, `bastion_instance_type` | `roles/aws/*` | AWS only |
| `vpc_cidr`, `public_subnet_cidr` | `aws_provision_network` | AWS only; `private_subnet_cidr` defaults to `machine_network_cidr` |
| `mirror_registry_quay_hostname`, `mirror_registry_quay_port` | `deploy_mirror_registry`, `generate_install_config` | the bastion's mirror registry, always used — no connected fallback |
| `mirror_sync_method` | `sync_mirror_to_bastion` | `rsync` (default, needs a network path) or `media` (manual transfer) |
| `bastion_host` | roles that `delegate_to` the bastion | static inventory_hostname on bare metal; set dynamically by `aws_provision_bastion` on AWS |
| `rendezvous_ip`, `sno_mac_address`, `dns_server`, `default_gateway` | `roles/baremetal/*` | bare metal only, set once per deployment |
| `bmc_address`, `bmc_username`, `bmc_password` | `baremetal_boot_node_via_bmc` | bare metal only, required to un-stub that role |
| `backup_s3_bucket` | `configure_oadp_backup` | bucket name on the in-cluster NooBaa (`configure_mcg`) — the only backend this role supports, on both providers |
| `backup_egress_mode` | `configure_mcg_backup_export` | `network` \| `media` \| `both` — how app S3 data replicates out of a disconnected environment |
| `backup_external_s3_endpoint/bucket/access_key/secret_key` | `configure_mcg_backup_export` | real external S3 target; per-environment, set in inventory |
| `mcg_backing_pvc_size`, `mcg_backing_storage_class` | `configure_mcg` | standalone MCG (no CephCluster) backed by an LVMS PVC — true-SNO S3, RAID5 is the redundancy layer |
| `lvms_device_paths` | `configure_lvms` | bare metal: the RAID5 virtual disk's device path |
| `lokistack_size`, `loki_retention_days`, `loki_hot_retention_days` | `configure_lokistack` | S3-backed via `configure_mcg` |
| `metallb_address_pool` | `configure_metallb` | customer-provided range; non-HTTP TCP middleware only, not app HTTP ingress |
| `alert_smtp_host`, `alert_smtp_port`, `alert_email_from`, `alert_email_to` | `configure_alerting` | assumes direct network reachability to the customer's SMTP server |
| `ntp_server` | `generate_install_config` | bare metal only; customer-provided NTP server, added to `additionalNTPSources` |
| `*_expose_external` (`rabbitmq_expose_external`, `redis_expose_external`, ...) | `configure_rabbitmq`/`configure_postgres`/`configure_redis` | opt-in `type: LoadBalancer` via `configure_metallb` |
| `oc_mirror_operator_packages` | `stage_mirror_content` | list of package names, or `{name, channel}` dicts to pin a non-default channel |
| `log_forward_endpoint` | `configure_log_forwarding` | external SIEM endpoint (runs alongside the LokiStack output) |
| `sno_upgrade_channel`, `sno_upgrade_target_version`, `sno_upgrade_ack_key` | `sno_upgrade` | set per upgrade run |
| `sno_node_name`, `simulate_node_failure_confirm` | `simulate_node_failure` | destructive drill guard |

## Common commands

```bash
# Set up (or add) an AWS test environment first
ansible-playbook configure-aws-env.yaml

# Full AWS test environment: prereqs + provision (network, mirror, bastion, SNO) + storage + backup + logging
ansible-playbook full-sno-test-setup.yaml -i ../inventory/aws/<base_domain>.yaml

# Just provision (always disconnected: builds the isolated VPC, mirrors content, then installs)
ansible-playbook provision-sno-aws.yaml -i ../inventory/aws/<base_domain>.yaml

# Upgrade drill
ansible-playbook upgrade-sno.yaml -i ../inventory/aws/<base_domain>.yaml \
  -e sno_upgrade_channel=stable-4.19 -e sno_upgrade_target_version=4.19.4

# Node failure/recovery drill (destructive — single node)
ansible-playbook simulate-node-failure.yaml -i ../inventory/aws/<base_domain>.yaml \
  -e simulate_node_failure_confirm=true -e sno_node_name=<node>

# Tear down
ansible-playbook destroy-sno-aws.yaml -i ../inventory/aws/<base_domain>.yaml

# Full bare-metal rollout (storage + MetalLB + logging + tracing + alerting + backup
# + Day 2 middleware)
ansible-playbook full-baremetal-production-setup.yaml -i ../inventory/baremetal/inventory.yaml

# Just provision on bare metal (same role sequence as provision-sno-aws.yaml, against
# the agent-based/BMC path instead)
ansible-playbook provision-sno-baremetal.yaml -i ../inventory/baremetal/inventory.yaml

# Tear down bare metal
ansible-playbook destroy-sno-baremetal.yaml -i ../inventory/baremetal/inventory.yaml

# Refresh mirrored content on an existing bastion + deploy the on-cluster app Quay
# (the initial mirror already happened during provision-sno-{aws,baremetal}.yaml)
ansible-playbook mirror-content.yaml -i ../inventory/baremetal/inventory.yaml

# Relay app S3 data out to the external backup target (periodic/on-demand — there's no
# always-on path from the cluster to the internet on either provider, see CLAUDE.md)
ansible-playbook export-backup.yaml -i ../inventory/baremetal/inventory.yaml
```

Swap `-i ../inventory/aws/<base_domain>.yaml` for `-i ../inventory/baremetal/inventory.yaml`
once bare-metal hardware is available — the `configure-*.yaml` and `upgrade-sno.yaml`
playbooks need no changes; only provisioning/destroy use the provider-specific
`provision-sno-{aws,baremetal}.yaml`/`destroy-sno-{aws,baremetal}.yaml` entry points.
