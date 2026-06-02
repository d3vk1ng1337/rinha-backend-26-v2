# Offline accuracy gate

Validates EXTREME-threshold (or any env-var) changes against the SAME amd64+AVX2 production C++ image the rig uses. Use it BEFORE any submission to confirm detection_score will stay at 3000.

## Why this exists

The Zig `cmd/dump_worst_dist` analysis runs on arm64 (Mac) and uses different SIMD instructions than the production C++ AVX2 on amd64. Offline-Zig saying "0 divergent queries" did not translate to offline-amd64 — #4110 (commit 32cb819, EXTREME2/3=99999999) showed 144 FP + 158 FN, sinking final_score from 6000 to 4104. This gate runs the exact production binary under orbstack/rosetta and is bit-accurate.

## How it works

`deploy/docker-compose.gate.yml` spins up the production `ghcr.io/steixeira93/rinha-backend-26-v2-native` image (linux/amd64, runs under rosetta on Mac) with the index baked in. HAProxy fronts the unix sockets on `:3457` because the production `jrblatt/so-no-forevis` LB uses io_uring which is unsupported under rosetta.

`tools/offline-gate.py` replays all 54,100 entries from `test/test-data.json`, compares response.approved against entry.expected_approved, and tallies FP/FN/HTTP errors. Its `weighted_E` field follows the official scoring formula: `FP + 3*FN + 5*HTTP_errors`.

## Validation

Reproduces rig results bit-for-bit:

| Config                                      | Rig FP / FN  | Gate FP / FN |
|--------------------------------------------|--------------|--------------|
| b4bfc6b (known-good 0a20b53)                | 0 / 0        | **0 / 0**    |
| 32cb819 (EXTREME2/3=99999999, broken)       | 144 / 158    | **144 / 158**|

## Usage

```bash
# 1. Start the gate stack (defaults to known-good thresholds)
docker compose -f deploy/docker-compose.gate.yml up -d

# 2. Wait a few seconds for sockets to be ready
sleep 3

# 3. Run the gate (~5 seconds for 54k queries)
python3 tools/offline-gate.py

# 4. Tear down when done
docker compose -f deploy/docker-compose.gate.yml down -v
```

To test a threshold variant, override env vars before `up`:

```bash
EXTREME2_WORST_THRESHOLD=4000000 \
EXTREME3_WORST_THRESHOLD=3500000 \
docker compose -f deploy/docker-compose.gate.yml up -d --force-recreate api1 api2

python3 tools/offline-gate.py
```

The gate output is a single JSON line: `{"fp": N, "fn": N, "tp": N, "tn": N, "errors": 0, "weighted_E": ...}`. **Only submit a change if `fp==0 && fn==0`** unless you've explicitly traded accuracy for a clear p99 win (and even then, do the math on detection_score impact).

In sandboxed Codex runs, Python localhost socket access may need escalation. A run that reports every request as an HTTP error while `curl http://localhost:3457/ready` succeeds is sandbox evidence, not application evidence.
