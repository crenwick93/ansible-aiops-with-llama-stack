#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}"                      # build context (confluence_ingestor)
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"   # top-level repo (holds .env)

usage() {
  echo "Usage: $0 [--namespace <ns>] [--app-name <name>] [--dockerfile <path>]"
  echo "Defaults read from .env when present. Minimal flow:"
  echo "  oc login ... ; bash $0"
  echo
  echo "Optional:"
  echo "  --follow-logs          Stream Job pod logs when it starts"
}

cleanup_build_artifacts() {
  local ns="$1"
  local bc="$2"
  echo "Cleaning up build artifacts for BuildConfig '${bc}' in namespace '${ns}'..."
  # Prefer label selector for builds
  local builds
  builds="$(oc get builds -n "${ns}" -l "buildconfig=${bc}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  # Fallback: grep by name prefix
  if [[ -z "${builds}" ]]; then
    builds="$(oc get builds -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep "^${bc}-" || true)"
  fi
  if [[ -n "${builds}" ]]; then
    while IFS= read -r b; do
      [[ -z "${b}" ]] && continue
      oc delete cm -n "${ns}" -l "openshift.io/build.name=${b}" --ignore-not-found >/dev/null 2>&1 || true
      oc delete pod -n "${ns}" -l "openshift.io/build.name=${b}" --ignore-not-found >/dev/null 2>&1 || true
    done <<< "${builds}"
  fi
}

if ! command -v oc >/dev/null 2>&1; then
  echo "Error: 'oc' CLI not found. Install and login to your OpenShift cluster." >&2
  exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
  echo "Error: You must be logged into a cluster (oc login)." >&2
  exit 1
fi

# Load .env from repo root if present
set -a  # export sourced variables for downstream oc process/param-file
if [[ -f "${REPO_ROOT}/.env" ]]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/.env"
fi
set +a

NAMESPACE_DEFAULT="$(oc project -q 2>/dev/null || true)"
NAMESPACE="${NAMESPACE:-${NAMESPACE_DEFAULT:-}}"
# Prefer Confluence-specific env vars to avoid collisions with other scripts
APP_NAME="${CONFLUENCE_INGESTOR_APP_NAME:-${CONFLUENCE_APP_NAME:-${APP_NAME:-aiops-conf-ingestion}}}"
DOCKERFILE="${CONFLUENCE_INGESTOR_DOCKERFILE:-${CONFLUENCE_DOCKERFILE:-${DOCKERFILE:-Containerfile}}}"
FOLLOW_LOGS="${FOLLOW_LOGS:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --dockerfile)
      DOCKERFILE="$2"
      shift 2
      ;;
    --follow-logs)
      FOLLOW_LOGS=true
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${NAMESPACE}" ]]; then
  echo "No namespace provided. Use --namespace or set NAMESPACE in .env or via 'oc project'." >&2
  exit 2
fi

echo "Namespace:  ${NAMESPACE}"
echo "App name:   ${APP_NAME}"
echo "Dockerfile: ${DOCKERFILE}"

if ! oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo "Namespace '${NAMESPACE}' not found. Attempting to create..."
  if ! oc new-project "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Could not create namespace '${NAMESPACE}'. Please create it or pick an existing one." >&2
    exit 3
  fi
fi

echo "Applying ImageStream and BuildConfig (binary build)..."
# Render imagestream + buildconfig with provided app name and Dockerfile
oc process -f "${ROOT_DIR}/openshift/build-binary.yaml" \
  --param NAMESPACE="${NAMESPACE}" \
  --param APP_NAME="${APP_NAME}" \
  --param DOCKERFILE="${DOCKERFILE}" \
| oc apply -n "${NAMESPACE}" -f -

# Pre-build cleanup (remove any prior build pods and staging ConfigMaps)
cleanup_build_artifacts "${NAMESPACE}" "${APP_NAME}"

# Wait for BuildConfig to be discoverable
echo "Waiting for BuildConfig '${APP_NAME}' to be ready in namespace '${NAMESPACE}'..."
for i in {1..20}; do
  if oc get bc "${APP_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

echo "Starting binary build from current directory..."
oc start-build "${APP_NAME}" -n "${NAMESPACE}" --from-dir="${ROOT_DIR}" --follow

IMAGE="image-registry.openshift-image-registry.svc:5000/${NAMESPACE}/${APP_NAME}:latest"
echo "Built image: ${IMAGE}"

# Post-build cleanup (remove build pods and staging ConfigMaps)
cleanup_build_artifacts "${NAMESPACE}" "${APP_NAME}"

echo "Applying runtime resources (ConfigMap, Secret, Job) from template with .env..."
# Ensure a fresh Job run each time
oc delete job confluence-ingester -n "${NAMESPACE}" --ignore-not-found || true
oc process -f "${ROOT_DIR}/openshift/template.yaml" \
  --param-file="${REPO_ROOT}/.env" \
  --param NAMESPACE="${NAMESPACE}" \
  --param IMAGE="${IMAGE}" \
  --ignore-unknown-parameters \
| oc apply -n "${NAMESPACE}" -f -

echo "Waiting for Job pod to start in namespace '${NAMESPACE}'..."
POD=""
for i in {1..60}; do
  POD="$(oc get pods -n "${NAMESPACE}" -l job-name=confluence-ingester -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${POD}" ]]; then
    break
  fi
  sleep 2
done

if [[ -n "${POD}" ]]; then
  echo "Job pod detected: ${POD}"
  if [[ "${FOLLOW_LOGS}" == "true" ]]; then
    echo "Streaming logs from pod: ${POD}"
    # It may still be ContainerCreating; oc logs will error until container starts
    # Retry until logs are available or timeout
    for i in {1..60}; do
      if oc logs -n "${NAMESPACE}" "${POD}" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    oc logs -n "${NAMESPACE}" -f "${POD}"
  else
    echo "Tip: View status/logs with:"
    echo "  oc get pods -n ${NAMESPACE} -l job-name=confluence-ingester -o wide"
    echo "  oc logs -n ${NAMESPACE} ${POD} -f"
  fi
else
  echo "Timed out waiting for Job pod. Inspect with:"
  echo "  oc get pods -n ${NAMESPACE} -l job-name=confluence-ingester"
fi


