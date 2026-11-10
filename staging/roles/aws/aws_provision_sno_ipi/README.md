# aws_provision_sno_ipi

Runs on `staging` (`hosts: localhost`) — `openshift-install create cluster` needs
real internet access to reach Route53 and IAM/ccoctl (see
`aws_configure_manual_credentials`/`aws_configure_manual_dns` for why), which only
`staging` has in this split. `bastion` generates `install-config.yaml` itself
(colocated with `deploy_mirror_registry`'s facts) and hands it back to `staging` via
`bastion/roles/common/package_install_config_bundle` →
`staging/roles/common/unpack_install_config_bundle`, which must run before this role.

Unlike `main`'s original version of this role, this one does **not**
`include_role: generate_install_config` itself — that already happened on `bastion`.
Its self-heal block (destroy-and-retry on a stale `metadata.json`) also only clears
leftover state, not the freshly-unpacked `install-config.yaml`, since nothing in this
role regenerates it.

After a successful `create cluster`, `staging/playbooks/provision-sno-aws.yaml` runs
`wait_for_sno_install` (shared, provider-agnostic) and then
`package_kubeconfig_bundle` to hand `sno_kubeconfig` back to the bastion, so the
shared `roles/ocp/*` day-2 roles can run there unchanged.

## The rescue block's second `wait-for install-complete` may need more than one try

`openshift-install wait-for install-complete` has no `--timeout` flag (only
`-h`/`--log-level`) — its internal budget is a fixed 40m. Confirmed live: right after
this rescue path runs (apps DNS record created, credentials reapplied —
`aws_configure_manual_dns`/`aws_configure_manual_credentials`'s `reapply_credentials.yml`),
`image-registry` transiently failed its own reconcile with
`WebIdentityErr: ... InvalidIdentityToken` against the just-reapplied STS
credentials — not a real OIDC/IAM misconfiguration, just the operator needing a
couple more reconcile cycles than one 40m window allows immediately after a
mid-install credentials/DNS fixup. It converged on its own about 8 minutes after that
first window ran out, with no further intervention. The "Resume waiting..." task
retries the command itself (up to 2 extra times) rather than trying to lengthen a
single wait, since each invocation independently re-polls live cluster state from
scratch and returns immediately once everything's actually converged — a retry costs
nothing extra if the first window was already enough.

## Known gap

Verified against a real AWS run (through to a fully `Available` clusterversion with
every cluster operator `Available`/non-`Degraded`) as of this restructuring, including
the DNS/credentials rescue path above.
