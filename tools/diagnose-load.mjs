import http from 'node:http';
import fs from 'node:fs';
import { performance } from 'node:perf_hooks';

const concurrency = parseInt(process.env.CONCURRENCY ?? '250', 10);
const timeoutMs = parseInt(process.env.REQUEST_TIMEOUT_MS ?? '2001', 10);
const url = new URL(process.env.TARGET_URL ?? 'http://127.0.0.1:9999/fraud-score');

const syntheticPayload = {
  id: 'diag-01',
  transaction: {
    amount: 384.88,
    installments: 3,
    requested_at: '2026-03-11T06:23:35Z',
  },
  customer: {
    avg_amount: 769.76,
    tx_count_24h: 3,
    known_merchants: ['MERC-009', 'MERC-001'],
  },
  merchant: {
    id: 'MERC-009',
    mcc: '5912',
    avg_amount: 298.95,
  },
  terminal: {
    is_online: false,
    card_present: true,
    km_from_home: 13.7,
  },
  last_transaction: {
    timestamp: '2026-03-11T05:58:35Z',
    km_from_current: 18.86,
  },
};

const entries = process.env.TEST_DATA_PATH
  ? JSON.parse(fs.readFileSync(process.env.TEST_DATA_PATH, 'utf8')).entries
  : null;
const total = parseInt(process.env.TOTAL_REQUESTS ?? String(entries?.length ?? 12000), 10);

function payloadAt(index) {
  if (!entries) return Buffer.from(JSON.stringify(syntheticPayload));
  return Buffer.from(JSON.stringify(entries[index % entries.length].request));
}

const agent = new http.Agent({
  keepAlive: true,
  maxSockets: concurrency,
  maxFreeSockets: concurrency,
  timeout: timeoutMs,
});

const counts = new Map();
const durations = [];
let completed = 0;
let launched = 0;

function bump(key) {
  counts.set(key, (counts.get(key) ?? 0) + 1);
}

function percentile(values, p) {
  if (values.length === 0) return 0;
  const idx = Math.min(values.length - 1, Math.ceil((p / 100) * values.length) - 1);
  return values[idx];
}

function runOne() {
  const requestIndex = launched;
  launched += 1;
  const started = performance.now();
  const payload = payloadAt(requestIndex);

  const req = http.request({
    agent,
    hostname: url.hostname,
    port: url.port,
    path: url.pathname,
    method: 'POST',
    timeout: timeoutMs,
    headers: {
      'Content-Type': 'application/json',
      'Content-Length': payload.length,
    },
  }, (res) => {
    res.resume();
    res.on('end', () => {
      durations.push(performance.now() - started);
      bump(String(res.statusCode));
      completed += 1;
      schedule();
    });
  });

  req.on('timeout', () => {
    req.destroy(new Error('timeout'));
  });
  req.on('error', (err) => {
    durations.push(performance.now() - started);
    bump(`ERR_${err.message}`);
    completed += 1;
    schedule();
  });
  req.end(payload);
}

function schedule() {
  while (launched < total && launched - completed < concurrency) {
    runOne();
  }
  if (completed === total) {
    agent.destroy();
    durations.sort((a, b) => a - b);
    const sortedCounts = [...counts.entries()].sort((a, b) => a[0].localeCompare(b[0]));
    console.log(JSON.stringify({
      total,
      concurrency,
      timeout_ms: timeoutMs,
      counts: Object.fromEntries(sortedCounts),
      latency_ms: {
        min: durations[0] ?? 0,
        p50: percentile(durations, 50),
        p90: percentile(durations, 90),
        p99: percentile(durations, 99),
        max: durations[durations.length - 1] ?? 0,
      },
    }, null, 2));
  }
}

schedule();
