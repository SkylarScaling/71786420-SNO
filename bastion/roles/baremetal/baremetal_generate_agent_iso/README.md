# baremetal_generate_agent_iso

Renders the Agent-Based Installer's `agent-config.yaml` (node identity + nmstate
networking) alongside `install-config.yaml` (via `generate_install_config`), then
runs `openshift-install agent create image` to produce the boot ISO that
`baremetal_boot_node_via_bmc` mounts via Redfish virtual media.

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
