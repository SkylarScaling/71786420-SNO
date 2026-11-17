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

**Confirmed again 2026-11-16, far more broadly**, against a real customer run with a
much larger custom `oc_mirror_operator_packages` override (several extra catalogs,
many extra package/version pins, including nine separately-pinned `quay-operator`
versions) — dozens of unrelated operator repos (`odf4/*`, `quay/*`,
`cluster-observability-operator/*`, etc.) hit the same "manifest unknown" pattern in
one run, not just one tag in one catalog. A larger/more complex operator catalog list
appears to increase how *often* this defect surfaces, not just which repo(s) it
picks — this is the same defect as above, at scale, not a new one.

Rather than leaving this as a manual "if this recurs, re-run the role" instruction,
`tasks/main.yaml` now automates the detection and the known recovery:
`files/scan_archive_gaps.py` walks every repo in the cache (not a fixed list) right
after the mirror-to-disk run and reports any whose manifests reference blobs the
exported archive doesn't actually carry; if it finds any, this role re-runs
`oc-mirror` once in place against the same, already-populated cache (the same
self-heal that worked manually above) and re-scans. Whatever's still missing after
that — expected to be rare — is still worth capturing automatically even though the
retry mostly subsumes the original workaround below: `files/build_cache_handoff.py`
takes whatever repo list the final scan reports (unioned with `release_cache_repo_names`,
see below) and hardlinks each one's minimal referenced blob subset into
`release_cache_handoff_dir`, the same mechanism `package_bastion_bundle`/
`unpack_bastion_bundle` already carry to the bastion. If a repo's blob was never
written to this host's cache at all (truly unrecoverable — upstream
`registry.redhat.io`/`quay.io` unavailability during the mirror, not a commit race),
`build_cache_handoff.py` reports that explicitly and `tasks/main.yaml` fails the
staging run with the specific repo/digest list, rather than letting the gap surface
hours later as an opaque `manifest unknown` on the bastion.

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

Unlike the intermittent multi-catalog defect above, this one is 100% reproducible
every run (not just occasionally) — `release_cache_repo_names` (role default:
`[release, release-images]`) is always included in the cache handoff `tasks/main.yaml`
builds (see the "Known oc-mirror --v2 defect: multi-catalog..." section above for the
scan/retry/handoff mechanism this now shares), regardless of what the archive-gap
scan itself finds on any given run — this gap is never left to the scan's
discretion. If a third `manifest unknown` ever surfaces against another synthetic
`openshift/*` repo on every run (not just occasionally, the way the multi-catalog
defect is), add its name to `release_cache_repo_names` in `defaults/main.yaml` too —
nothing here enumerates oc-mirror's own synthetic repos up front, so this list is
"confirmed 100%-reproducible gaps found so far," not a closed set.

**A second, separate repo has the identical defect: `openshift/release-images`.**
Confirmed live on a real customer run, after the `openshift/release` fix above was
already in place: 188/192 release-component images mirrored successfully, but the
release *payload* image itself (`openshift/release-images:4.22.20-x86_64`, what
`ocp-release` actually resolves to) still failed with the same `manifest unknown` —
the handoff only ever scanned `openshift/release` at the time.

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

## Bastion RPMs — now `sync_bastion_rpms`

Mirroring the bastion's own OS-level RPM dependencies (`bastion_packages`/
`bastion_required_repos`, `reposync`/`resolve` via `bastion_rpm_sync_method`) used to
be a tagged (`bastion_prereqs`) block directly in this role's `tasks/main.yaml`. Split
out into its own `sync_bastion_rpms` role on 2026-11-17, at customer request: a full
`reposync` can run 8+ hours on its own, and the customer wanted to run/re-run it
independently of this role's separate, also-hours-long oc-mirror "mirror to disk"
step via a standalone playbook (`staging/playbooks/sync-bastion-rpms.yaml`), without
one blocking the other.

This role still imports `sync_bastion_rpms` (tagged `bastion_prereqs`, same tag as
before) so a combined `stage-and-package.yaml` run still produces both the content
mirror and the RPM sync in one pass — `--tags bastion_prereqs` on that playbook still
targets just the RPM-sync tasks, the same as when they lived here directly. See
`sync_bastion_rpms`'s own README for the `reposync`/`resolve` methods and
`bastion_rpm_sync_method`, and `package_bastion_rpms_bundle`'s README for why the RPM
output now ships to the bastion as its own tar.gz rather than inside
`package_bastion_bundle`'s main bundle.

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
