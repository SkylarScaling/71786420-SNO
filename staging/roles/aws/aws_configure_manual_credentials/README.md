# aws_configure_manual_credentials

Runs on the controller (localhost), between `generate_install_config` and
`openshift-install create cluster` in `aws_provision_sno_ipi`. Switches the cluster's
cloud credentials from the default "Mint" mode (cloud-credential-operator creates IAM
users at runtime, from inside the cluster) to "Manual" mode with ccoctl-issued
STS/OIDC roles — `generate_install_config` sets `credentialsMode: Manual` in
install-config.yaml; this role does the rest.

## Why this is necessary at all

Confirmed against a real run: under the default Mint mode, every single
CredentialsRequest failed identically — `cloud-credential-operator`, running on the
SNO node itself, tried to call `iam.amazonaws.com` directly and timed out
(`dial tcp ...:443: i/o timeout`). The node has no internet route by design (see
CLAUDE.md's "always fully disconnected"), and **IAM has no VPC endpoint at all** —
unlike EC2/S3/ELB/STS, which `roles/aws/aws_provision_network` already provisions
interface/gateway endpoints for. Mint mode is fundamentally incompatible with a
disconnected node; it isn't a timeout/retry-tuning problem.

Manual mode avoids this entirely: cloud-credential-operator never calls IAM at
runtime — it just reads a pre-provisioned Secret (role ARN + a path to the
service-account's own web-identity token) and hands it to the component that
requested it. The actual credential exchange happens via `AssumeRoleWithWebIdentity`
against **STS**, which does have a VPC endpoint already (`aws_provision_network`'s
`vpc_interface_endpoint_services` already includes `sts` — apparently anticipating
exactly this need before this role existed). This resolves every CredentialsRequest
whose underlying AWS API has a VPC endpoint: EBS CSI driver, machine-api,
image-registry, cloud-network-config-controller (all EC2/S3/ELB under the hood).

**It does not resolve the ingress-operator's DNS management failure** — that's a
separate problem with a separate fix, in `staging/roles/aws/aws_configure_manual_dns`. Route53
itself has no VPC endpoint at all (same category as IAM: a global control-plane API,
not reachable via PrivateLink), so even with valid STS-issued credentials, the
ingress-operator still cannot reach `route53.amazonaws.com` to write the `*.apps`
wildcard record from inside the cluster. Credentials and network reachability are two
independent problems here; Manual mode only solves the first.

## What this role actually does

1. Extracts `ccoctl` from this release's own `cloud-credential-operator` image
   (`oc adm release info --image-for=cloud-credential-operator` then
   `oc image extract`) — version-matched to `openshift_version` the same
   existence-OR-version-mismatch way `install_ocp_prerequisites` guards
   `openshift-install`/`oc` against staleness, since ccoctl is versioned per-release
   too.
2. `oc adm release extract --credentials-requests --cloud=aws` to get the exact list
   of CredentialsRequests this release actually ships (not a hardcoded list, which
   would drift across OCP versions).
3. `ccoctl aws create-all` — creates a public S3 bucket serving the OIDC discovery
   documents (this is fetched by AWS STS's own backend when validating tokens, not by
   anything inside our VPC, so it doesn't need to be internet-reachable from the node;
   it needs to be internet-reachable *to AWS itself*, which is unrelated to our node's
   routing) plus one IAM role per CredentialsRequest, trusting that OIDC provider.
4. Copies the generated credential Secret manifests into `{{ install_dir }}/manifests/`
   (openshift-install picks up any manifests already present there before generating
   its own — no special flag needed) and the generated
   `bound-service-account-signing-key.key` into `{{ install_dir }}/tls/` (required so
   in-cluster service-account tokens are signed with the exact key the OIDC provider
   trusts — a different, more specific path than the manifests convention above, easy
   to miss).

## Reentrancy across retries

`ccoctl_name` is a deterministic hash of `cluster_name` + `base_domain`, not randomly
generated per run — `ccoctl aws create-all` is documented as safe to re-run under the
same `--name` (it detects and reuses existing resources rather than erroring or
duplicating), so a retried install after a prior failed attempt reuses the same OIDC
provider/IAM roles instead of leaking a new set every time.
`staging/roles/aws/aws_destroy_cluster` recomputes the same hash to find what to delete — a true
teardown runs `ccoctl aws delete`, since `openshift-install destroy cluster` has no
knowledge of resources ccoctl created outside its own tracked infrastructure.
