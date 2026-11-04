#!/usr/bin/env bash
set -euo pipefail

# Minimal, non-Ansible bootstrap for a brand-new staging host that has nothing on
# it yet — a freshly imaged bare-metal staging machine, or a freshly created AWS
# EC2 instance (aws-infra/playbooks/provision-hosts.yaml copies this script there
# automatically). Does the least possible by hand: installs Python/pip/git via the
# system package manager, clones this repo, and installs this repo's own Python
# dependencies (unavoidable in bash — Ansible itself is one of them, so nothing
# past that point can be an Ansible task). Everything else — Galaxy collections,
# further host prep, mirroring, packaging, cluster creation — happens in Ansible,
# starting with staging/playbooks/prepare-staging-host.yaml.
#
# Usage: ./bootstrap-staging-host.sh <git-repo-url> [branch] [clone-dir]

REPO_URL="${1:?Usage: $0 <git-repo-url> [branch] [clone-dir]}"
BRANCH="${2:-main}"
CLONE_DIR="${3:-$HOME/sno-automation}"

if command -v dnf >/dev/null 2>&1; then
  PKG_MGR=dnf
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR=yum
else
  echo "No dnf/yum found on this host — install python3, python3-pip, and git manually, then re-run." >&2
  exit 1
fi

sudo "${PKG_MGR}" install -y python3 python3-pip git

git clone --branch "${BRANCH}" "${REPO_URL}" "${CLONE_DIR}"

python3 -m pip install --user --upgrade pip
# Installs ansible itself, among this repo's other Python deps (kubernetes,
# openshift, boto3, botocore) — see requirements.txt. Can't be an Ansible task:
# Ansible doesn't exist on this host until this line runs.
python3 -m pip install --user -r "${CLONE_DIR}/requirements.txt"

# --user installs (ansible, boto3, etc. above) land in ~/.local/bin, which isn't on
# PATH by default. A script can't export into the parent shell that invoked it, so
# the current session still needs the manual `export` printed below — but we can at
# least make every future login shell on this host already have it, so this is a
# one-time nuisance per host, not per session.
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qxF "${PATH_LINE}" "${HOME}/.bashrc" 2>/dev/null; then
  echo "${PATH_LINE}" >> "${HOME}/.bashrc"
fi

# AWS only: aws-infra/playbooks/provision-hosts.yaml already scp'd a fully-rendered
# inventory here (it needs VPC/subnet facts that only exist after the VPC is
# created, so it couldn't be baked into this repo checkout before now) — move it
# into place now that the clone exists. Bare metal has no such file; this is a
# no-op there.
if [ -f "${HOME}/sno-staging-inventory.yaml" ]; then
  mkdir -p "${CLONE_DIR}/staging/inventory"
  mv "${HOME}/sno-staging-inventory.yaml" "${CLONE_DIR}/staging/inventory/inventory.yaml"
  echo "Moved staged inventory into ${CLONE_DIR}/staging/inventory/inventory.yaml"
fi

cat <<EOF

Bootstrap complete. ~/.local/bin has been added to PATH for future logins, but this
shell doesn't have it yet (a script can't export into the shell that ran it) — so for
this session:
  export PATH="\${HOME}/.local/bin:\${PATH}"
  cd ${CLONE_DIR}/staging/playbooks
  ansible-playbook prepare-staging-host.yaml -i ../inventory/inventory.yaml

(Bare metal only: copy/symlink ../inventory/inventory-baremetal.yaml to
../inventory/inventory.yaml first — AWS already has one waiting, moved above.)
EOF
