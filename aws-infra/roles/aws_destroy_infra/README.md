# aws_destroy_infra

Terminates the two EC2 instances `aws_provision_mirror_staging_host`/
`aws_provision_bastion` created and tears down the VPC `aws_provision_network`
built (endpoints → IGW → route tables → subnets → security groups → the private
Route53 zone/record → the VPC itself, in dependency order).

**Run `staging/playbooks/destroy-sno-aws.yaml` (which runs
`staging/roles/aws/aws_destroy_cluster`) first.** This role only tears down
infrastructure — it has no knowledge of the cluster itself. Terminating the
instances/VPC out from under a still-registered cluster just leaks its AWS-side
state (ccoctl-created IAM roles/OIDC bucket, the public-zone apps CNAME) instead of
cleaning it up; `aws_destroy_cluster` is what removes those.
