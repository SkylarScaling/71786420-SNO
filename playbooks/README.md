# Playbooks

## Credentials

Secrets (`pull_secret`, `ssh_key`) are read from files via `lookup('file', ...)` in
`group_vars/all.yaml` — never commit them. BMC, SMTP, and external-backup credentials
are per-environment and live in `inventory/baremetal/inventory.yaml`'s `vars:` block —
for a real deployment, move the actual secret values into `ansible-vault` rather than
committing them in plain text.

## Variable reference

Shared defaults live in `group_vars/all.yaml`; per-environment values (`base_domain`,
BMC details, etc.) live in `inventory/baremetal/inventory.yaml`'s `vars:` block —
never add defaults for those back into `group_vars/all.yaml` (see CLAUDE.md for why).

| Variable | Used by | Notes |
|---|---|---|
| `cluster_name`, `base_domain`, `openshift_version` | all | cluster identity |
| `sno_kubeconfig` | `roles/ocp/*` | always `{{ install_dir }}/auth/kubeconfig` |
| `machine_network_cidr`, `cluster_network_cidr`, `service_network_cidr` | `generate_install_config` | |
| `mirror_registry_quay_hostname`, `mirror_registry_quay_port` | `deploy_mirror_registry`, `generate_install_config` | the bastion's mirror registry, always used — no connected fallback |
| `mirror_sync_method` | `sync_mirror_to_bastion` | `rsync` (default, needs a network path) or `media` (manual transfer) |
| `bastion_host` | roles that `delegate_to` the bastion | static `inventory_hostname` |
| `rendezvous_ip`, `sno_mac_address`, `dns_server`, `default_gateway` | `roles/baremetal/*` | set once per deployment |
| `sno_network_topology`, `sno_interface_name_secondary`, `sno_mac_address_secondary` | `baremetal_generate_agent_iso` | `single_switch` (default) or `dual_switch` opt-in NIC bonding on the SNO node |
| `bmc_address`, `bmc_username`, `bmc_password` | `baremetal_boot_node_via_bmc` | required to un-stub that role |
| `backup_s3_bucket` | `configure_oadp_backup` | bucket name on the in-cluster NooBaa (`configure_mcg`) — the only backend this role supports |
| `backup_egress_mode` | `configure_mcg_backup_export` | `network` \| `media` \| `both` — how app S3 data replicates out of a disconnected environment |
| `backup_external_s3_endpoint/bucket/access_key/secret_key` | `configure_mcg_backup_export` | real external S3 target; per-environment, set in inventory |
| `mcg_backing_pvc_size`, `mcg_backing_storage_class` | `configure_mcg` | standalone MCG (no CephCluster) backed by an LVMS PVC — true-SNO S3, RAID5 is the redundancy layer |
| `lvms_device_paths` | `configure_lvms` | the RAID5 virtual disk's device path |
| `lvms_retain_storage_class_name` | `configure_lvms`, `configure_postgres` | Retain-policy StorageClass, same device class as `vg1` — used by Postgres only |
| `lokistack_size`, `loki_retention_days`, `loki_hot_retention_days` | `configure_lokistack` | S3-backed via `configure_mcg` |
| `metallb_address_pool` | `configure_metallb` | customer-provided range; non-HTTP TCP middleware only, not app HTTP ingress |
| `alert_smtp_host`, `alert_smtp_port`, `alert_email_from`, `alert_email_to` | `configure_alerting` | assumes direct network reachability to the customer's SMTP server |
| `ntp_server` | `generate_install_config` | customer-provided NTP server, added to `additionalNTPSources` |
| `*_expose_external` (`rabbitmq_expose_external`, `redis_expose_external`, ...) | `configure_rabbitmq`/`configure_postgres`/`configure_redis` | opt-in `type: LoadBalancer` via `configure_metallb` |
| `oc_mirror_operator_packages` | `stage_mirror_content` | list of package names, or `{name, channel}` dicts to pin a non-default channel |
| `log_forward_endpoint` | `configure_log_forwarding` | external SIEM endpoint — placeholder, not production-ready (see role README) |
| `sno_upgrade_channel`, `sno_upgrade_target_version`, `sno_upgrade_ack_key`, `sno_upgrade_prune_images` | `sno_upgrade` | set per upgrade run |
| `sno_node_name`, `simulate_node_failure_confirm` | `simulate_node_failure` | destructive drill guard |

## Common commands

```bash
# Full production rollout (provision + storage + MetalLB + logging + tracing +
# alerting + backup + Day 2 middleware)
ansible-playbook full-baremetal-production-setup.yaml -i ../inventory/baremetal/inventory.yaml

# Just provision (always disconnected: mirrors content, generates the agent ISO,
# boots the node via BMC, then installs)
ansible-playbook provision-sno-baremetal.yaml -i ../inventory/baremetal/inventory.yaml

# Upgrade drill
ansible-playbook upgrade-sno.yaml -i ../inventory/baremetal/inventory.yaml \
  -e sno_upgrade_channel=stable-4.19 -e sno_upgrade_target_version=4.19.4

# Node failure/recovery drill (destructive — single node)
ansible-playbook simulate-node-failure.yaml -i ../inventory/baremetal/inventory.yaml \
  -e simulate_node_failure_confirm=true -e sno_node_name=<node>

# Tear down
ansible-playbook destroy-sno-baremetal.yaml -i ../inventory/baremetal/inventory.yaml

# Refresh mirrored content on an existing bastion + deploy the on-cluster app Quay
# (the initial mirror already happened during provision-sno-baremetal.yaml)
ansible-playbook mirror-content.yaml -i ../inventory/baremetal/inventory.yaml

# Relay app S3 data out to the external backup target (periodic/on-demand — there's no
# always-on path from the cluster to the internet, see CLAUDE.md)
ansible-playbook export-backup.yaml -i ../inventory/baremetal/inventory.yaml
```
