# configure_mirror_catalog_sources

Points OLM at the bastion's mirror registry instead of the public internet, so every
`Subscription` in every other `roles/ocp/*` role can actually resolve. Runs once,
right after the cluster's kubeconfig first exists on this host — the last step of
`provision-sno-baremetal.yaml`, and of `unpack-cluster-access.yaml` on AWS — before
any feature role's `include_role` that creates a `Subscription`.

## Why this exists

`generate_install_config`'s `imageContentSources` only redirects the release image
pulls the installer/kubelet/crio need — it says nothing to OLM. Left alone, every
`Subscription` in this repo resolves against the cluster's three default
CatalogSources (`redhat-operators`/`community-operators`/`certified-operators`),
which point at `registry.redhat.io`/`registry.connect.redhat.com` out of the box.
Confirmed live: on this fully disconnected cluster, those CatalogSource pods sit in
`Init:ImagePullBackOff` forever, and every Subscription's `ResolutionFailed:
ConstraintsNotSatisfiable`/catalog-unhealthy condition never clears — meaning every
other `roles/ocp/*` role's "wait for the operator deployment" task times out with no
CSV, no Deployment, ever created, no matter how long you wait.

## What it does

`deploy_mirror_registry`'s oc-mirror v2 "disk to mirror" push already generates the
fix as plain manifests under `{{ mirror_archive_dir }}/working-dir/cluster-resources/`
— one `CatalogSource` (`cs-*.yaml`) per mirrored operator index pointing at this
bastion's own registry, `ImageDigestMirrorSet`/`ImageTagMirrorSet`
(`idms-/itms-oc-mirror.yaml`) covering every other image reference, and a
release-signature `ConfigMap`. This role:

1. Applies the IDMS/ITMS/signature-configmap manifests directly.
2. Sets `disableAllDefaultSources: true` on the cluster's `OperatorHub` config.
   Confirmed live: a plain `spec.image` patch against a default CatalogSource gets
   silently reverted within seconds — the marketplace operator continuously
   reconciles all three back to `registry.redhat.io`. This is the documented switch
   that stops it from managing (and recreating) those three objects at all.
3. Recreates `redhat-operators`/`community-operators`/`certified-operators` —
   **under the same names** — pointed at the mirrored index images oc-mirror already
   resolved (derived from each generated `cs-*.yaml`'s filename, not hardcoded).
   Every other `roles/ocp/*` role's Subscription template hardcodes `source:
   redhat-operators` etc. by name, so keeping the same names means zero changes
   needed anywhere else in this repo — the alternative (reference oc-mirror's
   generated `cs-*` names directly) would mean rewriting every one of those
   templates instead. The generated `cc-*.yaml` `ClusterCatalog` manifests are
   `olm.operatorframework.io/v1` — the newer OLM v1 ClusterExtension API, unrelated
   to the classic Subscription/CatalogSource (OLM v0) flow every role here actually
   uses — deliberately not applied.
4. Waits for the resulting MachineConfigPool rollout. IDMS/ITMS only take effect once
   `/etc/containers/registries.conf` is re-rendered on the node; without this wait,
   the Subscription tasks that immediately follow in other roles can race the
   rollout and intermittently still resolve against the stale, pre-mirror config.

## A second, related gap this doesn't cover

Several `*_channel` defaults elsewhere in this repo (`configure_lvms`'s
`lvms_channel`, `configure_mcg`'s `mcg_channel`, `configure_log_forwarding`'s
`logging_channel`, `configure_oadp_backup`'s `oadp_channel`) previously didn't match
any channel actually published by the mirrored catalog for `openshift_version` 4.22
(confirmed live via `oc get packagemanifest <pkg> -o
jsonpath='{.status.channels[*].name}'`) — fixed in each role's own `defaults/main.yaml`
alongside this role's introduction, with the same re-verify-on-upgrade caveat already
used by `stage_mirror_content`'s `oc_mirror_operator_packages` channel pins.
