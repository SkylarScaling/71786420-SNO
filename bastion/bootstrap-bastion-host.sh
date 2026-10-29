#!/usr/bin/env bash
set -euo pipefail

# Minimal, non-Ansible bootstrap for a brand-new, fully disconnected bastion — same
# "do the least possible in bash to get Ansible running" philosophy as
# ../staging/bootstrap-staging-host.sh, adapted for a host with NO internet route at
# all (unlike staging). Bare-metal bastions are expected to already have Ansible and
# the kubernetes/openshift Python modules baked into their base image/build — see
# roles/baremetal/baremetal_prepare_bastion's README — so this script is normally only
# needed on the AWS test loop's freshly provisioned, blank EC2 bastion. Installs
# ansible-core and python3-pip from the RPMs stage_mirror_content already downloaded
# and package_bastion_bundle already bundled into ../mirror-installers/bastion-rpms/,
# then the kubernetes/openshift Python modules from the matching
# ../mirror-installers/bastion-wheelhouse/ — both entirely offline (--disablerepo/
# --no-index), since dnf/pip's normal remote repos are unreachable here. Run this once,
# before any ansible-playbook invocation on this host.
#
# Usage: ./bootstrap-bastion-host.sh (run from inside this bastion/ directory, after
# extracting the bundle staging handed you)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLERS_DIR="${SCRIPT_DIR}/../mirror-installers"

if [ ! -d "${INSTALLERS_DIR}/bastion-rpms" ]; then
  echo "No ${INSTALLERS_DIR}/bastion-rpms found — is this script still inside the extracted bundle's bastion/ directory?" >&2
  exit 1
fi

# --disablerepo='*' matches configure_bastion_services' own install step: this host
# has no internet route, so dnf must never attempt a network repo lookup. The RPMs
# here already include their full dependency closure (dnsmasq/httpd too, not just
# ansible-core/python3-pip — see stage_mirror_content's bastion_packages) —
# installing all of it now is harmless; configure_bastion_services' own install of
# the same RPMs later is just a no-op.
sudo dnf install -y --disablerepo='*' "${INSTALLERS_DIR}"/bastion-rpms/*.rpm

# kubernetes.core.k8s* modules (used by every roles/ocp/* role) need these importable
# by whatever Python interpreter Ansible uses here — not RPM-packaged, so pip (not
# dnf) is how they'd normally install, except there's no route to PyPI either.
# --no-index forces pip to use only the bundled wheelhouse, never reaching out. Package
# names are duplicated here rather than read from the repo root's
# requirements-bastion.txt (the source of truth stage_mirror_content's pip download
# step uses) — that file lives outside bastion/, so it isn't part of what actually
# gets bundled onto this host.
python3 -m pip install --user --no-index --find-links "${INSTALLERS_DIR}/bastion-wheelhouse" kubernetes openshift

# Same PATH gap as staging's bootstrap script, same fix: this shell can't inherit an
# export from the script that just ran, but future logins can via ~/.bashrc.
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qxF "${PATH_LINE}" "${HOME}/.bashrc" 2>/dev/null; then
  echo "${PATH_LINE}" >> "${HOME}/.bashrc"
fi

cat <<EOF

Bootstrap complete. ~/.local/bin has been added to PATH for future logins, but this
shell doesn't have it yet (a script can't export into the shell that ran it) — so for
this session:
  export PATH="\${HOME}/.local/bin:\${PATH}"
  cd ${SCRIPT_DIR}/playbooks
  ansible-playbook provision-sno-aws.yaml -i ../inventory/inventory.yaml

(Bare metal doesn't need this script at all — its bastion is expected to already
have ansible-core and the kubernetes/openshift Python modules pre-installed.)
EOF
