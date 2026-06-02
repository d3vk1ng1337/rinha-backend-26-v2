# Decisions

## 2026-06-02 - Official docs and local gate baseline

- Read the official `docs/br` API, architecture, detection rules, dataset, scoring, and FAQ docs from `zanfranceschi/rinha-de-backend-2026`. The current invariant remains: two endpoints behind port 9999, LB plus at least two APIs, bridge network, public linux-amd64 images, total resource limits <= 1 CPU and 350 MB, and no lookup by transaction identity.
- Keep the amd64 offline gate as the required proof before submissions or threshold/search changes. The earlier Mac/Zig analysis can drift from the production AVX2 path, so it is useful for exploration only.
- Treat detection accuracy as the primary guardrail. The current pinned native image passed the offline gate over all 54,100 preview entries: FP=0, FN=0, HTTP_errors=0, weighted_E=0.
- Fix the offline gate tooling before further tuning: it previously reported `weighted_E=0` when Python socket calls were sandbox-blocked and all 54,100 requests failed. The official formula is `E = FP + 3*FN + 5*HTTP_errors`.
