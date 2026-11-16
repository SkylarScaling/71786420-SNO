#!/usr/bin/env python3
"""Find any oc-mirror cache repo whose referenced blobs are missing from the
exported mirror_*.tar archive(s) — see the "Known oc-mirror --v2 defect:
multi-catalog mirror-to-disk can drop a tag's blob" section of this role's
README for the failure this detects (and why it isn't limited to
openshift/release the way the first-discovered instance of it was).

Usage: scan_archive_gaps.py <registry_v2_dir> <archive_dir>
Prints {"gap_repos": ["<namespace>/<name>", ...]} to stdout.
"""
import json
import os
import re
import sys
import tarfile

registry_v2_dir, archive_dir = sys.argv[1:3]
repos_root = os.path.join(registry_v2_dir, "repositories")


def referenced_digests(repo_dir):
    digests = set()
    revisions_dir = os.path.join(repo_dir, "_manifests/revisions/sha256")
    if not os.path.isdir(revisions_dir):
        return digests
    for rev in os.listdir(revisions_dir):
        digests.add(rev)
        blob_path = os.path.join(registry_v2_dir, "blobs/sha256", rev[:2], rev, "data")
        if not os.path.exists(blob_path):
            continue
        with open(blob_path) as f:
            try:
                manifest = json.load(f)
            except ValueError:
                continue
        if "config" in manifest:
            digests.add(manifest["config"]["digest"].split(":")[1])
        for layer in manifest.get("layers", []):
            digests.add(layer["digest"].split(":")[1])
        for sub in manifest.get("manifests", []):
            digests.add(sub["digest"].split(":")[1])
    return digests


# Every (namespace/name) directory anywhere under repositories/ that actually
# has a _manifests subdirectory — walked generically rather than assuming any
# fixed set of repo names, since the whole point is to catch gaps anywhere,
# not just the two synthetic openshift/* repos already known to have them.
repo_dirs = []
if os.path.isdir(repos_root):
    for root, _dirs, _files in os.walk(repos_root):
        if os.path.basename(root) == "_manifests":
            repo_dirs.append(os.path.dirname(root))

# Blob digests actually present somewhere in the exported tar archive(s).
# Reading member names only (no extraction) is cheap even for a multi-GB tar —
# tarfile just scans headers.
blob_re = re.compile(r"blobs/sha256/[0-9a-f]{2}/([0-9a-f]{64})/data$")
archive_digests = set()
if os.path.isdir(archive_dir):
    for name in sorted(os.listdir(archive_dir)):
        if not name.endswith(".tar"):
            continue
        with tarfile.open(os.path.join(archive_dir, name)) as tf:
            for member in tf.getnames():
                m = blob_re.search(member)
                if m:
                    archive_digests.add(m.group(1))

gap_repos = []
for repo_dir in repo_dirs:
    repo_name = os.path.relpath(repo_dir, repos_root)
    required = referenced_digests(repo_dir)
    if required - archive_digests:
        gap_repos.append(repo_name)

print(json.dumps({"gap_repos": sorted(gap_repos)}))
