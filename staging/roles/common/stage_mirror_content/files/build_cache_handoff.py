#!/usr/bin/env python3
"""Hardlink the minimal oc-mirror cache subset a list of repos need into a
handoff directory laid out exactly like oc-mirror's own --cache-dir, for
package_bastion_bundle/unpack_bastion_bundle to carry to the bastion and merge
into deploy_mirror_registry's --cache-dir before the disk-to-mirror push. See
this role's README ("Known oc-mirror --v2 defect...") for why this exists.

Usage: build_cache_handoff.py <registry_v2_dir> <handoff_v2_dir> <repo_name> [<repo_name> ...]
Each <repo_name> is a repository path relative to repositories/, e.g.
"openshift/release" or "odf4/odf-rhel9-operator".

Prints {"linked": N, "unrecoverable": {"<repo>": ["<digest>", ...], ...}} to
stdout — any entry under "unrecoverable" means that repo's manifest references
a blob this cache never had either, so no amount of re-bundling can patch it;
only a fresh oc-mirror run against the real upstream can recover it.
"""
import json
import os
import shutil
import sys

registry_v2_dir, handoff_v2_dir = sys.argv[1:3]
repo_names = sys.argv[3:]

linked = 0
unrecoverable = {}

for repo_name in repo_names:
    repo_src = os.path.join(registry_v2_dir, "repositories", repo_name)
    revisions_dir = os.path.join(repo_src, "_manifests/revisions/sha256")
    if not os.path.isdir(revisions_dir):
        continue

    digests = set()
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

    for digest in digests:
        src = os.path.join(registry_v2_dir, "blobs/sha256", digest[:2], digest, "data")
        if not os.path.exists(src):
            unrecoverable.setdefault(repo_name, []).append(digest)
            continue
        dst_dir = os.path.join(handoff_v2_dir, "blobs/sha256", digest[:2], digest)
        os.makedirs(dst_dir, exist_ok=True)
        dst = os.path.join(dst_dir, "data")
        if os.path.exists(dst):
            continue
        try:
            os.link(src, dst)
        except OSError:
            shutil.copy2(src, dst)
        linked += 1

    repo_dst = os.path.join(handoff_v2_dir, "repositories", repo_name)
    if os.path.exists(repo_dst):
        shutil.rmtree(repo_dst)
    shutil.copytree(repo_src, repo_dst)

print(json.dumps({"linked": linked, "unrecoverable": unrecoverable}))
