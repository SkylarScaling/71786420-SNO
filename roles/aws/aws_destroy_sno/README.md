# aws_destroy_sno

Tears down everything the AWS test loop creates, including the two resource types that
`openshift-install destroy cluster` doesn't know about because they were created
outside its own CAPI-tracked bookkeeping:

- **ccoctl-created OIDC S3 bucket + IAM roles** (`roles/aws/
  aws_configure_manual_credentials`, run during `create cluster` to work around
  Mint-mode CCO's IAM reachability problem — see that role's README). Cleaned up via
  `ccoctl aws delete --name=<ccoctl_name> --region=<aws_region>`, recomputing
  `ccoctl_name` with the exact same deterministic hash formula as that role's
  `defaults/main.yaml` (role defaults aren't shared across roles, so this must stay in
  sync by hand if that formula ever changes).
- **The apps wildcard CNAME in the public Route53 zone** (`roles/aws/
  aws_configure_manual_dns`'s `create_apps_record.yml`, run from `aws_provision_sno_ipi`'s
  `rescue:` block). The private zone's own copy of this record is removed for free when
  `destroy cluster` deletes that zone below, but the public zone's copy is not tracked
  by the installer at all and would otherwise leak permanently across every
  destroy/recreate cycle.

Both cleanups run with `ignore_errors: true` — the cluster may never have reached the
point where either resource was created (e.g. it failed before
`aws_configure_manual_credentials`/`aws_configure_manual_dns` ran), and this role is
also used as the self-heal path in `aws_provision_sno_ipi` for a prior partial attempt.

Everything after that is unchanged: `openshift-install destroy cluster`, then
EC2/VPC-internals teardown in dependency order (endpoints → IGW → route tables →
subnets → security groups → the `mirror.{{ base_domain }}` record → the private
`base_domain` hosted zone → the VPC itself).
