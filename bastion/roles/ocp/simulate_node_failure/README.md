# simulate_node_failure

A reboot/recovery drill for the SNO node — validates how quickly workloads return
after unscheduled downtime, feeding into a node maintenance/replacement protocol
document. Gated behind `simulate_node_failure_confirm=true` since on a single node
this *is* a full outage, not a rolling-update-style no-op.

## What this does not cover

Total node replacement (new hardware, re-running the agent-based install, restoring
application data from the OADP offsite backup) is a physical-swap scenario that can't
be meaningfully automated against a VM — document that procedure manually using
`configure_oadp_backup`'s restore path once bare-metal hardware is available, and treat
this role as validating only the "temporary downtime, same hardware" half of node
maintenance planning.
