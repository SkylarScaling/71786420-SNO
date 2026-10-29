# stage_mirror_content

First step of the disconnected mirroring pattern (see
[`docs/architectural-decisions.md`](../../../docs/architectural-decisions.md#2-disconnected-content-mirroring)):
runs directly on staging (`hosts: localhost` — this automation is executed directly
on the internet-connected staging host) and uses the `oc-mirror` binary (downloaded
here into `{{ bin_dir }}`) in "mirror to disk" mode to produce a self-contained
archive under `{{ oc_mirror_workspace }}/archive` — no registry needs to run on this
host.

Also downloads the raw `oc-mirror`, `mirror-registry`, `openshift-install`, and `oc`
tarballs under `{{ mirror_installers_dir }}` (not just extracting `oc-mirror` into
`{{ bin_dir }}` for its own use) — the bastion has no internet route at all, so it
can't fetch any of these itself; `package_bastion_bundle`/`unpack_bastion_bundle`
carry them over inside the bundle the same way they carry the content archive, and
`deploy_mirror_registry` unarchives `oc-mirror`/`mirror-registry` from that bundled
copy. See `docs/architectural-decisions.md` #1.

Also downloads RPMs (`bastion_packages`, with full dependency closure, into
`{{ mirror_installers_dir }}/bastion-rpms`) and a Python wheelhouse
(`requirements-bastion.txt`, into `{{ mirror_installers_dir }}/bastion-wheelhouse`)
for the bastion to install entirely offline. `configure_bastion_services` installs
the RPMs it actually needs (dnsmasq/httpd) later, once Ansible is already running
there — but `ansible-core`/`python3-pip` are in `bastion_packages` precisely so
Ansible can exist in the first place on a bastion that starts with nothing on it at
all (the AWS test loop's freshly provisioned EC2 bastion; bare-metal bastions are
assumed to already have this baked into their base image — see
`bastion/roles/baremetal/baremetal_prepare_bastion`'s README). `../../../bastion/
bootstrap-bastion-host.sh` installs both the RPMs and the wheelhouse, the same
"minimum possible in bash before Ansible can take over" role `staging/
bootstrap-staging-host.sh` plays for the staging host.

Runs with `--v2`: `oc-mirror --v1` is deprecated (every v1 run printed its own
warning: "oc-mirror v1 is deprecated ... will be removed in a future release") and,
on a real run against OpenShift 4.22, its mirrored content failed release-image
signature verification on the node (`Source image rejected: A signature was required,
but no signature exists`) — v1 predates the OCI sigstore-attachment model the
installer now expects to find on the mirror. `imageset-config.yaml.j2` is the
`v2alpha1` `ImageSetConfiguration` schema, which drops v1's `storageConfig` block
(v2 tracks state in a `--cache-dir` instead of a local metadata path) but otherwise
keeps the same two-phase "mirror to disk" → "disk to mirror" split this whole pattern
is built around (`docs/architectural-decisions.md` #2) — v2 supports that split just
as well as v1 did, via `--workspace`/`file://` output and a later `--from file://...`
push, so switching tools didn't require redesigning the overall pipeline. It did
require two smaller changes, both already made: `imageset-config.yaml.j2` is rendered
directly into `{{ oc_mirror_workspace }}/archive/` (not the workspace root) so it
rides along automatically when `package_bastion_bundle/unpack_bastion_bundle` syncs the archive, since v2's
"disk to mirror" push needs `--config` again (v1's `--from` alone was enough because
the archive was fully self-describing); and `roles/common/deploy_mirror_registry`'s
push step passes its own `--cache-dir` too. Whether v2 actually resolves the
signature-verification failure isn't independently confirmed yet — verify against the
next real bootstrap run; if it doesn't, the gap is in RHCOS's `/etc/containers/
policy.json` expectations, not this role.

## Known `oc-mirror --v2` defect: multi-catalog mirror-to-disk can drop a tag's blob

Confirmed against a real run: with `oc_mirror_operator_packages` split across three
operator catalogs (redhat/community/certified, per `defaults/main.yaml`), one
mirror-to-disk invocation left `certified-operator-index`'s `v4.22` tag in the
archive's internal docker-registry storage pointing at a manifest digest whose blob
was never actually written — `deploy_mirror_registry`'s later "disk to mirror" push
failed with `reading manifest v4.22 in 127.0.0.1:55000/redhat/certified-operator-index:
manifest unknown` even against a freshly-synced, uncontaminated archive (ruled out via
`tar -tvf mirror_000001.tar`: the tag/revision link files existed, the blob file under
`docker/registry/v2/blobs/sha256/...` did not). Mirroring the certified catalog alone
with the same `--cache-dir` produced a complete, correct blob; re-running the full
three-catalog mirror-to-disk against that now-warmed cache then also produced a
correct blob, and the push succeeded — strongly suggesting a commit/race defect in how
`oc-mirror --v2` finalizes the last-processed catalog's rebuilt tag when multiple
catalogs are mirrored in one invocation, not anything specific to this repo's config
or pipeline. If this recurs: re-run this role (`stage_mirror_content`) rather than
suspecting `package_bastion_bundle/unpack_bastion_bundle` or `deploy_mirror_registry` — both were verified
innocent by testing against a fully-cleared, freshly-synced bastion first.

## Platform release pinning

`imageset-config.yaml.j2`'s `mirror.platform.channels` entry pins both `minVersion`
and `maxVersion` to `openshift_version` exactly. Without this, `oc-mirror` mirrors
whatever the *latest* release in that channel happens to be at mirror time — which
silently drifts out of sync with `openshift_version` (the version this role itself downloads `openshift-install`/`oc` for).
Confirmed against a real run: the channel had moved to `4.22.18` while
`openshift_version` stayed pinned at `4.22.17`, and the resulting digest mismatch made
every release-image pull on the master fail with `manifest unknown` against the
mirror — which manifested as bootstrapping timing out after 45 minutes, not a clear
version-mismatch error. Bump `openshift_version` deliberately when you want a newer
release; don't let the channel pick it implicitly.

## Operator packages mirrored

`oc_mirror_operator_packages` (role default, see `defaults/main.yaml`) is the full
set this repo's feature roles install — LVM Storage, OADP, cluster logging, the ODF
operator in standalone MCG mode, Loki/Grafana, OpenTelemetry/Tempo, MetalLB,
RabbitMQ, Crunchy Postgres, and Keycloak — each entry either a bare package name
(default catalog/channel) or a `{name, channel, catalog}` dict where a package needs
a pinned channel or ships from a non-default operator index. Override this in
`staging/inventory/inventory.yaml`'s vars block to mirror a different set, or trim
the list if you're not exercising every feature. Set it to `[]` to mirror the
*entire* operator catalog instead (large and slow).

Before any of that, hardens sshd's `ClientAliveInterval`/`ClientAliveCountMax` on this
host (paired with `ServerAliveInterval`/`ControlPersist` in `playbooks/ansible.cfg`) —
the "mirror to disk" run can go quiet for long stretches with no stdout while pulling
large blobs, and at sshd defaults that idle period can get the SSH connection dropped
by something in between (NAT/firewall state timeout), failing the task with "Shared
connection to X closed" even though the host itself is healthy.

Writes `pull_secret` (`group_vars/all.yaml`) to `~/.docker/config.json` on this host
so `oc-mirror` can authenticate to `registry.redhat.io`/`quay.io` — this relies on
`pull_secret` being the standard pull secret downloaded from
console.redhat.com/openshift/install/pull-secret, which already bundles auths for
those registries alongside the cluster-facing ones. If you're using a pull secret
that's missing those entries, merge them in before running this role.

## Progress reporting

The `oc-mirror` invocation runs `async: 14400, poll: 0` instead of blocking
synchronously, and `tasks/_poll_oc_mirror_progress.yml` is included recursively every
15 seconds to print a `debug` message with bytes written to the local archive so far,
until `async_status` reports the job finished — same pattern as
`package_bastion_bundle/unpack_bastion_bundle`/`package_staging_bundle/unpack_staging_backup_bundle`'s progress polling, except there's
no known total size to mirror against up front here, so this reports progress-so-far
rather than a percentage. Unlike v1 (which wrote a single `.oc-mirror.log` this task
used to grep for a blob count), v2 logs per-component under
`archive/working-dir/logs/` with filenames not yet verified against a real run —
reporting on destination-directory size instead avoids depending on that layout.
`_poll_oc_mirror_progress.yml` isn't meant to run standalone; it depends on
`_stage_mirror_job` set in `tasks/main.yaml`.
