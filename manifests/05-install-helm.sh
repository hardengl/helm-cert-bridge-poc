#!/usr/bin/env bash
set -euo pipefail

# ARC Helm Install Script for OpenShift
# Prerequisites: oc logged in as cluster-admin, helm v3+, GITHUB_TOKEN set
#
# Usage:
#   export GITHUB_TOKEN="ghp_..."
#   export QUAY_USER="gharden"        # optional, for private runner image
#   export QUAY_TOKEN="..."           # optional, for private runner image
#   ./05-install-helm.sh
#
# To customize:
#   export GITHUB_REPO="https://github.com/org/repo"
#   export RUNNER_IMAGE="quay.io/org/runner:tag"
#   export RUNNER_LABEL="helm-cert-bm"
#   export MAX_RUNNERS=80

GITHUB_REPO="${GITHUB_REPO:-https://github.com/hardengl/helm-cert-bridge-poc}"
RUNNER_IMAGE="${RUNNER_IMAGE:-quay.io/gharden/helm-cert-arc-runner:v1.0.0}"
RUNNER_LABEL="${RUNNER_LABEL:-helm-cert-bm}"
MAX_RUNNERS="${MAX_RUNNERS:-80}"
ARC_VERSION="${ARC_VERSION:-0.14.2}"
CONTROLLER_NS="helm-cert-system"
RUNNERS_NS="helm-cert-runners"

echo "=== ARC Deployment ==="
echo "  Repo:        $GITHUB_REPO"
echo "  Runner:      $RUNNER_IMAGE"
echo "  Label:       $RUNNER_LABEL"
echo "  Max runners: $MAX_RUNNERS"
echo "  ARC version: $ARC_VERSION"
echo ""

# Verify prerequisites
if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged into OpenShift. Run 'oc login' first."
  exit 1
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN not set."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Step 1: Apply static manifests
echo "[1/5] Applying static manifests..."
oc apply -f "$SCRIPT_DIR/01-namespaces.yaml"
oc apply -f "$SCRIPT_DIR/02-rbac.yaml"
oc apply -f "$SCRIPT_DIR/03-scc.yaml"
oc apply -f "$SCRIPT_DIR/04-runner-sa.yaml"

# Step 2: Install ARC controller
echo "[2/5] Installing ARC controller..."
if helm status arc-system -n "$CONTROLLER_NS" &>/dev/null; then
  echo "  Controller already installed, upgrading..."
  helm upgrade arc-system \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
    --namespace "$CONTROLLER_NS" \
    --version "$ARC_VERSION"
else
  helm install arc-system \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
    --namespace "$CONTROLLER_NS" \
    --version "$ARC_VERSION"
fi

# Step 3: Wait for controller
echo "[3/5] Waiting for controller..."
oc rollout status deployment/arc-system-gha-rs-controller -n "$CONTROLLER_NS" --timeout=120s

# Step 4: Create pull secret (if Quay creds provided)
if [ -n "${QUAY_TOKEN:-}" ] && [ -n "${QUAY_USER:-}" ]; then
  echo "[4/5] Creating Quay pull secret..."
  oc create secret docker-registry quay-pull-secret \
    --docker-server=quay.io \
    --docker-username="$QUAY_USER" \
    --docker-password="$QUAY_TOKEN" \
    -n "$RUNNERS_NS" 2>/dev/null || echo "  Pull secret already exists"
  PULL_SECRET_FLAG="--set template.spec.imagePullSecrets[0].name=quay-pull-secret"
else
  echo "[4/5] Skipping pull secret (QUAY_TOKEN not set, assuming public image)"
  PULL_SECRET_FLAG=""
fi

# Step 5: Install runner scale set
echo "[5/5] Installing runner scale set..."
if helm status "$RUNNER_LABEL" -n "$RUNNERS_NS" &>/dev/null; then
  echo "  Runner scale set already installed, upgrading..."
  HELM_CMD="upgrade"
else
  HELM_CMD="install"
fi

# shellcheck disable=SC2086
helm $HELM_CMD "$RUNNER_LABEL" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --namespace "$RUNNERS_NS" \
  --version "$ARC_VERSION" \
  --set "githubConfigUrl=$GITHUB_REPO" \
  --set "githubConfigSecret.github_token=$GITHUB_TOKEN" \
  --set controllerServiceAccount.name=arc-system-gha-rs-controller \
  --set controllerServiceAccount.namespace="$CONTROLLER_NS" \
  --set "runnerScaleSetName=$RUNNER_LABEL" \
  --set minRunners=0 \
  --set "maxRunners=$MAX_RUNNERS" \
  --set 'template.spec.containers[0].name=runner' \
  --set "template.spec.containers[0].image=$RUNNER_IMAGE" \
  --set 'template.spec.containers[0].imagePullPolicy=Always' \
  --set 'template.spec.containers[0].command[0]=/home/runner/run.sh' \
  --set 'template.spec.containers[0].securityContext.runAsUser=1001' \
  --set 'template.spec.containers[0].securityContext.runAsGroup=123' \
  --set 'template.spec.containers[0].securityContext.runAsNonRoot=true' \
  $PULL_SECRET_FLAG

# Grant anyuid to any newly created SAs
for sa in $(oc get sa -n "$RUNNERS_NS" --no-headers -o custom-columns=':metadata.name'); do
  oc adm policy add-scc-to-user anyuid -z "$sa" -n "$RUNNERS_NS" 2>/dev/null
done

# Step 6: Wait for listener
echo ""
echo "Waiting for listener pod..."
sleep 10
oc get pods -n "$CONTROLLER_NS" -l actions.github.com/component=listener --no-headers

# Step 7: Create runner SA token for GitHub secret
echo ""
echo "=== Runner SA Token ==="
echo "Create a GitHub Actions secret named OC_TOKEN_BM with this value:"
oc create token helm-cert-runner -n "$RUNNERS_NS" --duration=720h

echo ""
echo "=== Deployment Complete ==="
echo "Runner label for workflows: runs-on: $RUNNER_LABEL"
oc get autoscalingrunnersets -n "$RUNNERS_NS"
