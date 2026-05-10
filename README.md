# rinha-backend-26-v2 — submission branch

Submission branch for the Rinha de Backend 2026 evaluator.

Source code, history, and design docs live on `main`:
https://github.com/steixeira93/rinha-backend-26-v2/tree/main

**V2.2 stack:**
- Zig 0.16 (cross-compiled to x86_64-linux-musl)
- `cmd/lb` — custom io_uring TCP-to-unix-socket round-robin LB (replaces HAProxy)
- `cmd/api` — io_uring HTTP server (Linux), blocking fallback (macOS), mmap'd index
- `cmd/builder` — one-shot index builder, gzipped JSON array → binary V2 format
- Two-stage search: 14-bit Hamming popcount → top-32 → int8 L2 rerank → top-5

**Local benchmark (200 reqs through LB):**
- p50 1.8 ms, p99 4.8 ms (vs V1 baseline 38 ms p99)
- Memory total ~40 MB sustained
- Approval agreement vs int8 brute force ground truth: 98%

To run locally:

```sh
docker compose build
docker compose up -d
curl http://localhost:9999/ready
curl http://localhost:9999/fraud-score -X POST -H 'Content-Type: application/json' -d @data/sample.json
docker compose down -v
```
