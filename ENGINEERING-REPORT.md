# CERTSA-45: ARC on Bare Metal — Engineering Report

**Date**: September 16, 2026
**Author**: Gary Harden
**Cluster**: kni-qe-64 (hp-e910 bare metal, RDU2)
**Status**: Stage environment deployed, stress-tested, manifests for reproducible deployment

---

## 1. What We Did

### Objective
Deploy GitHub Actions Runner Controller (ARC) on a production-representative bare metal OpenShift cluster and determine the maximum concurrent chart-verifier capacity for the Helm Certification pipeline.

### Cluster
| Property | Value |
|---|---|
| Hostname | hp-e910-{01,02,03}.kni-qe-64.ecosys.eng.rdu2.dc.redhat.com |
| API | `https://api.kni-qe-64.ecosys.eng.rdu2.dc.redhat.com:6443` |
| OCP Version | 4.22.9 |
| Topology | 3-node compact (master+worker) |
| CPU | 47.5 cores per node / 142.5 total |
| RAM | 95 GiB per node / 285 GiB total |
| Idle utilization | 2-6% CPU, 28-39% memory |
| Location | RDU2 datacenter, directly reachable (no SSH jump) |
| Prior workloads | ACM, Hypershift, Assisted Installer, ZTP (all idle) |

### What Was Deployed

1. **ARC Controller** (v0.14.2) in namespace `helm-cert-system`
   - 1 controller pod (Deployment)
   - 1 listener pod (long-polls GitHub for pending jobs)

2. **Runner Scale Set** (`helm-cert-bm`) in namespace `helm-cert-runners`
   - Ephemeral runner pods: 0 at idle, scales to N on demand
   - maxRunners: 80
   - Runner image: `quay.io/gharden/helm-cert-arc-runner:v1.0.0`
   - Each runner pod runs one GitHub Actions job, then terminates

3. **Supporting resources** (all in the two namespaces above, plus 3 cluster-scoped RBAC objects)
   - See `manifests/` directory for complete list

### Tests Executed

