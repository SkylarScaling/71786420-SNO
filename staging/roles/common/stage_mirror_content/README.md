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

## Known `oc-mirror --v2` defect: release-content manifests never make it into the archive at all

Confirmed against a real run, and reproduced two more ways to rule out transfer
corruption or stale bastion-side state: `deploy_mirror_registry`'s disk-to-mirror
push failed with `manifest unknown` on the very first `openshift/release`
per-component image (e.g. `openshift/release:4.22.17-x86_64-cluster-kube-apiserver-operator`),
even against a freshly-synced archive and a freshly-unpacked bastion. A same-host,
no-transfer reproduction (mirror-to-disk and disk-to-mirror both run from the exact
same archive, same machine, no bundle/rsync step in between at all) failed
identically, ruling out `package_bastion_bundle`/`unpack_bastion_bundle`. Direct `tar
tvf` inspection of the archive confirmed the root cause: the tag/revision "link"
pointer files for every `openshift/release` component tag are present, but the
actual manifest/config/layer blob content those links point at is simply never
written into the exported `mirror_NNNNNN.tar` in the first place — a different,
100%-reproducible defect from the intermittent one above. Operator bundle content IS
fully archived; this gap is specific to `openshift/release`'s synthetic
per-component tags.

The fix: this role's "Build the release-content cache handoff" task computes the
minimal blob subset actually referenced by `stage_mirror_content`'s own
`openshift/release` cache metadata (every digest reachable from each tag's manifest —
config, layers, and any nested manifests for multi-arch), hardlinks just those into
`release_cache_handoff_dir`, laid out identically to oc-mirror's own
`.oc-mirror/.cache/docker/registry/v2/...` structure. `package_bastion_bundle` ships
that alongside the bundle as `release-cache/`, and `unpack_bastion_bundle` merges it
into the bastion's own `--cache-dir` (`oc_mirror_cache_dir`) before
`deploy_mirror_registry` ever runs, so disk-to-mirror has the content locally instead
of needing to reconstruct it from the archive. Confirmed ~20GiB for this subset vs.
~60GiB for the full cache in a real run — a fresh `--cache-dir` containing only this
handoff's output, with no other prior state, mirrored all 306 images successfully
end to end, including every previously-failing release-component image.

**A second, separate repo has the identical defect: `openshift/release-images`.**
Confirmed live on a real customer run, after the `openshift/release` fix above was
already in place: 188/192 release-component images mirrored successfully, but the
release *payload* image itself (`openshift/release-images:4.22.20-x86_64`, what
`ocp-release` actually resolves to) still failed with the same `manifest unknown` —
the handoff task only ever scanned `openshift/release`. `release_cache_repo_names`
in the "Build the release-content cache handoff" task is now a list (currently
`[release, release-images]`), looped over for both digest discovery and the
repo-metadata copy, rather than a single hardcoded path. If a third
`manifest unknown` ever surfaces against another `openshift/*` synthetic repo, add
its name to that list — nothing here enumerates oc-mirror's own synthetic repos up
front, so this list is "confirmed gaps found so far," not a closed set.

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
`inventory/<provider>/inventory.yaml`'s vars block to mirror a different set, or trim
the list if you're not exercising every feature. Set it to `[]` to mirror the
*entire* operator catalog instead (large and slow).

### Updating a mirrored operator's channel

