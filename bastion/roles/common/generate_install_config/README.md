# generate_install_config

Renders `install-config.yaml` for the Agent-Based Installer. Every install is treated
as disconnected (see
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md#2-disconnected-content-mirroring))
— there's no connected/non-mirrored code path. `imageContentSources` and
`additionalTrustBundle` always point at the mirror registry deployed on the bastion by
`deploy_mirror_registry`, which must run before this role (it sets the
`mirror_registry_ca_cert` and `mirror_registry_auth_b64` facts this role requires).

`pullSecret` is **not** the raw `pull_secret` var — this role merges in an `auths`
entry for the mirror registry (keyed `mirror_registry_quay_hostname:
mirror_registry_quay_port`, value `mirror_registry_auth_b64`) before rendering.
Without it, `openshift-install`'s own "Mirror registry ... is not found in
pullSecret" warning is fatal in practice: nothing on the node (kubelet, crio,
machine-config-daemon-pull) can authenticate to pull release/operator images from
there, and it manifests as bootstrapping silently timing out after 45 minutes rather
than a clear auth error (confirmed against a real run).

`platform: none`, consistent with the Agent-Based Installer — there's no cloud
platform integration on bare metal.

**Does not render `additionalNTPSources`** — that's an `AgentConfig` field
(`agent-config.yaml`), not an `InstallConfig` one. Confirmed live as a real bug: this
template used to render it here anyway, where `openshift-install` doesn't recognize
it, so the customer-provided NTP server never actually took effect even though it
appeared to be configured — moved to
`bastion/roles/baremetal/baremetal_generate_agent_iso`'s `agent-config.yaml.j2`,
still set from `ntp_server` when defined (per `staging/inventory/inventory.yaml`).
