# package_bastion_rpms_bundle

Packages `sync_bastion_rpms`'s output (`{{ mirror_installers_dir }}/bastion-rpms`)
into its own `sno-bastion-rpms-{{ cluster_name }}.tar.gz` (+ `.sha256`, same checksum
pattern as `package_bastion_bundle`'s main bundle) in `bastion_bundle_export_dir`.

## Why a separate bundle, not part of the main one

Added 2026-11-17 at customer request, alongside `sync_bastion_rpms` being split out
of `stage_mirror_content`: a full `reposync` can run 8+ hours on its own, and the
customer wanted to be able to refresh the bastion's RPM content (e.g. after adding a
package, or after a transient `reposync` failure) without re-sending the much larger
main bundle (mirrored container content, tens of GB) just to pick up a small RPM
change — and without the main bundle's packaging/transfer step depending on the RPM
sync having just run.

`package_bastion_bundle` still calls this role too (so a normal, combined
`stage-and-package.yaml` run produces both bundles in one pass) but no longer
includes `bastion-rpms/` inside its own `mirror-installers/` copy — see that role's
README.

## Called from two places

- `staging/playbooks/sync-bastion-rpms.yaml` — the standalone RPM-sync path, so
  running just that playbook also repackages this bundle.
- `package_bastion_bundle` — so the combined flow still produces this bundle
  alongside the main one.

## Unpacking

`bastion/roles/common/unpack_bastion_rpms_bundle` (via
`bastion/playbooks/unpack-bastion-rpms.yaml`) is the bastion-side counterpart —
verifies the checksum and extracts into `mirror_installers_dir/bastion-rpms`,
independent of `unpack_bastion_bundle`/`provision-sno.yaml`. Requires the main bundle
to have been unpacked at least once already (for `bastion/` and the resolved vars to
exist on the bastion).

## Known gap

No live two-host transfer has been tested yet, same as `package_bastion_bundle`'s own
known gap.