A pinned `channel` in `oc_mirror_operator_packages` and the matching
`roles/ocp/configure_*`'s own `*_channel` default are two separately-maintained
values for the same actual requirement — read by two different tools at two
different times (oc-mirror, on staging, potentially hours/days before install; the
role's `Subscription` template, on the bastion/cluster, at install time). **Bumping
one without the other is a real failure mode, confirmed live**: `loki_channel`'s
`stable-6.6` pin was correct when first set, then silently dropped from the catalog
by a later mirror run, failing `oc-mirror` outright with the real cause buried in its
own per-component logs rather than surfaced clearly (see `tasks/main.yaml`'s "Fail if
the oc-mirror run itself failed" for the error-message improvement that followed).

When a channel needs to change (OCP upgrade, or just re-verifying periodically —
catalogs can drop older channels even without an `openshift_version` bump):

1. Re-run `oc-mirror list operators --v1 --catalog <index>[:vX.Y] --package <name>`
   against the catalog/version actually in use to confirm the real current channel —
   don't assume a channel that worked last time still exists.
2. Update the entry in `oc_mirror_operator_packages` here.
3. Update the matching role's own `*_channel` default in the **same change**.
4. Re-run `stage_mirror_content` (`--tags` isn't scoped finely enough to just the
   mirror step the way `bastion_prereqs` is for RPMs — a channel change needs the
   full "mirror to disk" re-run) before the next install/upgrade.

Currently-pinned entries that need both sides kept in sync: `loki-operator`
(`configure_lokistack`'s `loki_channel`), `grafana-operator`
(`configure_grafana`'s `grafana_channel`), `rabbitmq-cluster-operator`
(`configure_rabbitmq`'s `rabbitmq_operator_channel`), `crunchy-postgres-operator`
(`configure_postgres`'s `postgres_operator_channel`), and `quay-operator`
(`configure_onprem_quay`'s `quay_channel`) — each of those roles' own
`defaults/main.yaml` carries a comment pointing back here.

`quay-operator` was found missing from this list entirely while documenting this
(its `Subscription` is templated by `configure_onprem_quay`, but nothing had ever
mirrored it) — added as part of the same fix. Worth treating this as a prompt to spot
check: any `roles/ocp/configure_*` role that creates a `Subscription`/`CatalogSource`
needs a corresponding entry here, bare or pinned; there's no automated check tying
the two together.

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

## Bastion RPMs (`bastion_packages`/`bastion_required_repos`)

Separate from the container-image mirroring above — `bastion_packages` (default:
`dnsmasq`, `httpd`, `tmux`) are plain RPMs `configure_bastion_services` installs on
the bastion, which has no internet route of its own to reach them. `dnf download
--resolve` (see `tasks/main.yaml` for why not `dnf install --downloadonly`) needs
`bastion_required_repos`'s repo IDs already attached to *this* staging host's
subscription (just not necessarily enabled by default) to resolve against — passed
as `--enablerepo` on the download command itself rather than toggled host-wide via
`subscription-manager`, so this role doesn't leave staging's own repo configuration
changed as a side effect. Keep both vars and the RHEL major version staging/the
bastion are actually provisioned from in sync — see `configure_bastion_services`'s
README for why that match matters.

After downloading, `createrepo_c` runs against `mirror_installers_dir/bastion-rpms`
so it becomes a real (local-only) dnf repo — `repodata/` alongside the RPMs — rather
than a bare pile of files. Confirmed against a real customer environment: handing
dnf a raw list of RPM file paths to install (an earlier version of both this role
and `configure_bastion_services`) isn't reliable, since dnf's solver only considers
exactly the files named on the command line, with none of the repo metadata it
normally uses to work out a correct transaction across a larger closure. `createrepo_c`
itself is installed on staging from the same `bastion_required_repos` (ships in
AppStream), so no extra subscription attachment is needed beyond what's already a
documented prerequisite.

Tagged `bastion_prereqs` separately from the container-mirroring tasks above so it
can be re-run on its own (e.g. after adding a package to `bastion_packages` — update
`configure_bastion_services`'s own copy of the list too, see that role's README)
without redoing the hour-plus `oc-mirror` run — `--tags bastion_prereqs`, then
`--tags package` on `package_bastion_bundle` to re-bundle with the new RPMs/metadata
included.

## Progress reporting

The `oc-mirror` invocation runs `async: {{ oc_mirror_job_timeout }}, poll: 0` instead
of blocking synchronously, and `tasks/_poll_oc_mirror_progress.yml` prints a `debug`
message with bytes written to the local archive so far every `oc_mirror_poll_interval`
seconds, until `async_status` reports the job finished — same general pattern as
`package_bastion_bundle/unpack_bastion_bundle`/`package_staging_bundle/unpack_staging_backup_bundle`'s
progress polling, except there's no known total size to mirror against up front here,
so this reports progress-so-far rather than a percentage. Unlike v1 (which wrote a
single `.oc-mirror.log` this task used to grep for a blob count), v2 logs
per-component under `archive/working-dir/logs/` with filenames not yet verified
against a real run — reporting on destination-directory size instead avoids depending
on that layout.

`tasks/main.yaml`'s "Poll and report oc-mirror progress" task loops
`_poll_oc_mirror_progress.yml` a fixed number of times (`oc_mirror_job_timeout /
oc_mirror_poll_interval`, so always in lockstep with the async ceiling), rather than
that file recursively `include_tasks`-ing itself — it used to, and a real multi-hour
run at the original 15-second interval hit Ansible's "maximum recursion depth
exceeded" (confirmed live: each recursive `include_tasks` call adds its own stack
frame, and a 4-hour job at 15s/poll is roughly 960 levels deep). Looping the
`include_tasks` call from the top keeps stack depth constant no matter how many times
it fires, so `oc_mirror_poll_interval` is now free to be tuned for responsiveness
without reintroducing that failure mode. `_poll_oc_mirror_progress.yml` isn't meant to
run standalone; it depends on `_stage_mirror_job` set in `tasks/main.yaml`.
