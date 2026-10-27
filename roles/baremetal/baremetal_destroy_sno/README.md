# baremetal_destroy_sno

Scaffold. Unlike AWS, there's no API call that tears down a physical server — "destroy"
here means wiping local disks and re-generating/re-mounting the install ISO so the
single node can be reinstalled from scratch. Finish this alongside
`baremetal_boot_node_via_bmc` once hardware access and BMC details are available.

Planned steps:
1. Redfish `PowerForceOff` via the real BMC.
2. Boot a rescue/live image (or reuse the agent ISO's discovery phase) and wipe the
   installation disk (`wipefs`/`sgdisk --zap-all`) so the next agent-based install
   starts clean.
3. Remove the generated `install_dir` content locally so a re-run regenerates
   install-config/agent-config/ISO from current vars.
