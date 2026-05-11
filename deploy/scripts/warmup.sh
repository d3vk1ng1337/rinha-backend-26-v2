#!/bin/sh
# Warm the API stack before the rinha k6 load phase fires. Pulls /ready until
# both backends are listening, then sends a number of real /fraud-score
# requests with 12 VARIED payloads so JIT/branch-predictor/L1/L2 caches and
# HAProxy keepalive sockets cover a representative slice of the production
# distribution before real traffic arrives.
#
# Payloads span the categorical feature space (mcc ∈ risk-table + unknown,
# hour ∈ {00, 03, 06, ..., 22}, terminal.is_online/card_present combos,
# km_from_home magnitudes, with/without last_transaction, varied amounts).
set -eu

BASE_URL="${BASE_URL:-http://localhost:9999}"
READY_URL="${BASE_URL}/ready"
SCORE_URL="${BASE_URL}/fraud-score"
READY_RETRIES="${READY_RETRIES:-240}"
READY_SLEEP="${READY_SLEEP:-0.25}"
WARMUP_ROUNDS="${WARMUP_ROUNDS:-96}"

# 12 payloads spanning the categorical space. mcc covers all 10 risk-table
# entries plus 2 unknowns to also exercise the default-MCC branch.
p01='{"id":"w-01","transaction":{"amount":42.10,"installments":1,"requested_at":"2026-03-11T00:15:23Z"},"customer":{"avg_amount":85.50,"tx_count_24h":2,"known_merchants":["MERC-001","MERC-002"]},"merchant":{"id":"MERC-001","mcc":"5411","avg_amount":52.30},"terminal":{"is_online":false,"card_present":true,"km_from_home":2.1},"last_transaction":null}'
p02='{"id":"w-02","transaction":{"amount":384.88,"installments":3,"requested_at":"2026-03-11T06:23:35Z"},"customer":{"avg_amount":769.76,"tx_count_24h":3,"known_merchants":["MERC-009","MERC-001"]},"merchant":{"id":"MERC-009","mcc":"5912","avg_amount":298.95},"terminal":{"is_online":false,"card_present":true,"km_from_home":13.7},"last_transaction":{"timestamp":"2026-03-11T05:58:35Z","km_from_current":18.86}}'
p03='{"id":"w-03","transaction":{"amount":2911.41,"installments":12,"requested_at":"2026-03-11T12:17:11Z"},"customer":{"avg_amount":411.03,"tx_count_24h":8,"known_merchants":["MERC-221","MERC-010"]},"merchant":{"id":"MERC-551","mcc":"7995","avg_amount":712.22},"terminal":{"is_online":true,"card_present":false,"km_from_home":2.18},"last_transaction":{"timestamp":"2026-03-11T11:51:05Z","km_from_current":1.34}}'
p04='{"id":"w-04","transaction":{"amount":150.00,"installments":2,"requested_at":"2026-03-12T18:42:11Z"},"customer":{"avg_amount":140.00,"tx_count_24h":5,"known_merchants":["MERC-303"]},"merchant":{"id":"MERC-303","mcc":"5311","avg_amount":120.50},"terminal":{"is_online":true,"card_present":true,"km_from_home":0.8},"last_transaction":null}'
p05='{"id":"w-05","transaction":{"amount":85.40,"installments":1,"requested_at":"2026-03-13T03:30:00Z"},"customer":{"avg_amount":92.10,"tx_count_24h":1,"known_merchants":[]},"merchant":{"id":"MERC-512","mcc":"4511","avg_amount":340.00},"terminal":{"is_online":true,"card_present":false,"km_from_home":1250.5},"last_transaction":{"timestamp":"2026-03-12T15:20:00Z","km_from_current":900.2}}'
p06='{"id":"w-06","transaction":{"amount":5500.00,"installments":10,"requested_at":"2026-03-14T22:05:18Z"},"customer":{"avg_amount":80.25,"tx_count_24h":15,"known_merchants":["MERC-001","MERC-002","MERC-003"]},"merchant":{"id":"MERC-999","mcc":"7801","avg_amount":4200.00},"terminal":{"is_online":true,"card_present":false,"km_from_home":700.0},"last_transaction":{"timestamp":"2026-03-14T21:30:00Z","km_from_current":500.0}}'
p07='{"id":"w-07","transaction":{"amount":25.50,"installments":1,"requested_at":"2026-03-15T09:11:00Z"},"customer":{"avg_amount":28.00,"tx_count_24h":4,"known_merchants":["MERC-101","MERC-102","MERC-103","MERC-104"]},"merchant":{"id":"MERC-104","mcc":"5812","avg_amount":31.25},"terminal":{"is_online":false,"card_present":true,"km_from_home":3.5},"last_transaction":{"timestamp":"2026-03-15T08:45:00Z","km_from_current":4.0}}'
p08='{"id":"w-08","transaction":{"amount":799.99,"installments":6,"requested_at":"2026-03-16T15:55:42Z"},"customer":{"avg_amount":350.00,"tx_count_24h":2,"known_merchants":["MERC-200"]},"merchant":{"id":"MERC-201","mcc":"5944","avg_amount":820.50},"terminal":{"is_online":true,"card_present":false,"km_from_home":45.2},"last_transaction":null}'
p09='{"id":"w-09","transaction":{"amount":1250.00,"installments":4,"requested_at":"2026-03-17T07:33:10Z"},"customer":{"avg_amount":1100.00,"tx_count_24h":1,"known_merchants":["MERC-400","MERC-401"]},"merchant":{"id":"MERC-401","mcc":"5999","avg_amount":1300.00},"terminal":{"is_online":false,"card_present":true,"km_from_home":8.7},"last_transaction":{"timestamp":"2026-03-16T22:00:00Z","km_from_current":6.5}}'
p10='{"id":"w-10","transaction":{"amount":9800.00,"installments":12,"requested_at":"2026-03-18T20:48:55Z"},"customer":{"avg_amount":75.00,"tx_count_24h":18,"known_merchants":[]},"merchant":{"id":"MERC-666","mcc":"6011","avg_amount":8500.00},"terminal":{"is_online":true,"card_present":false,"km_from_home":2400.0},"last_transaction":{"timestamp":"2026-03-18T19:30:00Z","km_from_current":2200.0}}'
p11='{"id":"w-11","transaction":{"amount":62.00,"installments":1,"requested_at":"2026-03-19T11:00:00Z"},"customer":{"avg_amount":65.00,"tx_count_24h":3,"known_merchants":["MERC-700","MERC-701"]},"merchant":{"id":"MERC-700","mcc":"7802","avg_amount":58.00},"terminal":{"is_online":false,"card_present":true,"km_from_home":0.5},"last_transaction":null}'
p12='{"id":"w-12","transaction":{"amount":3200.00,"installments":8,"requested_at":"2026-03-20T04:25:33Z"},"customer":{"avg_amount":450.00,"tx_count_24h":7,"known_merchants":["MERC-800"]},"merchant":{"id":"MERC-800","mcc":"7995","avg_amount":2900.00},"terminal":{"is_online":true,"card_present":false,"km_from_home":380.0},"last_transaction":{"timestamp":"2026-03-19T23:00:00Z","km_from_current":320.0}}'

