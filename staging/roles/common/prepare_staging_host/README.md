# prepare_staging_host

Finishes what `../../../bootstrap-staging-host.sh` deliberately leaves undone. That
script does the minimum possible in bash — just enough to get Ansible itself running
on a brand-new staging host (bare-metal or AWS EC2): installs `python3`/`python3-pip`/
`git` via the system package manager, clones this repo, and runs
`pip install -r requirements.txt` (which installs `ansible` itself, among this repo's
other Python deps — unavoidable in bash, since Ansible doesn't exist on the host
until that line runs). Everything else happens here, in Ansible, per this repo's
"as much as possible in Ansible" convention.

## What this role does

- `ansible-galaxy collection install -r requirements.yml` — the Galaxy collections
  (`kubernetes.core`, `amazon.aws`, `community.general`, `ansible.posix`) this repo's
  roles depend on. Couldn't run from the bootstrap script since `ansible-galaxy`
  doesn't exist until `pip install -r requirements.txt` has already run.
- Installs `rsync`/`tar`/`gzip` via the system package manager — used by
  `package_bastion_bundle`/`package_kubeconfig_bundle`/`package_install_config_bundle`'s
  `rsync`/`archive` tasks.

## Usage

Run `staging/playbooks/prepare-staging-host.yaml` once, right after
`bootstrap-staging-host.sh` completes — before any other `staging/` playbook.

## Why this isn't folded into `stage-and-package.yaml`

Keeping it a separate, explicit first step avoids any ordering ambiguity: every
other `staging/` playbook's `include_role` calls reference modules from the
collections this role installs (`kubernetes.core.k8s_info` via `aws_configure_manual_dns`,
`amazon.aws.*` via `roles/aws/*`), so those collections must already be present
before Ansible even parses those playbooks, not just before the relevant task runs.
