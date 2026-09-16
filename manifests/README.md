# ARC Deployment Manifests for OpenShift

Deploy GitHub Actions Runner Controller (ARC) on OpenShift 4.19+ for Helm Certification chart verification.

## Quick Start

```bash
# 1. Log into OpenShift as cluster-admin
oc login -s https://api.<cluster>:6443 -u kubeadmin

# 2. Apply static manifests (namespaces, RBAC, SCC, SA)
oc apply -f manifests/01-namespaces.yaml
oc apply -f manifests/02-rbac.yaml
oc apply -f manifests/03-scc.yaml
oc apply -f manifests/04-runner-sa.yaml

# 3. Install ARC via Helm (controller + runner scale set)
export GITHUB_TOKEN="ghp_..."
export QUAY_USER="gharden"
export QUAY_TOKEN="..."
./manifests/05-install-helm.sh
```

Or as a single command:

```bash
export GITHUB_TOKEN="ghp_..." QUAY_USER="gharden" QUAY_TOKEN="..."
oc apply -f manifests/01-namespaces.yaml -f manifests/02-rbac.yaml -f manifests/03-scc.yaml -f manifests/04-runner-sa.yaml && ./manifests/05-install-helm.sh
```

## Files

| File | Type | Purpose |
|---|---|---|
| `01-namespaces.yaml` | `oc apply` | Creates `helm-cert-system` + `helm-cert-runners` with PSA labels |
| `02-rbac.yaml` | `oc apply` | ClusterRole + ClusterRoleBinding for ARC controller |
| `03-scc.yaml` | `oc apply` | Grants `anyuid` SCC to runner namespace service accounts |
| `04-runner-sa.yaml` | `oc apply` | Service account for runner `oc login` (cluster-admin) |
| `05-install-helm.sh` | Script | Installs ARC controller + runner scale set via Helm |
| `teardown.sh` | Script | Complete removal of all ARC resources |

## Configuration

Override via environment variables before running `05-install-helm.sh`:

| Variable | Default | Description |
|---|---|---|
| `GITHUB_TOKEN` | (required) | GitHub PAT with `repo` scope |
| `GITHUB_REPO` | `https://github.com/hardengl/helm-cert-bridge-poc` | Target repository |
| `RUNNER_IMAGE` | `quay.io/gharden/helm-cert-arc-runner:v1.0.0` | Runner container image |
| `RUNNER_LABEL` | `helm-cert-bm` | Label for `runs-on:` in workflows |
| `MAX_RUNNERS` | `80` | Maximum concurrent runner pods |
| `ARC_VERSION` | `0.14.2` | ARC Helm chart version |
| `QUAY_USER` | (optional) | Quay.io username for private images |
| `QUAY_TOKEN` | (optional) | Quay.io token for private images |

## Post-Install

After running the install script, it outputs a service account token. Add it as a GitHub Actions secret:

1. Copy the token from the script output
2. Go to repo Settings → Secrets and variables → Actions
3. Create secret `OC_TOKEN_BM` with the token value

## Teardown

```bash
./manifests/teardown.sh
```

## Architecture

```
helm-cert-system (namespace)
├── arc-system-gha-rs-controller  (Deployment, 1 pod)
│   └── Watches for workflow_job events from GitHub
└── helm-cert-bm-listener         (Pod, 1 pod)
    └── Long-polls GitHub for pending jobs

helm-cert-runners (namespace)
└── helm-cert-bm-*-runner-*       (Ephemeral pods, 0 at idle → N on demand)
    └── Each runs one GitHub Actions job, then terminates
```

## OpenShift-Specific Notes

- **PSA labels** (`01-namespaces.yaml`): Runner namespace needs `enforce: privileged` because runner pods run as UID 1001
- **SCC grants** (`03-scc.yaml`): Declarative `anyuid` grant via ClusterRoleBinding to SA group
- **RBAC** (`02-rbac.yaml`): Controller needs cross-namespace access that OCP doesn't grant by default
- **Runner scale set name** must be unique per GitHub repo — two ARC installs targeting the same repo with the same name causes a 409 session conflict

## Tested On

| Cluster | OCP | Topology | Max Concurrent | Result |
|---|---|---|---|---|
| ocp-edge-0 | 4.19.22 | 3-node compact (17.5 CPU/node) | 20 | 100% pass |
| kni-qe-64 | 4.22.9 | 3-node compact BM (47.5 CPU/node) | 80 | 100% pass |
