CERTSA-45: ARC on Bare Metal — Executive Summary

**Verdict: Proceed with migration.** GitHub Actions Runner Controller (ARC) on a bare-metal internal OCP cluster is a validated, production-ready replacement for the AWS-hosted runners currently used by the Helm chart certification pipeline. Migration requires 4 targeted, non-breaking changes to one workflow file.

**Test environment**: kni-qe-64, 3-node compact OCP 4.18, 142.5 CPU / 285 GiB total. ARC controller v0.14.2, two runner scale sets (PoC + dev-fork), all removable via `helm uninstall`. No cluster-level resources were modified; nothing destructive was done.

WHAT WAS VALIDATED

1. Production pipeline compatibility — Forked the real `openshift-helm-charts/development` repo and ran its actual `build.yml` on ARC. Only 4 code changes were needed: point the chart-verifier job at the ARC runner label, swap the one Docker-container action (`mikefarah/yq`) for a binary install (Docker actions are the only action type ARC can't run — everything else, including Node.js and composite actions, worked unmodified), and switch `wget`→`curl` for the oc CLI install. Confirmed working: full PR pipeline (checkout → chart-verifier → PR comment → merge → release), artifact passing between GitHub-hosted and ARC runners, and a 5-concurrent-PR burst test (each got its own runner, all completed, scale-to-zero confirmed).

2. Full functional correctness — Ran the project's actual Behave E2E suite (19 feature files covering chart install, certification, signing, merge, and release flows) against the ARC-backed fork. **Result: 19/19 pass (100%)**. An initial run showed 7 failures; root-caused to a GitHub repo permission setting unrelated to ARC (`can_approve_pull_request_reviews`, needed because the pipeline's bot both opens and approves its own PRs) — fixed with a one-line API call, then all 19 passed.

3. Raw infrastructure throughput — Ran up to 100 concurrent chart-verifier jobs using generated minimal test charts. **100% pass at every level (5/40/60/80/100 concurrent)**, 110s wall time at 100 concurrent, peak CPU 70% on one node (headroom for an estimated 150–200+ with better pod spread). This measures infra plumbing, not chart realism.

4. Real customer chart load — To close the realism gap, pulled 25 actual, diverse partner/Red Hat charts straight from the production `openshift-helm-charts/charts` repo (including our own `redhat-developer-hub` chart, plus AppsCode, Kyverno, Solace, EAP, and others — 4KB–560KB, real images/CRDs/webhooks) and ran all 25 through `chart-verifier` concurrently. **Zero infrastructure failures.** 134/160 individual checks passed; every failure traced to a real, explainable chart-content issue (e.g. a chart's BuildConfig needing a user-supplied Git URL) — not an ARC or infra problem. Same failures would occur on GitHub-hosted runners.

WHAT CHANGES FOR PRODUCTION MIGRATION

- `build.yml`: point chart-verifier job `runs-on` at the ARC runner label
- `build.yml`: replace the 2 `mikefarah/yq` Docker-action calls with a binary yq install
- `build.yml`: change `wget`→`curl` in the oc-install step
- Deploy ARC controller + runner scale set on the target cluster
- Add `API_SERVER` / `CLUSTER_TOKEN` secrets pointing at the ARC cluster
- If the target org uses the same bot-approves-bot-PR pattern, enable "Allow GitHub Actions to create and approve pull requests" in repo settings

RECOMMENDATION

Proceed with migration. Changes are minimal, well-understood, and can be rolled out incrementally (chart-verifier job first). All findings, run links, and full technical detail (per-chart results, action compatibility matrix, root-cause writeups) are in the full engineering report: https://github.com/hardengl/helm-cert-bridge-poc/blob/main/ENGINEERING-REPORT.md