echo "warming up stack via ${BASE_URL}"

i=1
while [ "${i}" -le "${READY_RETRIES}" ]; do
  if curl -fsS --max-time 1 "${READY_URL}" >/dev/null; then
    break
  fi
  if [ "${i}" -eq "${READY_RETRIES}" ]; then
    echo "ready check failed after ${READY_RETRIES} attempts" >&2
    exit 1
  fi
  sleep "${READY_SLEEP}"
  i=$((i + 1))
done

i=1
while [ "${i}" -le "${WARMUP_ROUNDS}" ]; do
  # Rotate through the 12 payloads.
  case $((i % 12)) in
    0)  body="${p01}" ;;
    1)  body="${p02}" ;;
    2)  body="${p03}" ;;
    3)  body="${p04}" ;;
    4)  body="${p05}" ;;
    5)  body="${p06}" ;;
    6)  body="${p07}" ;;
    7)  body="${p08}" ;;
    8)  body="${p09}" ;;
    9)  body="${p10}" ;;
    10) body="${p11}" ;;
    11) body="${p12}" ;;
  esac
  curl -fsS \
    --max-time 2 \
    -H 'content-type: application/json' \
    -d "${body}" \
    "${SCORE_URL}" >/dev/null
  i=$((i + 1))
done

echo "warmup complete (${WARMUP_ROUNDS} requests across 12 payloads)"
