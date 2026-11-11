# deploy_mirror_registry

Third step of the disconnected mirroring pattern (see
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md#2-disconnected-content-mirroring)):
runs **on the bastion** (the disconnected target), installs a standalone Quay via
`mirror-registry`, and pushes the archive synced by `package_bastion_bundle/unpack_bastion_bundle` into it
("disk to mirror"). This is the registry `install-config.yaml`'s
`imageContentSources`/`imageDigestSources` point at — set via
`mirror_registry_quay_hostname`/`mirror_registry_quay_port`, consumed by
`roles/common/generate_install_config`.

Before any of that, fails fast with guidance if `mirror_registry_quay_hostname`
doesn't resolve (checked via `getent hosts`) — that hostname is a customer DNS
record (`docs/bare-metal-architecture.md` §9), not something this automation
provisions, and without this check a missing record wasn't discovered until well
into the run: `mirror-registry install` (several minutes), `podman login`, and
`oc-mirror`'s push all independently fail on it with a generic "Temporary failure in
name resolution"/"Name or service not found" that gives no hint it's a DNS gap.

`mirror_registry_ca_cert` is set as a fact from the registry's generated root CA, for
`additionalTrustBundle` in the install-config. The same CA is also written to
`/etc/pki/ca-trust/source/anchors/` and trusted via `update-ca-trust` **on the bastion
itself** — that's a separate need from the cluster's trust bundle: the "disk to
mirror" push below runs `oc-mirror` on the bastion, talking to Quay over HTTPS, and
without this it fails immediately with `x509: certificate signed by unknown
authority` before attempting any push (confirmed against a real run).

Also extracts the `oc-mirror` binary into `{{ bin_dir }}` for the push, and the
`mirror-registry` installer itself — this host has no internet route at all, so both
are unarchived from the tarballs `package_bastion_bundle/unpack_bastion_bundle` already
synced into `{{ mirror_installers_dir }}` (downloaded by `stage_mirror_content` on the
internet-connected mirror-staging host) rather than fetched here directly. A real run
once hit this the hard way: the original version of this role tried a plain
`get_url`/`unarchive` from `mirror.openshift.com` straight from the bastion and failed
with `Network is unreachable` — don't reintroduce a direct download here.

Before any of that, hardens sshd's `ClientAliveInterval`/`ClientAliveCountMax` on the
bastion the same way `stage_mirror_content` does on the mirror-staging host — the
install and the "disk to mirror" push are both long, bursty operations with the same
risk of an idle SSH connection getting dropped mid-run.

## `mirror-registry install` quirks (confirmed against a real 2.0.12 run)

- **No `status`/`start` subcommand** — only `install`/`uninstall`/`upgrade` exist.
  Always run `install` unconditionally, first-time or re-run alike: it's idempotent
  on its own (detects an existing `~/quay-install/quay-config/config.yaml`, preserves
  its secrets, and reconciles/restarts the containers), so there's no need (and no
  working way) to pre-detect install state with separate commands.
- **No `--quayPort` flag** — `install`'s only hostname-related flag is
  `--quayHostname`, and the port must be embedded in it directly (`host:port`); its
  own default is literally `"<targetHostname>:8443"`. Passing `--quayPort` separately
  doesn't error loudly — see below.
- **Exits 0 even when it did nothing** — confirmed directly: passing the (invalid)
  `--quayPort` flag printed `Error: unknown flag: --quayPort` and the command's usage
  text, then still returned exit code 0. `tasks/main.yaml` can't rely on `rc` to
  detect failure here, so it `stat`s for `~/quay-install/quay-config/config.yaml`
  immediately afterward and fails loudly with the captured stdout/stderr if it's
  missing, rather than letting the "Wait for the mirror registry to be healthy" task
  below spend ten minutes retrying before reporting an opaque `Connection refused`.
- **Regenerates a brand new self-signed TLS cert/key on every invocation** unless
  `--sslCert`/`--sslKey` are passed — confirmed directly: an otherwise fully
  idempotent second run still showed `changed` for "Create root CA key"/"Create root
  CA pem"/"Create ssl key". Harmless within a single playbook run (the CA is fetched
  fresh after install, see below), but across separate runs (e.g. re-running
  `mirror-content.yaml` to refresh content on an already-installed cluster) it would
  silently invalidate the CA that cluster's `install-config.yaml`
  `additionalTrustBundle` already baked in. `tasks/main.yaml` persists the first run's
  generated `ssl.cert`/`ssl.key` to `{{ mirror_registry_install_dir }}/.ssl.cert`/
  `.ssl.key` and passes them back via `--sslCert`/`--sslKey` on every run after that,
  so the cert stays stable for the life of the bastion.

- **Always SSHes to its install target, even for a "local" install onto the box
  it's invoked from** — confirmed against a real run: without an existing key at its
  default identity path, `install` fails outright with `could not find ssh key at
  default location` rather than generating one itself or falling back to a
  non-SSH local path. `tasks/main.yaml` generates an SSH key pair at
  `mirror_registry_ssh_key` (default `~/.ssh/quay_installer`, matching
  `mirror-registry`'s own default) if one doesn't already exist, adds it to this
  same user's own `authorized_keys` (mirror-registry connects back to itself as the
  user running the install), and passes it explicitly via `--sshKey` so the install
  doesn't depend on whatever mirror-registry's own default resolves to.

## Registry auth for the "disk to mirror" push

