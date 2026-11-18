# baremetal_destroy_sno

Unlike AWS, there's no API call that tears down a physical server — "destroy" here
means wiping local disks and re-generating/re-mounting the install ISO so the single
node can be reinstalled from scratch. Requires `baremetal_destroy_sno_confirm: true`
(`-e`), same pattern as `simulate_node_failure`.

1. **Done**: Redfish `PowerForceOff` via the real BMC, using the same
   `bmc_address`/`bmc_system_resource_id` vars as `baremetal_boot_node_via_bmc`.
2. **Still a scaffold**: booting a rescue/live image (or reusing the agent ISO's
   discovery phase) and wiping the installation disk (`wipefs`/`sgdisk --zap-all`).
   Fails fast with manual instructions instead of guessing — a wrong wipe target on
   real hardware is irreversible, so this needs validation against the actual target
   disk layout before being automated.
3. **Done**: removes the locally generated `install_dir` content so a re-run
   regenerates install-config/agent-config/ISO from current vars.
