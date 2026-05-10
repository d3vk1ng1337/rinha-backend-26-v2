# rinha-backend-26-v2 — submission branch

This is the **submission branch** for the Rinha de Backend 2026 prévia/test runner.
Source code, history, and design docs live on `main`:
https://github.com/steixeira93/rinha-backend-26-v2/tree/main

Stack: Zig 0.16 + HAProxy 2.9 + Docker, int8 brute-force vector search.

To run locally:

```sh
docker compose up -d
curl http://localhost:9999/ready
curl http://localhost:9999/fraud-score -X POST -H 'Content-Type: application/json' -d @data/sample.json
```

V1 baseline: ~p99 38 ms locally on 100-request loop. V2 (binary quant + AVX2 popcount + io_uring) target: p99 ≤ 1 ms.
