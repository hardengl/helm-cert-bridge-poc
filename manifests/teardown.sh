#!/usr/bin/env bash
set -euo pipefail

# Complete teardown of ARC from the cluster. Removes everything.

RUNNER_LABEL="${RUNNER_LABEL:-helm-cert-bm}"

echo "=== Tearing down ARC ==="

echo "[1/4] Removing runner scale set..."
helm uninstall "$RUNNER_LABEL" -n helm-cert-runners 2>/dev/null || echo "  Not found"

echo "[2/4] Removing ARC controller..."
helm uninstall arc-system -n helm-cert-system 2>/dev/null || echo "  Not found"

echo "[3/4] Removing cluster-scoped RBAC..."
oc delete clusterrole arc-controller-full 2>/dev/null || true
oc delete clusterrolebinding arc-controller-full-binding 2>/dev/null || true
oc delete clusterrolebinding helm-cert-runners-anyuid 2>/dev/null || true
oc delete clusterrolebinding helm-cert-runner-cluster-admin 2>/dev/null || true

echo "[4/4] Removing namespaces..."
oc delete namespace helm-cert-runners helm-cert-system --wait=false

echo ""
echo "=== Teardown complete ==="
