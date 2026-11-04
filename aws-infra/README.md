# aws-infra/

Provisions the two EC2 hosts that become the `staging/` and `bastion/` trees'
machines for the AWS test loop. Bare metal has no equivalent of this tree — the
physical staging/bastion hosts already exist on the customer's network, so there's
nothing to provision there.

This tree only creates infrastructure. It does not run any `staging/`/`bastion/`
automation against the new hosts, and it does not add them to any in-memory Ansible
inventory — once the hosts exist, the operator reaches them over plain SSH and runs
`staging/`/`bastion/` locally there, exactly like a real bare-metal deployment (see
"Getting the repo onto the two EC2 hosts" in `docs/aws-test-environment-architecture.md`
§4, and `staging/README.md`'s "First-time setup on a blank staging host").

## One-time setup

```bash
cd aws-infra/playbooks
ansible-playbook configure-aws-env.yaml
```

Prompts for `aws_base_domain`/AWS credentials/region; imports your SSH public key as
an EC2 key pair; writes `~/tmp/<base_domain>-creds`; and renders
`aws-infra/inventory/inventory.yaml`. It does **not** render
`staging/inventory/inventory.yaml` — that needs VPC/subnet facts that don't exist yet
at this point; `provision-hosts.yaml` renders and delivers it instead, once those
facts exist (see below).

`automation_repo_url`/`automation_repo_ref` (this repo's own git location and branch
— constant across environments, not something this playbook prompts for) are set in
`playbooks/group_vars/all.yaml`. Update the placeholder URL there once, for real.

## Provision / destroy

```bash
# Create the VPC + both EC2 instances. Also renders staging/inventory/inventory.yaml
# (now that VPC/subnet facts exist) and scp's it, the AWS credentials file,
# staging/bootstrap-staging-host.sh, your local ~/.ssh/id_ed25519(.pub), and
# ~/pull-secret.json to the mirror-staging host's $HOME — prints the exact next
# command to run there. (Those last three are needed because
# staging/inventory/inventory.yaml's lookup('file', ...) calls for ssh_key/
# pull_secret/ssh_private_key are evaluated wherever staging/ actually runs, not
# wherever this inventory was authored.)
ansible-playbook provision-hosts.yaml -i ../inventory/inventory.yaml

# Tear down. Run staging/playbooks/destroy-sno-aws.yaml FIRST — this only removes
# infrastructure, not the cluster itself (see aws_destroy_infra's README)
ansible-playbook destroy-hosts.yaml -i ../inventory/inventory.yaml
```

## Known gaps

Unverified against a real AWS run since this restructuring split the old
single-controller `roles/aws/*` implementation into `aws-infra/` + `staging/roles/aws/`
+ the install-config/kubeconfig handback roles in `staging/roles/common/` and
`bastion/roles/common/` — flagged the same way other untested pieces in this repo are
flagged (see e.g. `bastion/roles/baremetal/baremetal_boot_node_via_bmc`'s README).
