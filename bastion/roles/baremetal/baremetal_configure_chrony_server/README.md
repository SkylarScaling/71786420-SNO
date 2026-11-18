# baremetal_configure_chrony_server

Optional. Stands up chrony on the bastion itself as a local NTP source
(`local stratum {{ bastion_chrony_stratum }}`, no upstream server) for a fully
disconnected test network that has no real NTP server for the bastion to sync
against. Disabled by default (`bastion_chrony_server_enabled: false`) — a production
bare-metal site provides its own NTP server, consumed via the existing `ntp_server`
var (`additionalNTPSources` in `agent-config.yaml`, see
`baremetal_generate_agent_iso`'s README) rather than this role.

When enabled, set `ntp_server` (inventory) to this bastion's own IP — that's the only
wiring needed for the SNO node's side, since it reuses the `additionalNTPSources`
mechanism that's already in place. This role only configures the bastion side:
installing chrony, templating `/etc/chrony.conf`, enabling/restarting `chronyd`, and
opening the firewall for NTP.

`bastion_chrony_allow_network` defaults to `machine_network_cidr` — the SNO node's
own network — matching the customer's manually-validated config
(`allow <node-network>/24`).
