# aws_destroy_cluster

Cluster-level teardown — renamed/trimmed from `main`'s `aws_destroy_sno`, which also
tore down the EC2 instances/VPC/Route53 zone. That infrastructure-level portion moved
to `aws-infra/roles/aws_destroy_infra`, since this split's `staging/` tree has no
business terminating the EC2 instance it's running on. Run this role first (via
`staging/playbooks/destroy-sno-aws.yaml`), then `aws-infra/playbooks/destroy-hosts.yaml`
— see `aws_destroy_infra`'s README for why the order matters.

Removes the two resource types `openshift-install destroy cluster` doesn't know about
because they were created outside its own CAPI-tracked bookkeeping:

- **ccoctl-created OIDC S3 bucket + IAM roles** (`aws_configure_manual_credentials`,
  run during `create cluster` to work around Mint-mode CCO's IAM reachability
  problem — see that role's README). Cleaned up via `ccoctl aws delete
  --name=<ccoctl_name> --region=<aws_region>`, recomputing `ccoctl_name` with the
  exact same deterministic hash formula as that role's `defaults/main.yaml` (role
  defaults aren't shared across roles, so this must stay in sync by hand if that
  formula ever changes).
- **The apps wildcard CNAME in the public Route53 zone** (`aws_configure_manual_dns`'s
  `create_apps_record.yml`, run from `aws_provision_sno_ipi`'s `rescue:` block). The
  private zone's own copy of this record is removed for free when `destroy cluster`
  deletes that zone, but the public zone's copy is not tracked by the installer at all
  and would otherwise leak permanently across every destroy/recreate cycle.

Both cleanups run with `ignore_errors: true` — the cluster may never have reached the
point where either resource was created (e.g. it failed before
`aws_configure_manual_credentials`/`aws_configure_manual_dns` ran), and
`aws_provision_sno_ipi` also reuses this same logic inline as its own self-heal path
for a prior partial attempt.
