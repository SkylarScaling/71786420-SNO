# deploy_mirror_registry

Third step of the disconnected mirroring pattern (see
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md#2-disconnected-content-mirroring)):
runs **on the bastion** (the disconnected target), installs a standalone Quay via
`mirror-registry`, and pushes the archive synced by `package_bastion_bundle/unpack_bastion_bundle` into it
("disk to mirror"). This is the registry `install-config.yaml`'s
`imageContentSources`/`imageDigestSources` point at — set via
`mirror_registry_quay_hostname`/`mirror_registry_quay_port`, consumed by
`roles/common/generate_install_config`.

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
}}`), independent of `stage_mirror_content`'s cache on the mirror-staging host. See
`roles/common/stage_mirror_content/README.md` for why this role moved from v1 to v2
in the first place (a release-image signature-verification failure on a real 4.22
bootstrap).

The same `base64("user:pass")` value (already in the exact format the pull secret's
`auth` field needs, since that's what `slurp` returns for the `.init-credentials`
file) is also exposed as the `mirror_registry_auth_b64` fact, which
`generate_install_config` reads directly (both roles run in the same single-host
`provision-sno-baremetal.yaml`/`provision-sno-aws.yaml` play) to merge into `pullSecret` — without this,
`openshift-install`'s own "Mirror registry ... is not found in pullSecret" warning is
fatal in practice: nothing on the node can authenticate to pull images from here,
which manifested as bootstrapping timing out after 45 minutes with no clearer error
(confirmed against a real run).
