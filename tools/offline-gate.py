#!/usr/bin/env python3
"""Offline accuracy gate: replays test/test-data.json against the local stack
(deploy/docker-compose.gate.yml) and counts FP/FN. Use to validate that any
threshold change preserves detection_score=3000 before submitting to the rig.
"""
import json, sys, time, threading
from http.client import HTTPConnection, RemoteDisconnected
from concurrent.futures import ThreadPoolExecutor, as_completed

HOST, PORT = "localhost", 3457
TIMEOUT = 30.0
CONCURRENCY = 8

def weighted_errors(fp, fn, errors):
    return fp + (fn * 3) + (errors * 5)

_local = threading.local()
def conn():
    c = getattr(_local, "conn", None)
    if c is None:
        c = HTTPConnection(HOST, PORT, timeout=TIMEOUT)
        _local.conn = c
    return c

def post(body):
    for attempt in range(3):
        c = conn()
        try:
            c.request("POST", "/fraud-score", body=body, headers={"content-type": "application/json", "connection": "keep-alive"})
            r = c.getresponse()
            data = r.read()
            if r.status != 200:
                raise RuntimeError(f"http {r.status}")
            return json.loads(data)
        except (RemoteDisconnected, ConnectionResetError, BrokenPipeError, OSError) as e:
            try: c.close()
            except: pass
            _local.conn = None
            if attempt == 2:
                raise

def main(path):
    with open(path) as f:
        doc = json.load(f)
    entries = doc["entries"]
    n = len(entries)
    print(f"loaded {n} entries; stats: {doc['stats']}", file=sys.stderr)

    fp = fn = tp = tn = errors = 0
    t0 = time.monotonic()
    bodies = [json.dumps(e["request"]).encode() for e in entries]
    expecteds = [e["expected_approved"] for e in entries]

    with ThreadPoolExecutor(max_workers=CONCURRENCY) as ex:
        futures = {ex.submit(post, bodies[i]): (i, expecteds[i]) for i in range(n)}
        done = 0
        for fut in as_completed(futures):
            i, expected_approved = futures[fut]
            try:
                resp = fut.result()
                got = resp.get("approved")
                if got is None:
                    errors += 1
                elif got == expected_approved:
                    if expected_approved: tn += 1
                    else: tp += 1
                else:
                    if expected_approved: fp += 1
                    else: fn += 1
            except Exception:
                errors += 1
            done += 1
            if done % 5000 == 0:
                dt = time.monotonic() - t0
                print(f"  {done}/{n} ({dt:.1f}s; FP={fp} FN={fn} err={errors})", file=sys.stderr)
    dt = time.monotonic() - t0
    print(f"DONE in {dt:.1f}s — FP={fp} FN={fn} TP={tp} TN={tn} HTTP_errors={errors}", file=sys.stderr)
    print(json.dumps({"fp": fp, "fn": fn, "tp": tp, "tn": tn, "errors": errors, "weighted_E": weighted_errors(fp, fn, errors)}))
    return 0 if errors == 0 else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "test/test-data.json"))
