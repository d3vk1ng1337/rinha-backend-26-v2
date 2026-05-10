# data/

## `references.json.gz` (gitignored, ~48 MB)

Reference dataset for the kNN fraud-detection index. Copied from the V1 Go submission via `make data`.

### Format

- **Container:** single-line, gzip-compressed **JSON array** (`[ {...}, {...}, ... ]`). Not NDJSON.
- **Records:** 3,000,000 total.
- **Schema per record (exactly two keys):**
  - `vector`: array of **14 floats**. Values appear normalized to roughly `[-1, 1]` (sentinel `-1` observed for missing-features dimensions 5 and 6).
  - `label`: string, one of `"legit"` (2,000,594) or `"fraud"` (999,406). **No `is_fraud` boolean** — labels are string-encoded.

### Example record

```json
{"vector":[0.5796,0.9167,1,0.0435,0,0.0056,0.4394,0.4598,0.4,1,0,1,0.85,0.0032],"label":"fraud"}
```

### Builder consumption notes (Chunk E)

- Stream-decode the array (do NOT load the full 48 MB decompressed JSON into memory at once).
- Map `label == "fraud"` to `1`, anything else to `0`. Treat `"legit"` as the only legit value; reject unknown labels.
- Vector arity is fixed at 14; assert this when reading.

## `sample.json` (committed)

Example `POST /fraud-score` request body for smoke testing. The 14-dim vector consumed by the search path is *derived* from these structured fields by the API — see `src/vec.zig` (Chunk B) for the projection logic.
