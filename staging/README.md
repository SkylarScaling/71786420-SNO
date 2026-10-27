# staging/

Runs directly on the internet-connected staging host (`hosts: localhost` everywhere
in this tree). Produces the one artifact the bastion needs: mirrored release/operator
content, the install-time binaries, the entire `bastion/` tree, and resolved
per-environment config, all packaged into a single `tar.gz`.

## Credentials

Secrets (`pull_secret`, `ssh_key`) are read from files via `lookup('file', ...)` in
`inventory/inventory.yaml` — never commit them. BMC, SMTP, and external-backup
credentials are also per-environment and live there — for a real deployment, move
the actual secret values into `ansible-vault` rather than committing them in plain
text.

## Variable reference

**`inventory/inventory.yaml` is the single source of per-environment config for both
staging and the bastion** — edit it here only. `playbooks/group_vars/all.yaml` holds
only generic, non-secret defaults; never add per-environment defaults back there —
Ansible's precedence puts `group_vars/all` above inline inventory-file vars, so a
default set there would silently win over the real inventory override.

| Variable | Used by | Notes |
|---|---|---|
| `cluster_name`, `base_domain`, `openshift_version`, `infra_provider` | both trees | cluster identity |
| `pull_secret`, `ssh_key`, `ssh_private_key` | both trees | read from local files on staging; shipped to the bastion in the resolved-vars bundle |
| `sno_kubeconfig`, `tmp_dir`, `install_dir` | bastion-side `roles/ocp/*` | always `{{ install_dir }}/auth/kubeconfig`; only meaningful once unpacked on the bastion |
| `machine_network_cidr`, `cluster_network_cidr`, `service_network_cidr` | bastion's `generate_install_config` | |
| `mirror_registry_quay_hostname`, `mirror_registry_quay_port` | bastion's `deploy_mirror_registry`/`generate_install_config` | the bastion's mirror registry, always used — no connected fallback |
| `oc_mirror_operator_packages` | `stage_mirror_content` | list of package names, or `{name, channel}` dicts to pin a non-default channel |
| `bastion_transfer_method`, `bastion_transfer_host`/`_user`/`_ssh_key`/`_dest_dir` | `package_bastion_bundle` | `media` (default, physical transfer) or `rsync` (opt-in network push) |
| `bmc_address`, `bmc_username`, `bmc_password`, `iso_http_url` | bastion's `baremetal_boot_node_via_bmc`/`configure_bastion_services` | required to un-stub that role |
| `rendezvous_ip`, `sno_mac_address`, `dns_server`, `default_gateway`, `ntp_server` | bastion's `roles/baremetal/*` | set once per deployment |
| `sno_network_topology`, `sno_interface_name_secondary`, `sno_mac_address_secondary` | bastion's `baremetal_generate_agent_iso` | `single_switch` (default) or `dual_switch` opt-in NIC bonding on the SNO node |
| `lvms_device_paths` | bastion's `configure_lvms` | the RAID5 virtual disk's device path |
| `metallb_address_pool` | bastion's `configure_metallb` | customer-provided range; non-HTTP TCP middleware only, not app HTTP ingress |
| `alert_smtp_host`, `alert_email_to` | bastion's `configure_alerting` | assumes direct network reachability to the customer's SMTP server |
| `backup_s3_bucket` | bastion's `configure_oadp_backup` | bucket name on the in-cluster NooBaa — the only backend this role supports |
| `backup_egress_mode` | bastion's `configure_mcg_backup_export`/`export-backup.yaml` | `network` \| `media` \| `both` — how app S3 data replicates out of a disconnected environment |
| `backup_external_s3_endpoint/bucket/access_key/secret_key` | bastion's `export-backup.yaml`, staging's `push_backup_to_external_s3` | real external S3 target |
| `log_forward_endpoint` | bastion's `configure_log_forwarding` | external SIEM endpoint — placeholder, not production-ready (see that role's README) |

See `bastion/README.md` for bastion-only variables (e.g. upgrade/node-failure-drill
vars) that don't need to flow through the resolved-vars bundle because they're only
ever passed as one-off `-e` overrides at run time on the bastion.

## Common commands

```bash
cd staging/playbooks

# Stage content and package the bastion bundle
ansible-playbook full-staging-setup.yaml -i ../inventory/inventory.yaml

# Equivalent, explicit two-step form
ansible-playbook stage-and-package.yaml -i ../inventory/inventory.yaml

# Receive a backup bundle from the bastion and push it to external S3
# (only after bastion/playbooks/export-backup.yaml has produced one and it's been
# physically copied or rsynced here)
ansible-playbook receive-backup.yaml -i ../inventory/inventory.yaml
```

After `full-staging-setup.yaml`/`stage-and-package.yaml` completes, physically copy
(or rsync, if `bastion_transfer_method: rsync`) the resulting
`sno-bastion-bundle-<cluster_name>.tar.gz` to the bastion, extract it into an empty
working directory there, and continue with `bastion/README.md`.
