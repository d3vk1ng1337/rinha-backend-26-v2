#!/usr/bin/env bash
set -euo pipefail

compose_file="${COMPOSE_FILE:-deploy/docker-compose.submission.yml}"
total="${TOTAL_REQUESTS:-12000}"
concurrency="${CONCURRENCY:-250}"
timeout_ms="${REQUEST_TIMEOUT_MS:-2001}"

echo "diagnose: compose=${compose_file} total=${total} concurrency=${concurrency} timeout_ms=${timeout_ms}"

cleanup() {
  docker compose -f "${compose_file}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker compose -f "${compose_file}" down -v --remove-orphans >/dev/null 2>&1 || true
docker compose -f "${compose_file}" pull
docker compose -f "${compose_file}" up -d

echo "diagnose: waiting for /ready"
ready_start="$(date +%s)"
for i in $(seq 1 120); do
  if curl -fsS --max-time 1 http://127.0.0.1:9999/ready >/dev/null; then
    ready_end="$(date +%s)"
    echo "diagnose: ready after $((ready_end - ready_start))s"
    break
  fi
  if [[ "${i}" == "120" ]]; then
    echo "diagnose: /ready failed" >&2
    docker compose -f "${compose_file}" ps
    docker compose -f "${compose_file}" logs --no-color --tail=200
    exit 1
  fi
  sleep 0.25
done

echo "diagnose: ps before load"
docker compose -f "${compose_file}" ps
docker stats --no-stream --format 'stats {{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}'

stats_log=".tmp/diagnose-stats.log"
mkdir -p .tmp
(
  while true; do
    date -u '+stats-ts %Y-%m-%dT%H:%M:%SZ'
    docker stats --no-stream --format 'stats {{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}'
    sleep 2
  done
) >"${stats_log}" 2>&1 &
stats_pid="$!"

echo "diagnose: starting load"
TOTAL_REQUESTS="${total}" \
CONCURRENCY="${concurrency}" \
REQUEST_TIMEOUT_MS="${timeout_ms}" \
node tools/diagnose-load.mjs

kill "${stats_pid}" >/dev/null 2>&1 || true
wait "${stats_pid}" >/dev/null 2>&1 || true

echo "diagnose: stats during load"
cat "${stats_log}"

echo "diagnose: ps after load"
docker compose -f "${compose_file}" ps
docker stats --no-stream --format 'stats {{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}'

echo "diagnose: logs"
docker compose -f "${compose_file}" logs --no-color --tail=300
