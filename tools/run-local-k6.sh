#!/usr/bin/env bash
set -euo pipefail

# Local k6 bench harness matching the official rig protocol.
# Usage: tools/run-local-k6.sh [--no-build] [--keep]
#
# Outputs:
#   .tmp/k6-results.json   — k6 scoring summary (FP/FN/TP/TN/E/p99/final_score)
#   .tmp/k6-stdout.log     — full k6 stdout
#   .tmp/docker-stats.log  — periodic docker stats samples during the run
#
# Note: results have a known calibration gap vs the Mac Mini Late 2014 official
# rig. Top1 reported ~1.17× pessimism (local 1.03ms → official 1.20ms). To
# expect official p99 ≤ 1.00ms aim for local p99 ≤ 0.85ms.

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${repo_root}"

compose_file="deploy/docker-compose.local.yml"
project="rinha_local"
tmp_dir=".tmp"
k6_dir="${tmp_dir}/k6"
no_build="0"
keep_stack="0"

for arg in "$@"; do
    case "${arg}" in
        --no-build) no_build="1" ;;
        --keep) keep_stack="1" ;;
        *) printf 'unknown flag: %s\n' "${arg}" >&2; exit 2 ;;
    esac
done

if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found in PATH" >&2
    exit 1
fi

cleanup() {
    rc=$?
    if [[ "${keep_stack}" != "1" ]]; then
        docker compose -p "${project}" -f "${compose_file}" down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    exit "${rc}"
}
trap cleanup EXIT

mkdir -p "${tmp_dir}" "${k6_dir}/test"
cp test/test-local.js "${k6_dir}/test/test.js"
cp test/test-data.json "${k6_dir}/test/test-data.json"
chmod -R 777 "${k6_dir}"

echo "==> bringing down any previous local stack"
docker compose -p "${project}" -f "${compose_file}" down -v --remove-orphans >/dev/null 2>&1 || true

if [[ "${no_build}" != "1" ]]; then
    echo "==> building images (this can take a few minutes on first run)"
    docker compose -p "${project}" -f "${compose_file}" build
fi

echo "==> starting builder + api1 + api2 + lb"
docker compose -p "${project}" -f "${compose_file}" up -d

echo "==> waiting for /ready"
ready_start="$(date +%s)"
for i in $(seq 1 240); do
    if curl -fsS --max-time 1 http://127.0.0.1:3456/ready >/dev/null; then
        ready_end="$(date +%s)"
        echo "    ready after $((ready_end - ready_start))s"
        break
    fi
    if [[ "${i}" == "240" ]]; then
        echo "    /ready failed after 60s — dumping logs:"
        docker compose -p "${project}" -f "${compose_file}" ps
        docker compose -p "${project}" -f "${compose_file}" logs --no-color --tail=200
        exit 1
    fi
    sleep 0.25
done

echo "==> container resource config"
docker compose -p "${project}" -f "${compose_file}" ps
docker compose -p "${project}" -f "${compose_file}" ps -q \
  | xargs docker inspect --format 'inspect {{.Name}} cpus={{.HostConfig.NanoCpus}} mem={{.HostConfig.Memory}}'

stats_log="${tmp_dir}/docker-stats.log"
(
    while true; do
        date -u '+stats-ts %Y-%m-%dT%H:%M:%SZ'
        docker stats --no-stream --format 'stats {{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}} pids={{.PIDs}}'
        sleep 2
    done
) >"${stats_log}" 2>&1 &
stats_pid="$!"

stdout_log="${tmp_dir}/k6-stdout.log"
echo "==> running k6 (120s ramp 1→900 RPS)"
set +e
docker run --rm --network host -w /work \
    -v "${repo_root}/${k6_dir}:/work" \
    grafana/k6:latest run /work/test/test.js | tee "${stdout_log}"
k6_exit=$?
set -e

kill "${stats_pid}" >/dev/null 2>&1 || true
wait "${stats_pid}" >/dev/null 2>&1 || true

if [[ -f "${k6_dir}/test/results.json" ]]; then
    cp "${k6_dir}/test/results.json" "${tmp_dir}/k6-results.json"
    echo "==> results"
    cat "${tmp_dir}/k6-results.json"
else
    echo "==> k6 did not produce results.json"
fi

echo "==> docker stats log: ${stats_log}"
echo "==> k6 stdout log:    ${stdout_log}"
echo "==> exit: ${k6_exit}"
exit "${k6_exit}"
