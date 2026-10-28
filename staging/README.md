# staging/

Runs directly on the internet-connected staging host (`hosts: localhost` everywhere
in this tree). Produces the one artifact the bastion needs: mirrored release/operator
content, the install-time binaries, the entire `bastion/` tree, and resolved
per-environment config, all packaged into a single `tar.gz`.

## First-time setup on a blank staging host

A freshly provisioned staging host (a real bare-metal machine with nothing installed
yet, or a freshly created AWS EC2 instance) has no Ansible, Python, or copy of this
repo on it. `bootstrap-staging-host.sh` does the minimum possible in plain bash to
fix that — install `python3`/`python3-pip`/`git`, clone this repo, and
`pip install -r requirements.txt` (which installs Ansible itself, among this repo's
other Python deps; unavoidable in bash, since nothing past that point can be an
Ansible task until Ansible exists) — then hands off to Ansible for everything else:

```bash
./bootstrap-staging-host.sh <git-repo-url> [branch] [clone-dir]
# then, in this same shell session:
export PATH="$HOME/.local/bin:$PATH"
cd <clone-dir>/staging/playbooks
ansible-playbook prepare-staging-host.yaml -i ../inventory/inventory.yaml
```

The `export` is only needed for this first session — the script also appends it to
`~/.bashrc`, so every subsequent login to this host already has `~/.local/bin` (where
the `--user` pip install above put `ansible`) on `PATH` with no manual step. It can't
apply that to the *current* shell itself: a script can't export into the shell that
invoked it, only into files that take effect on the next one.

On AWS, `aws-infra/playbooks/provision-hosts.yaml` already copies this script (plus a
fully-rendered `inventory.yaml` and the AWS credentials file) to the staging host's
`$HOME` as part of provisioning — see its printed summary for the exact command to
run, and `docs/aws-test-environment-architecture.md` §4. On bare metal, copy the
script over yourself (it has no other dependencies) and supply your own repo URL.

If `automation_repo_url` is an SSH URL (the default — see
`aws-infra/playbooks/group_vars/all.yaml`), the host doing the clone needs an SSH key
GitHub trusts. Don't copy your personal key onto the staging host for this — SSH in
with agent forwarding instead (`ssh -A ...`, already how `provision-hosts.yaml`'s
printed connection command connects to the AWS staging host) so the clone
authenticates as you without any key ever touching the host. Run `ssh-add -l`
locally first to confirm a key is loaded in your agent.

On AWS only, this tree also gains `roles/aws/*` and runs `openshift-install create
cluster` itself, using an install-config the bastion generates and hands back (see
`docs/aws-test-environment-architecture.md` §3 for why cluster creation can't happen
on the bastion for AWS). `inventory/inventory-baremetal.yaml` and `inventory/
inventory-aws.yaml.j2` are the two committed sources of truth for
`inventory/inventory.yaml` (per-environment, gitignored) — copy/symlink the former
for bare metal, or let `aws-infra/playbooks/provision-hosts.yaml` render and deliver
the latter for AWS (it needs VPC/subnet facts that don't exist until the VPC is
created, so it's rendered there rather than by `configure-aws-env.yaml`).

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
| `aws_region`, `sno_vpc_id`, `sno_vpc_cidr`, `sno_private_subnet_id`, `sno_public_subnet_id`, `sno_public_subnet_cidr` | AWS only — bastion's `generate_install_config`, `roles/aws/*` | produced by `aws-infra/playbooks/provision-hosts.yaml` and rendered directly into this file (then copied to the mirror-staging host) — no manual copying of values required |
| `aws_access_key_id`, `aws_secret_access_key` | AWS only — every `roles/aws/*` task (`module_defaults: group/aws:`) | sourced from `~/tmp/<base_domain>-creds`, written by `aws-infra/playbooks/configure-aws-env.yaml` — not `~/.aws/credentials`/`AWS_PROFILE` |
| `aws_sno_instance_type` | AWS only — bastion's `generate_install_config` | sized to emulate the target bare-metal server; defaults in that role, not here |

See `bastion/README.md` for bastion-only variables (e.g. upgrade/node-failure-drill
vars) that don't need to flow through the resolved-vars bundle because they're only
ever passed as one-off `-e` overrides at run time on the bastion.

## Common commands

```bash
cd staging/playbooks

# First time only, on a freshly bootstrapped staging host (see above)
ansible-playbook prepare-staging-host.yaml -i ../inventory/inventory.yaml

# Stage content and package the bastion bundle (bare metal)
ansible-playbook full-staging-setup-baremetal.yaml -i ../inventory/inventory.yaml

# Stage content and package the bastion bundle (AWS)
ansible-playbook full-staging-setup-aws.yaml -i ../inventory/inventory.yaml

# Equivalent, explicit two-step form (both providers)
ansible-playbook stage-and-package.yaml -i ../inventory/inventory.yaml

# AWS only: once the bastion has generated and handed back install-config.yaml,
# create the cluster here and hand the kubeconfig back to the bastion
ansible-playbook provision-sno-aws.yaml -i ../inventory/inventory.yaml

# AWS only: tear down the cluster (run before aws-infra/playbooks/destroy-hosts.yaml)
ansible-playbook destroy-sno-aws.yaml -i ../inventory/inventory.yaml

# Receive a backup bundle from the bastion and push it to external S3
# (only after bastion/playbooks/export-backup.yaml has produced one and it's been
# physically copied or rsynced here)
ansible-playbook receive-backup.yaml -i ../inventory/inventory.yaml
```

After `full-staging-setup-baremetal.yaml`/`full-staging-setup-aws.yaml`/
`stage-and-package.yaml` completes, physically copy (or rsync, if
`bastion_transfer_method: rsync`) the resulting
`sno-bastion-bundle-<cluster_name>.tar.gz` to the bastion, extract it into an empty
working directory there, and continue with `bastion/README.md`.
