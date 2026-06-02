# Decisions

## 2026-06-02 - Official docs and local gate baseline

- Read the official `docs/br` API, architecture, detection rules, dataset, scoring, and FAQ docs from `zanfranceschi/rinha-de-backend-2026`. The current invariant remains: two endpoints behind port 9999, LB plus at least two APIs, bridge network, public linux-amd64 images, total resource limits <= 1 CPU and 350 MB, and no lookup by transaction identity.
- Keep the amd64 offline gate as the required proof before submissions or threshold/search changes. The earlier Mac/Zig analysis can drift from the production AVX2 path, so it is useful for exploration only.
- Treat detection accuracy as the primary guardrail. The current pinned native image passed the offline gate over all 54,100 preview entries: FP=0, FN=0, HTTP_errors=0, weighted_E=0.
- Fix the offline gate tooling before further tuning: it previously reported `weighted_E=0` when Python socket calls were sandbox-blocked and all 54,100 requests failed. The official formula is `E = FP + 3*FN + 5*HTTP_errors`.

## 2026-06-02 - Current preview dataset edge-case fix

- Official issue `#7939` passed static validation after removing `seccomp=unconfined`, but scored FP=16/FN=15 on the current 54,100-entry preview dataset.
- Replayed the current official `test/test-data.json` through the amd64 gate and reproduced the issue result exactly: FP=16, FN=15, HTTP_errors=0, weighted_E=61.
- Root cause was not the d3 image rebuild or stale GHCR package: the freshly built `ghcr.io/d3vk1ng1337/rinha-backend-26-v2-native:sha-b7e016e0473b19516cdc5c03dd9cee7ac0e12a10` produced the same FP/FN matrix.
- Built C++/AVX2 diagnostics against the production `index.hpp` and brute-forced the repair divergences against the current official references. All residual repair divergences were edge cases where `requested_at` is in March 2026 but `last_transaction.timestamp` is outside March 2026.
- The bug was `epoch_minutes_fast(requested_at) - epoch_minutes_fast(last_ts)`: the current timestamp used a March-relative fast path while the old last timestamp used Unix-epoch minutes, producing a large negative delta and clamping `minutes_since_last_tx` to zero.
- Fixed the hot-path calculation to use the March-relative subtraction only when both timestamps are in March 2026; otherwise it uses full epoch minutes for both.
- With the time fix, the AVX2 diagnostic over all 54,100 current preview entries reports:
  - `repair_count` (`NPROBE=20`, `REPAIR_MIN=0`, `REPAIR_MAX=5`) = FP=0, FN=0, E=0.
  - baseline fast thresholds still leave FP=5/FN=8, so the next submission config should set `FAST_NPROBE=0` and always use the repaired search until a safe fast-tier policy is recalibrated.

## 2026-06-02 - Official preview with time fix

- Official issue `#7954` ran the `d3vk1ng1337-zig` submission at commit `be55ec7`, pinned to native image `sha-ca8d5dc4b5506e31b9156eb4d2ea50467dac6421@sha256:ef6c5ed79b284539d872eb7e7a6c0f540d7dd273517ebe69913b235c763ac4b9`.
- Result: FP=0, FN=0, HTTP_errors=0, weighted_E=0, detection_score=3000.
- p99 was 1.80857086 ms, p99_score=2742.6644708646986, final_score=5742.664470864698.
- Next target is latency only: preserve the full offline gate at E=0 while reducing p99 below 1 ms. The first likely lever is recalibrating a safe fast-tier policy, because the submission currently forces repaired search for every request (`FAST_NPROBE=0`, `REPAIR_MIN=0`, `REPAIR_MAX=5`).

## 2026-06-02 - Safe fast-tier re-enable after time fix

- Re-enabled `FAST_NPROBE=1` locally against the published timefix image with the previous EXTREME thresholds. The amd64 HTTP gate reported FP=0, FN=2, HTTP_errors=0, weighted_E=6. Both mismatches were fraud transactions returned as `fraud_score=0.4`, i.e. fast-count 2 was the unsafe class.
- Tested a conservative fallback policy by setting `EXTREME2_WORST_THRESHOLD=0`. In the current server logic, that disables the class threshold for fast-count 2 and lets `ADAPTIVE_MIN=2` force the full repaired search only for that class. That closed the gate at FP=0, FN=0, HTTP_errors=0, weighted_E=0.
- Refined the class-2 threshold to avoid unnecessary fallback while preserving E=0. Safe points included 2,600,000, 2,775,000, 2,795,000 and 2,798,000. The first observed failure was 2,799,000 (FP=0, FN=1, E=3); 2,800,000 also failed.
- Decision: publish `FAST_NPROBE=1` with `EXTREME2_WORST_THRESHOLD=2795000`, `NPROBE=20`, `REPAIR_MIN=0`, `REPAIR_MAX=5`. This is an env-only submission change, keeps a small margin below the first failing threshold, and requires no new native image.

## 2026-06-02 - Official fast-tier preview regression

- Official issue `#7967` tested commit `e26a921` with `FAST_NPROBE=1` and `EXTREME2_WORST_THRESHOLD=2795000`.
- Result remained detection-perfect: FP=0, FN=0, HTTP_errors=0, weighted_E=0, detection_score=3000.
- p99 regressed from `#7954`'s 1.80857086 ms to 1.8468878100000004 ms, dropping final_score from 5742.664470864698 to 5733.559485164935.
- Working hypothesis: this fast tier improves common-case work but not p99. The p99 is dominated by fallback requests, and those now pay `fast + full repaired search`, making the tail slightly worse.
- Decision: restore the submission default to the best official state known from `#7954`: `FAST_NPROBE=0`, `EXTREME2_WORST_THRESHOLD=2906420`, `NPROBE=20`, `REPAIR_MIN=0`, `REPAIR_MAX=5`. Future latency work must reduce the full/repaired tail itself rather than adding a pre-pass.

## 2026-06-02 - Full-path NPROBE retune

- Built a temporary amd64 diagnostic (`.tmp/measure_search.cpp`, not committed) that runs `MappedIndex::search()` directly over all 54,100 preview requests and records `SearchStats`.
- With repair universal (`REPAIR_MIN=0`, `REPAIR_MAX=5`), all tested NPROBE values preserved FP=0/FN=0. Direct search timings on linux/amd64 under Docker:
  - `NPROBE=8`: mean 37,475 ns, p95 84,774 ns, p99 123,911 ns.
  - `NPROBE=12`: mean 36,506 ns, p95 81,941 ns, p99 118,659 ns.
  - `NPROBE=16`: mean 36,917 ns, p95 82,523 ns, p99 118,326 ns.
  - `NPROBE=20`: mean 38,773 ns, p95 87,691 ns, p99 128,454 ns.
- Decision: publish `NPROBE=12` as an env-only latency improvement. It reduces mean and p95 versus the current official baseline while keeping p99 essentially tied with the best measured point and does not add a fast pre-pass to fallback requests.
