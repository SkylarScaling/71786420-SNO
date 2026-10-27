# baremetal_boot_node_via_bmc

Mounts the agent ISO via BMC virtual media and power-cycles the node to boot it —
confirmed against Dell iDRAC9/10 (the target hardware, PowerEdge R7725), which
implements standard Redfish with no vendor-specific payload beyond naming the
Manager/System resource IDs (`bmc_manager_resource_id`/`bmc_system_resource_id`,
defaulted to iDRAC's fixed names).

Fails fast if `bmc_address`/`bmc_username`/`bmc_password`/`iso_http_url` aren't set
(staging/inventory/inventory.yaml's vars block), so it can't silently no-op in a
full-setup run.

## Flow

1. `VirtualMediaInsert` (category `Manager`) mounts `iso_http_url` — point this at
   the ISO as served by `configure_bastion_services`
   (`http://<bastion>/sno-iso/agent.x86_64.iso`).
2. `SetOneTimeBoot` (category `Systems`) to `Cd`, with `boot_override_mode` matching
   `bmc_boot_mode` (`Uefi` by default — set `Legacy` if the server's configured boot
   mode doesn't match).
3. `PowerForceRestart`, then poll `GetSystemInfo` until `PowerState == 'On'`
   (20 retries × 15s) before handing off.

Agent-based install takes it from there (boots the ISO, applies
`agent-config.yaml`/`install-config.yaml`, starts the assisted-installer service) —
`roles/ocp/wait_for_sno_install` polls cluster-level install progress separately;
this role's job ends once the node is confirmed powered on with the ISO mounted.

## If a different BMC vendor is ever used

Everything here is standard Redfish (`community.general.redfish_command`/
`redfish_info`) except the two resource-ID defaults, which are iDRAC's fixed naming.
Override `bmc_manager_resource_id`/`bmc_system_resource_id` per vendor; the task
logic itself should need no changes for any Redfish-compliant BMC (iLO, generic
OpenBMC, etc.), though this hasn't been validated against anything but iDRAC9/10.