| Test | Concurrency | Result | Wall Time | Run |
|---|---|---|---|---|
| Scale test (smoke) | 5 | 5/5 PASS | 79s | [35129768216](https://github.com/hardengl/helm-cert-bridge-poc/actions/runs/35129768216) |
| Scale test | 40 | 40/40 PASS | 53s | [35129963634](https://github.com/hardengl/helm-cert-bridge-poc/actions/runs/35129963634) |
| Scale test | 60 | 60/60 PASS | 69s | [35130184922](https://github.com/hardengl/helm-cert-bridge-poc/actions/runs/35130184922) |
| Scale test (max) | 80 | 80/80 PASS | 109s | [35130448035](https://github.com/hardengl/helm-cert-bridge-poc/actions/runs/35130448035) |
| Manifest redeploy smoke | 5 | 5/5 PASS | ~79s | [35133796132](https://github.com/hardengl/helm-cert-bridge-poc/actions/runs/35133796132) |
| Full pipeline E2E (5-job) | 1 | 5/5 jobs PASS | ~2min | [35134087716](https://github.com/hardengl/helm-cert-bridge-poc/actions/runs/35134087716) |

### Teardown + Redeploy Verified
We tore down the entire ARC installation (Helm releases, namespaces, RBAC), confirmed a clean cluster state, then redeployed purely from the `manifests/` folder. Runners passed the smoke test on the fresh deployment. This proves the manifests are self-contained and reproducible.

---

## 2. How We Did It

### Deployment Procedure

All resources are in `manifests/` — deploy with:

```bash
# Static K8s resources
oc apply -f manifests/01-namespaces.yaml    # Namespaces with PSA labels
oc apply -f manifests/02-rbac.yaml          # ClusterRole + ClusterRoleBinding
oc apply -f manifests/03-scc.yaml           # anyuid SCC for runner pods
oc apply -f manifests/04-runner-sa.yaml     # Service account for oc login

# ARC controller + runner scale set via Helm
export GITHUB_TOKEN="ghp_..."
export QUAY_USER="gharden"
export QUAY_TOKEN="..."
bash manifests/05-install-helm.sh
```

See `manifests/README.md` for full details and configuration options.

### OpenShift-Specific Fixes Required

These are **not** in the upstream ARC docs and were discovered through debugging:

1. **PSA namespace labels** (`enforce: privileged`): OCP 4.22 enforces Pod Security Admission. Runner pods run as UID 1001 (GitHub Actions runner user), which violates `restricted`. Without the label, pods are rejected at admission.

2. **SCC grants** (`anyuid`): OCP's legacy SCC admission controller runs alongside PSA. Even with PSA labels, the SCC controller rejects pods where `runAsUser` falls outside the namespace-allocated UID range. Fix: grant `anyuid` SCC to the runner namespace SA group.

3. **ClusterRoleBinding for controller**: The ARC controller runs in `helm-cert-system` but needs to manage secrets, pods, roles, and CRDs in `helm-cert-runners`. OCP doesn't grant this by default. Without it, the controller logs `failed to get kubernetes secret` and the listener never starts.

4. **Unique runner scale set name**: If another ARC installation exists for the same GitHub repo (e.g., on a different cluster), both try to register the same session name. GitHub responds with `409 Conflict`. Fix: set `runnerScaleSetName` to a unique value per cluster.

5. **Zsh bracket quoting**: Helm `--set` with array indexes (`containers[0].name=runner`) triggers zsh globbing. Must use single quotes around the entire argument.

### Workflow Changes vs Production

The only change to the production `build.yml` is:

| What | Production | ARC |
|---|---|---|
| `runs-on` for chart-verifier job | `ubuntu-latest` (GH-hosted) | `helm-cert-bm` |
| `mikefarah/yq@v4` | Docker container action | Binary install (`curl` + `$GITHUB_PATH`) |
| OC login | Not applicable (GH-hosted) | `redhat-actions/oc-login@v1` |

All other actions (checkout, setup-python, setup-go, upload-artifact, download-artifact, openshift-tools-installer, chart-verifier) work identically on ARC runners.

---

## 3. Known Limits

### Hardware Limits (Observed)

| Metric | At 80 concurrent | Notes |
|---|---|---|
| Peak CPU (single node) | 89% | All pods scheduled to hp-e910-02 (scheduler imbalance) |
| Peak CPU (other nodes) | 5-10% | Barely used |
| Peak memory | 35% max | Memory is not the bottleneck |
| Wall time | 109s | Includes GH overhead (matrix generation, summary job) |

### Capacity Estimate
- **Current limit**: 80 concurrent (set by `maxRunners`, not hardware)
- **Observed ceiling**: ~80 on a single node before CPU saturation
- **With pod spreading** (topology spread constraints or anti-affinity): estimated 120-150 concurrent across all 3 nodes
- **Memory**: not a constraint at any tested level

### Software Limits

| Limit | Impact | Workaround |
|---|---|---|
| **Docker container actions** don't work on ARC | `mikefarah/yq@v4` fails (no Docker daemon in Kubernetes mode) | Install `yq` binary instead (2-line swap) |
| **ARC is "public preview"** per GitHub | No SLA, potential breaking changes | Monitor GitHub release notes; ARC v0.14.x is stable in practice |
| **Runner image is 1.86 GB** | First pod startup ~42s (image pull); subsequent pods instant (cached) | Pre-pull image on all nodes, or accept cold-start latency |
| **Scheduler imbalance** | All pods land on one node | Add topology spread constraints to runner pod template |
| **SA token TTL** | 720h (30 days) max per `oc create token` | Rotate `OC_TOKEN_BM` GitHub secret monthly, or use a bound token approach |
| **No DIND/DinD** | Can't run Docker-in-Docker inside runner pods | Only affects Docker container actions; all Node.js/composite actions work |
| **GitHub concurrent job limit** | GitHub may throttle >256 concurrent jobs per repo | Not hit in testing; production volume (~40 PRs/day) is well under this |

### What We Did NOT Test

| Gap | Why | Risk |
|---|---|---|
| Actual Behave E2E test suite | Requires fork of `openshift-helm-charts/development` with ARC-modified build.yml + repo secrets | Medium — pipeline structure is validated, but the ~50-80 PR nightly burst hasn't been tested with real chart content |
| Multi-day sustained load | Single-session testing only | Low — scale-to-zero means no resource leak; ARC is stateless |
| Node failure / pod eviction during run | Would require `oc debug node` + kill | Low — ephemeral pods; GitHub retries failed jobs |
| ARC controller upgrade (0.14.x → future) | No upgrade path tested | Medium — Helm upgrade should work, but listener session may need recreation |
| Image registry outage (Quay down) | Runner image cached on nodes after first pull | Low — cached image survives registry outage |
| GitHub token rotation under load | Token was static for all tests | Low — ARC handles token refresh internally |
| Disconnected / air-gapped deployment | Cluster has internet access | High — would need mirrored images, no GitHub long-poll possible (fundamental ARC limitation) |

---

## 4. What's Left

### Required Before Production

1. **Run actual Behave E2E suite** against a fork of `openshift-helm-charts/development` with ARC-modified `build.yml`. This is the definitive validation that the nightly ~50-80 PR burst works.

2. **Move images to org Quay** (`quay.io/redhat-certification/helm-cert-arc-runner` or similar). Currently on personal `quay.io/gharden/`.

3. **Install GitHub App** on `openshift-helm-charts/charts` (requires org admin). Currently using a PAT.

4. **Add pod topology spread constraints** to distribute runners across all 3 nodes instead of piling onto one. This would roughly triple effective capacity.

5. **SA token rotation automation** — either a CronJob that refreshes `OC_TOKEN_BM` or use a Kubernetes-native auth approach.

6. **Monitoring/alerting** — PrometheusRule for ARC controller health, runner queue depth, pod failure rate.

### Nice-to-Have

- Pre-pull runner image to all nodes (DaemonSet with init container)
- Resource requests/limits on runner pods for better scheduling
- Network policy to restrict runner pod egress
- Dedicated node pool for runners (taint/toleration) if sharing the cluster with other workloads

---

## 5. Repository Structure

```
hardengl/helm-cert-bridge-poc/
├── manifests/                          # ← NEW: Reproducible deployment
│   ├── README.md                       # Full deployment guide
│   ├── 01-namespaces.yaml              # Namespaces with PSA labels
│   ├── 02-rbac.yaml                    # ClusterRole + ClusterRoleBinding
│   ├── 03-scc.yaml                     # anyuid SCC grant
│   ├── 04-runner-sa.yaml              # Runner service account
│   ├── 05-install-helm.sh             # Helm install script (configurable)
│   └── teardown.sh                     # Complete cleanup
├── .github/workflows/
│   ├── full-pipeline-e2e.yml           # 5-job production mirror (kni-qe-64)
│   ├── scale-test-bm.yml              # Stress test (5-80 concurrent, kni-qe-64)
│   ├── scale-test.yml                  # Original stress test (ocp-edge-0)
│   ├── arc-node-composite-test.yml     # Action compatibility tests
│   ├── verify-yq-workaround.yml        # yq binary workaround validation
│   └── ...                             # Other test workflows
└── ENGINEERING-REPORT.md               # ← This document
```

---

## 6. GitHub Actions Secrets Required

| Secret | Purpose | How to Generate |
|---|---|---|
| `GITHUB_TOKEN` | ARC registration + API access | PAT with `repo` scope (or GitHub App) |
| `OC_TOKEN_BM` | Runner `oc login` to kni-qe-64 | `oc create token helm-cert-runner -n helm-cert-runners --duration=720h` |
| `QUAY_TOKEN` | Pull private runner image | Quay.io robot account or user token |

---

## 7. Comparison: ocp-edge-0 vs kni-qe-64

| Metric | ocp-edge-0 (previous) | kni-qe-64 (current) |
|---|---|---|
| OCP version | 4.19.22 | 4.22.9 |
| Topology | 3-node compact (VMs) | 3-node compact (bare metal) |
| CPU per node | 17.5 cores | 47.5 cores |
| RAM per node | 38 GiB | 95 GiB |
| Max tested concurrent | 20 | 80 |
| Max concurrent result | 30s wall, 100% pass | 109s wall, 100% pass |
| Peak CPU at max | 58% (one node) | 89% (one node) |
| Idle CPU | 3-5% | 2-6% |

---

## 8. Quick Reference

```bash
# Deploy ARC from scratch
oc apply -f manifests/01-namespaces.yaml -f manifests/02-rbac.yaml \
  -f manifests/03-scc.yaml -f manifests/04-runner-sa.yaml
GITHUB_TOKEN="..." QUAY_USER="..." QUAY_TOKEN="..." bash manifests/05-install-helm.sh

# Check status
oc get pods -n helm-cert-system                    # Controller + listener
oc get autoscalingrunnersets -n helm-cert-runners   # Scale set config
oc get pods -n helm-cert-runners                    # Active runners (0 at idle)
oc adm top nodes                                    # Node resource usage

# Teardown
bash manifests/teardown.sh

# Rotate OC_TOKEN_BM
oc create token helm-cert-runner -n helm-cert-runners --duration=720h
# → Update GitHub secret OC_TOKEN_BM with new value
```
