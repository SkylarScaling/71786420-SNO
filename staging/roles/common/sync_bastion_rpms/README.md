# sync_bastion_rpms

Mirrors the bastion's own OS-level RPM dependencies (`dnsmasq`, `httpd`, `tmux`,
`bind-utils`, `nmstate` by default) on the internet-connected staging host, for
offline install on the bastion — which has no internet route to reach RHUI/dnf repos
at all.

Split out of `stage_mirror_content` on 2026-11-17 at customer request: a full
`reposync` of `bastion_required_repos` can run 8+ hours on its own, and the customer
wanted to run/re-run that independently of the separate, also-hours-long oc-mirror
"mirror to disk" step, without one blocking the other.

## Two ways to run this

- **Standalone**: `staging/playbooks/sync-bastion-rpms.yaml` — just this role, plus
  `package_bastion_rpms_bundle` to produce the separate tar.gz. Use this to
  refresh/retry the RPM sync on its own schedule, independent of `stage-and-package.yaml`.
- **As part of the combined flow**: `stage_mirror_content` still imports this role
  (tagged `bastion_prereqs`), so a normal `stage-and-package.yaml` run produces both
  the content mirror and the RPM sync in one pass, same as before the split.
  `--tags bastion_prereqs` on that playbook still targets just this role's tasks, the
  same as it did when they lived directly in `stage_mirror_content`.

## `bastion_rpm_sync_method`: `reposync` (default) vs `resolve`

- **`reposync`** (default, deliberate customer choice, not the smallest possible
  transfer): mirrors `bastion_required_repos` **wholesale** — every RPM in each
  listed repo, not just `bastion_packages`' own dependency closure. `--download-metadata`
  carries over each repo's own published `repodata/` directly (no `createrepo_c` step
  needed); `--delete` prunes RPMs dropped from the upstream repo on a re-run so this
  doesn't grow unbounded. One subdirectory per repoid lands under
  `mirror_installers_dir/bastion-rpms/`.
- **`resolve`** (opt-in): the original, narrower `dnf download --resolve` approach.
  In its original form this was confirmed unreliable **twice** against two unrelated
  package families (`git-core`, then the full `apr-util`/`libapr-1`/`libaprutil-1`
  chain `httpd-core` needs): plain `dnf download --resolve` resolves dependencies
  against the rpmdb of whatever root it runs against — this staging host's own real
  root, by default — so a dependency already satisfied here (even transitively, even
  by something unrelated already installed) is silently dropped from the download
  set. The bastion starts with none of staging's pre-existing packages, so a closure
  that "resolved cleanly" here can still fail a depsolve there (confirmed live: the
  second failure surfaced as `configure_bastion_services`' `dnf install` on the
  bastion failing outright with `nothing provides apr-util-1(dbm)...` /
  `libapr-1.so.0()...` / `libaprutil-1.so.0()...`).

  **Fixed** by resolving against a brand-new, empty installroot
  (`bastion_rpm_resolve_installroot`, wiped and reinitialized with `rpm --initdb` on
  every run) instead of staging's real root — a standard dnf technique for exactly
  this class of problem. With no packages "already installed" in that root, nothing
  is ever treated as pre-satisfied, so the downloaded closure is complete regardless
  of what staging itself happens to have installed — the same correctness guarantee
  `reposync` gets structurally, without `reposync`'s full-repo transfer size.
  **Unverified against a live run yet** — if a depsolve gap is ever confirmed again
  after this fix, suspect the `--installroot`/`--releasever`/`--setopt=reposdir`
  flags in `tasks/main.yaml` first, not the `--resolve` approach itself.

  Downloads into a single flat directory and needs `createrepo_c` (installed from
  `bastion_required_repos` itself) to turn it into a real repo afterward.

**`bastion_rpm_sync_method` must match between staging and the bastion** (this role's
copy and `configure_bastion_services`'s copy) — a mismatch doesn't fail loudly on its
own; `configure_bastion_services` just looks for repo metadata in the wrong place and
fails with a `repodata not found` guidance message.

`bastion_required_repos` must already be attached to *this* staging host's
subscription (just not necessarily enabled by default) — passed as `--enablerepo` on
the `reposync`/`download` command itself rather than toggled host-wide via
`subscription-manager`, so this role doesn't leave staging's own repo configuration
changed as a side effect. Keep this list, and the RHEL major version staging/the
bastion are actually provisioned from, in sync with `configure_bastion_services`'s own
copy on the bastion side.

**`bastion_rpm_reposync_max_parallel_downloads`** (default `10`) sets `reposync`'s
`--setopt=max_parallel_downloads`. dnf's own default (3, even with multiple
`--repoid`s passed) leaves most of a typical staging host's bandwidth idle during the
full BaseOS+AppStream mirror — confirmed live: a real run projected 10+ hours at the
dnf default given the tens-of-GB transfer size (AppStream's many module streams in
particular). This only changes download concurrency, not what gets mirrored; tune it
down if staging's own network or disk I/O turns out to be the actual bottleneck
instead of request concurrency.

## Where the output goes

RPMs land under `{{ mirror_installers_dir }}/bastion-rpms` — the same directory tree
`stage_mirror_content` downloads the `oc-mirror`/`mirror-registry`/`openshift-install`/`oc`
tool tarballs into, but packaged to the bastion separately: see
`package_bastion_rpms_bundle`'s README for why this ships as its own tar.gz rather
than inside `package_bastion_bundle`'s main bundle.
