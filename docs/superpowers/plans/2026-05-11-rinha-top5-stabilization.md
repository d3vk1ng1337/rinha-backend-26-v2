# Rinha Top5 Stabilization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:systematic-debugging for each failed official run, then superpowers:test-driven-development for each behavior change. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce official `http_errors` to zero first, then improve p99 and detection quality until the Zig V2 submission reaches top5-level partial results.

**Architecture:** Work in small, reversible batches. First stabilize the request path and LB/API concurrency under the official k6 arrival-rate test. Only after `http_errors` are under the 15% scoring cutoff do ANN/index experiments become eligible.

**Tech Stack:** Zig 0.16, io_uring on linux/amd64, Docker Compose, HAProxy/Zig LB, GitHub Actions/GHCR, official Rinha issue runner.

---

## Current Evidence

- Official Zig V2 baseline with Zig LB: issue #3271, 5121 valid responses, 48803 HTTP errors, p99 2001.85ms, final score -6000.
- Official Zig V2 HAProxy+warmup run: issue #3283, 977 valid responses, 48009 HTTP errors, p99 2001.80ms, final score -6000.
- Official Go HNSW reference from the same author: issue #3292, 0 HTTP errors, p99 1.46ms, final score 5836.22.
- Local unit baseline: `zig build test` passes.
- Submission compose syntax baseline: `docker compose -f deploy/docker-compose.submission.yml config --quiet` passes.

## File Structure

- Modify: `cmd/api/main.zig`
  - Make worker count configurable.
  - Add safer fallback or diagnostics for io_uring setup.
  - Preserve default behavior unless compose opts into a new worker count.
- Modify: `cmd/lb/main.zig`
  - Fix stream partial writes.
  - Optionally add minimal health/diagnostic counters only if needed.
- Modify: `src/index_format.zig`
  - Add fixed-width vector accessor for the 14-dim hot path.
- Modify: `src/search.zig`
  - Use fixed-width accessor in rerank.
- Modify: `deploy/docker-compose.submission.yml`
  - Switch between HAProxy and Zig LB experiments.
  - Pin API worker count per official issue.
- Modify: `deploy/docker-compose.yml`
  - Keep development compose aligned when useful, but do not let builder affect submission.
- Modify: `docs/autonomous-log.md`
  - Record each official run, commit, hypothesis, and result.

## Task 1: API Worker Count Control

- [x] Step 1: Add a unit or compile-time-safe test path for parsing worker count arguments.
- [x] Step 2: Make `cmd/api/main.zig` accept optional third arg `num_workers`.
- [x] Step 3: Reject `0` and values above `4` to avoid accidental oversubscription.
- [x] Step 4: Run `zig build test`.
- [x] Step 5: Run `zig build -Doptimize=ReleaseFast test`.
- [ ] Step 6: Commit as `perf(api): allow tuning io_uring worker count`.

## Task 2: Fixed 14-Dim Vector Accessor

- [x] Step 1: Add `Reader.vectorAt14(i) *const [14]i8` in `src/index_format.zig`.
- [x] Step 2: Use it in the rerank loop in `src/search.zig`.
- [x] Step 3: Run `zig build test`.
- [x] Step 4: Run `zig build -Doptimize=ReleaseFast test`.
- [ ] Step 5: Commit as `perf(search): use fixed-width vector accessor in rerank`.

## Task 3: Zig LB Partial Write Correctness

- [x] Step 1: Add state fields for client-to-upstream and upstream-to-client pending writes.
- [x] Step 2: Change write completion handlers to resubmit remaining bytes when `cqe.res < pending_len`.
- [x] Step 3: Keep one outstanding read per direction only after the pending write is fully completed.
- [x] Step 4: Run `zig build -Doptimize=ReleaseFast`.
- [x] Step 5: If local Docker supports the binary, run keep-alive smoke through the LB; otherwise record the local environment limitation.
- [ ] Step 6: Commit as `fix(lb): handle partial stream writes`.

## Task 4: First Official Stabilization Run

- [x] Step 1: Choose the lowest-risk compose variant for the issue: Zig LB corrected, API workers set to `1`.
- [x] Step 2: Update `deploy/docker-compose.submission.yml` and submission branch root compose if needed.
- [x] Step 3: Run `zig build test`, `zig build -Doptimize=ReleaseFast test`, and compose config validation.
- [ ] Step 4: Commit and push `main`.
- [ ] Step 5: Wait for GitHub Actions/GHCR image publish to complete.
- [ ] Step 6: Update/push branch `submission` with the selected compose.
- [ ] Step 7: Open `rinha/test steixeira93-zig-v2`.
- [ ] Step 8: Wait for the official result and record it in `docs/autonomous-log.md`.

## Task 5: Iterate from Official Evidence

- [ ] If `http_errors > 15%`, do not change ANN. Form one new HTTP/runtime hypothesis and repeat Task 4.
- [ ] If `http_errors <= 15%` but p99 is high, tune API worker count, LB CPU share, keep-alive, and mmap warmup.
- [ ] If `http_errors == 0` and p99 is competitive, tune ANN parameters with `run-check` and official issue validation.
- [ ] Stop only after an official result is plausibly top5-level or after three consecutive architecture-level failures require human architectural decision.

## Benchmark Commands

```sh
zig build test
zig build -Doptimize=ReleaseFast test
zig build -Doptimize=ReleaseFast
docker compose -f deploy/docker-compose.submission.yml config --quiet
gh run list --workflow build-and-publish --limit 5
gh issue create --repo zanfranceschi/rinha-de-backend-2026 --title "rinha/test steixeira93-zig-v2" --body "rinha/test steixeira93-zig-v2"
gh issue view <issue-number> --repo zanfranceschi/rinha-de-backend-2026 --comments
```

## Rollback Criteria

- Revert the batch if official `http_errors` increase versus the immediately previous comparable Zig run.
- Revert ANN/search changes if true/false detection errors increase while `http_errors` are already controlled.
- Revert CPU/memory compose changes if the official runner reports resource validation failure.