`mirror-registry install` creates a default `init` user and prints its password to
stdout every run — e.g. `... with credentials (init, <password>)` — but that printed
password is **only real the first time the init user is actually created**. Confirmed
directly against two consecutive real runs: every idempotent reconcile run afterward
still prints that same line with a freshly fabricated, inapplicable random password,
even though the "Create init user" task itself reports `Init user already exists,
skipping creation` and the account's real password never changes. Trusting stdout on
every run (an earlier version of this role did) intermittently logs in with the wrong
password and fails the push with `UNAUTHORIZED: access to the requested resource is
not authorized`.

`tasks/main.yaml` instead extracts credentials from stdout **only the first time**
(detected by the absence of a persisted `{{ mirror_registry_install_dir }}/
.init-credentials` file), saves them there, and reads from that file on every run
thereafter — `podman login`s with whatever that file contains before the
`oc-mirror --v2 --from ... docker://...` push. If `mirror-registry`'s own output
format for this line ever changes, the regex in the "Extract the generated init user
credentials" task will need updating — it fails loudly (rather than silently
proceeding unauthenticated) if it can't find a match on that first run.

`tasks/main.yaml`'s login task intentionally has no `no_log` right now, so a real
failure's stdout/stderr is visible for debugging against the live customer
environment — which also means the init user's password prints in the task's own
output if it fails. Re-add `no_log: true` once the bastion rollout is stable and this
task is no longer a live debugging target.

## The "disk to mirror" push (`oc-mirror --v2`)

Unlike v1 (where `--from {{ mirror_archive_dir }}` alone was enough, since the
archive was fully self-describing), v2's push needs `--config` again, and `--from`
itself now requires an explicit `file://` prefix (confirmed against a real run:
`oc-mirror` rejects a bare path with "[Executor] when --from is used, it must have
file:// prefix") —
`stage_mirror_content` renders `imageset-config.yaml` directly into the archive
directory specifically so it arrives here via `package_bastion_bundle/unpack_bastion_bundle` without a
separate sync path; this role's push points `--config` at
`{{ mirror_archive_dir }}/imageset-config.yaml`. It also needs its own
`--cache-dir` (`oc_mirror_cache_dir`, default under `{{ mirror_registry_install_dir
}}`) — a separate directory from `stage_mirror_content`'s cache on the mirror-staging
host (different machine), but **not independent of it**: `unpack_bastion_bundle`
pre-populates this directory with a minimal subset of that staging-side cache before
this role ever runs, because the archive alone doesn't carry everything disk-to-mirror
needs — see `roles/common/stage_mirror_content/README.md`'s "release-content
manifests never make it into the archive at all" section for the full story. Don't
clear or recreate this directory before the push; it needs to arrive pre-populated.
See the same README for why this role moved from v1 to v2 in the first place (a
release-image signature-verification failure on a real 4.22 bootstrap).

The push itself retries (`until`/`retries: 3`/`delay: 30`) rather than running once —
on a real customer run, a ~22-minute push of 483 images hit a batch of `received
unexpected HTTP status: 500 Internal Server Error` from the registry's own
bearer-token endpoint, spread across the run (release images, pushed first, all
succeeded; operator images, pushed later with heavier shared-layer dedup traffic via
"trying to reuse blob", took the hit). Retrying is safe regardless of root cause,
since oc-mirror/containers-image check for and reuse blobs that already exist at the
destination before re-uploading, so a retry mostly re-attempts only what actually
failed. On final failure after retries, the task greps `{{ mirror_archive_dir
}}/working-dir/logs/mirroring_errors_*.txt` (the exact file oc-mirror's own output
already points at, but buried at the bottom of a potentially huge stdout dump) and
surfaces the tail directly in the failure message.

**Root cause confirmed, on the customer's own bastion: `/var` was at 100%
utilization, not memory/CPU as first suspected.** Podman's default storage root
(`/var/lib/containers`) backs both `mirror-registry`'s own Quay/Postgres/Redis
containers and every blob `oc-mirror`/`podman`/`skopeo` stage locally while copying —
filling it up breaks container storage in a way that surfaces as a registry-side
`500 Internal Server Error`, not an obvious disk-full error, which is what made this
one hard to diagnose from the client side alone. The retry above is still useful
insurance for a genuinely transient blip, but **won't fix this specific failure
mode** — a persistently full `/var` fails identically on every attempt. See the new
disk-space check below, added directly in response to this finding.

### Pre-flight disk space check

Before anything else in this role runs, it checks `/var`'s free space (`df -BG
--output=avail /var`) against `bastion_min_free_disk_gb` (default `100`, an
unconfirmed placeholder — tune it once a real run's actual `/var` usage for this
customer's `oc_mirror_operator_packages` selection is known) and fails immediately
with guidance if it's short, rather than discovering it ~20+ minutes into a "disk to
mirror" push the way the confirmed incident above did.

The same `base64("user:pass")` value (already in the exact format the pull secret's
`auth` field needs, since that's what `slurp` returns for the `.init-credentials`
file) is also exposed as the `mirror_registry_auth_b64` fact, which
`generate_install_config` reads directly (both roles run in the same single-host
`bastion/playbooks/provision-sno.yaml` play) to merge into `pullSecret` — without this,
`openshift-install`'s own "Mirror registry ... is not found in pullSecret" warning is
fatal in practice: nothing on the node can authenticate to pull images from here,
which manifested as bootstrapping timing out after 45 minutes with no clearer error
(confirmed against a real run).
