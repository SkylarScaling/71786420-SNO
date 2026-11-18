# baremetal_generate_agent_iso

Renders the Agent-Based Installer's `agent-config.yaml` (node identity + nmstate
networking, plus `additionalNTPSources` — see below) alongside `install-config.yaml`
(via `generate_install_config`), then runs `openshift-install agent create image` to
produce the boot ISO, copies it into the bastion's `iso_serve_dir` (served by
`configure_bastion_services`'s httpd), and restores its SELinux context — the
resulting `iso_http_url` is what `baremetal_boot_node_via_bmc` mounts via Redfish
virtual media.

## No separate rootfs.img extraction needed

`baremetal_boot_node_via_bmc` boots the node by mounting the **full ISO** directly as
Redfish virtual media (`VirtualMediaInsert`), not PXE. PXE-based netboot is a
different boot path that serves `rootfs.img` (extracted from the ISO) separately from
a minimal iPXE/kernel boot — that split doesn't apply here. `agent.x86_64.iso` is the
only artifact that needs to be reachable at `iso_http_url`, and this role copies it
into place automatically; no manual copy or ISO-mount/extract step is needed.

## `additionalNTPSources`

Set from `ntp_server` when defined (customer-provided NTP server, per
`staging/inventory/inventory.yaml`). This lives here, not in
`generate_install_config`'s `install-config.yaml.j2` — confirmed live as a real bug:
it used to be rendered into `install-config.yaml` instead, which isn't where
`openshift-install` expects it (`additionalNTPSources` is an `AgentConfig` field),
so a configured NTP server never actually took effect even though the var appeared
set correctly in inventory.

## `role: master`

Rendered unconditionally on the single host entry — this is always a true
single-node deployment (`controlPlane.replicas: 1`, `compute.replicas: 0` in
`install-config.yaml`), so the sole host is always the control plane. No var needed,
unlike a multi-node `AgentConfig` where this would vary per host. Confirmed live as a
gap found against a customer's manually-fixed `agent-config.yaml`, which set this
explicitly.

## `rootDeviceHints` (`sno_root_device`)

Unset (`""`) by default; rendered as `rootDeviceHints.deviceName` only when set.
Without this, the Agent-Based Installer has to pick an install disk on its own,
which is non-deterministic on multi-disk hardware — confirmed live as a real gap
against a customer's manually-fixed `agent-config.yaml`, which pinned
`/dev/nvme0n1` explicitly; the target R7725 hardware has more than one NVMe drive.
Set `sno_root_device` in `staging/inventory/inventory.yaml` to the real target
device for any multi-disk server. Leave unset only for genuinely single-disk
hardware, where there's no ambiguity to begin with.

## ISO generation is guarded, not re-run unconditionally

`tasks/main.yaml` only runs `agent create image` if `{{ install_dir }}/agent.x86_64.iso`
doesn't already exist — without that check, re-running `provision-sno.yaml` after a
later failure (e.g. the BMC boot step, a known first-run failure point per the root
README) would regenerate the ISO every time. The ISO's own existence is the only
reliable signal available: `openshift-install` consumes (deletes)
`install-config.yaml`/`agent-config.yaml` as part of generating it, so both are
guaranteed to be freshly re-templated on any re-run regardless of whether anything
actually changed — a content- or mtime-based skip on those inputs isn't possible. To
force a genuine regeneration (network/BMC details actually changed since the ISO was
built), delete `{{ install_dir }}/agent.x86_64.iso` (or the whole `install_dir`)
before re-running.

## Network topology: single_switch (default) vs dual_switch

`sno_network_topology` selects the SNO node's nmstate network config:

- `single_switch` (default): one NIC (`sno_interface_name`/`sno_mac_address`), no
  bonding — matches the production default topology (single ToR switch, single NIC
  per function).
- `dual_switch`: bonds two NICs (`sno_interface_name`/`sno_mac_address` as primary,
  `sno_interface_name_secondary`/`sno_mac_address_secondary` as secondary) into
  `sno_bond_name` (default `bond0`) using `sno_bond_mode` (default `active-backup`),
  carrying the node's IP — so a single ToR switch failure doesn't take down node
  connectivity, provided each NIC in the bond is cabled to a different switch.
  Requires a second physical NIC on the server; confirm the target hardware's NIC
  count supports this before enabling. Fails fast in `tasks/main.yaml` if either
  secondary NIC var is missing while this mode is selected.

**This role only controls the SNO node's own networking — the bastion's NICs are not
configured by this automation at all** (`baremetal_prepare_bastion` only validates
reachability; the bastion is pre-existing, pre-configured customer hardware). If the
bastion also needs dual-switch bonding for the same redundancy, that's done
manually/out-of-band by the customer's own network admin — there is nothing in this
repo to toggle for it.

**Unverified against real hardware** — no live dual-NIC server has been available to
test the bonded nmstate config against yet, consistent with the same caveat already
carried by `baremetal_boot_node_via_bmc`'s README. If a real run surfaces nmstate
quirks with the bond syntax, fix them here.
