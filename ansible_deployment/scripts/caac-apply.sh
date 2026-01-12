#!/usr/bin/env bash
set -euo pipefail

# Apply AAP Controller/EDA objects via infra.aap_configuration using env-driven inputs.
# This script sources the REPO ROOT .env so all variables are centralized.
#
# Usage:
#   ./ansible_deployment/scripts/caac-apply.sh
#
# Required env (from top-level .env):
#   AAP_HOSTNAME, AAP_TOKEN, AAP_VALIDATE_CERTS (true|false), AAP_ORG
#   SN_INSTANCE, SN_USERNAME, SN_PASSWORD
# Optional:
#   OCP_API_HOST, OCP_API_TOKEN, OCP_VERIFY_SSL (true|false), OCP_SSL_CA_CERT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PLAYBOOK="${REPO_ROOT}/ansible_deployment/caac/apply.yml"

# Load top-level .env if present
if [[ -f "${REPO_ROOT}/.env" ]]; then
  echo "Loading environment from ${REPO_ROOT}/.env"
  # shellcheck disable=SC2046
  export $(grep -v '^#' "${REPO_ROOT}/.env" | xargs -I{} echo {})
fi

# Basic sanity: ansible-playbook present
if ! command -v ansible-playbook >/dev/null 2>&1; then
  echo "Error: ansible-playbook not found. Install Ansible first."
  exit 1
fi

# Run the playbook (uses lookup('env', ...) inside apply.yml)
ansible-playbook "${PLAYBOOK}" "$@"


